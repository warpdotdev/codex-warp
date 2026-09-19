$ErrorActionPreference = "Stop"

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
} catch {
}

function Read-HookInput {
    $reader = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), [System.Text.Encoding]::UTF8)
    try {
        return $reader.ReadToEnd()
    } finally {
        $reader.Dispose()
    }
}

function ConvertFrom-JsonSafe {
    param([string]$Json)

    if ([string]::IsNullOrWhiteSpace($Json)) {
        return $null
    }

    try {
        return $Json | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Get-JsonProperty {
    param(
        [object]$Object,
        [string]$Name,
        [object]$Default = ""
    )

    if ($null -eq $Object) {
        return $Default
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return $Default
    }

    return $property.Value
}

function Test-OzHarnessAvailable {
    if ([string]::IsNullOrEmpty($env:OZ_CLI)) {
        return $false
    }
    if ([string]::IsNullOrEmpty($env:OZ_RUN_ID)) {
        return $false
    }
    if ([string]::IsNullOrEmpty($env:OZ_PARENT_RUN_ID)) {
        return $false
    }

    return $null -ne (Get-Command $env:OZ_CLI -ErrorAction SilentlyContinue)
}

function Get-StateRoot {
    if (-not [string]::IsNullOrEmpty($env:OZ_PARENT_STATE_ROOT)) {
        return $env:OZ_PARENT_STATE_ROOT
    }

    return (Join-Path $HOME ".codex\oz-parent-bridge")
}

function Get-StateDirFromSessionId {
    param([string]$SessionId)

    return (Join-Path (Get-StateRoot) $SessionId)
}

function Get-StateDirFromInput {
    param([string]$InputJson)

    $inputObject = ConvertFrom-JsonSafe $InputJson
    $sessionId = [string](Get-JsonProperty $inputObject "session_id" "")
    if ([string]::IsNullOrEmpty($sessionId)) {
        return $null
    }

    return (Get-StateDirFromSessionId $sessionId)
}

function New-HookState {
    $inputJson = Read-HookInput
    if (-not (Test-OzHarnessAvailable)) {
        return $null
    }

    $stateDir = Get-StateDirFromInput $inputJson
    if ([string]::IsNullOrEmpty($stateDir)) {
        return $null
    }

    return [pscustomobject]@{
        InputJson = $inputJson
        StateDir = $stateDir
    }
}

function Import-HookState {
    $state = New-HookState
    if ($null -eq $state) {
        return $null
    }

    if (Test-ListenerLifecycleManagedExternally) {
        if (-not (Test-Path -LiteralPath $state.StateDir -PathType Container)) {
            return $null
        }
    } else {
        New-StateDir $state.StateDir
    }

    return $state
}

function Test-ListenerLifecycleManagedExternally {
    return $env:OZ_PARENT_LISTENER_MANAGED_EXTERNALLY -eq "1"
}

function New-StateDir {
    param([string]$StateDir)

    New-Item -ItemType Directory -Force -Path (Get-StagedDir $StateDir) | Out-Null
}

function Get-StagedDir {
    param([string]$StateDir)

    return (Join-Path $StateDir "staged")
}

function Get-SurfacedDir {
    param([string]$StateDir)

    return (Join-Path $StateDir "surfaced")
}

function Get-HookOutputFile {
    param([string]$StateDir)

    return (Join-Path $StateDir "pending-hook-output.json")
}

function Get-HookOutputAckFile {
    param([string]$StateDir)

    return (Join-Path $StateDir "pending-hook-output.ack")
}

function Get-ListenerPidFile {
    param([string]$StateDir)

    return (Join-Path $StateDir "listener.pid")
}

function Get-ListenerLogFile {
    param([string]$StateDir)

    return (Join-Path $StateDir "listener.log")
}

function Get-LastSequenceFile {
    param([string]$StateDir)

    return (Join-Path $StateDir "last-sequence")
}

function Get-StagedMessagePath {
    param(
        [string]$StateDir,
        [int64]$Sequence,
        [string]$MessageId
    )

    return (Join-Path (Get-StagedDir $StateDir) ("{0:D20}-{1}.json" -f $Sequence, $MessageId))
}

function Get-SortedMessageFiles {
    param([string]$Directory)

    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        return @()
    }

    return @(Get-ChildItem -LiteralPath $Directory -Filter "*.json" -File | Sort-Object Name | ForEach-Object { $_.FullName })
}

function Get-SortedStagedMessages {
    param([string]$StateDir)

    return Get-SortedMessageFiles (Get-StagedDir $StateDir)
}

function Get-SortedSurfacedMessages {
    param([string]$StateDir)

    return Get-SortedMessageFiles (Get-SurfacedDir $StateDir)
}

function Get-StagedMessageCount {
    param([string]$StateDir)

    return @(Get-SortedStagedMessages $StateDir).Count
}

function Get-SurfacedMessageCount {
    param([string]$StateDir)

    return @(Get-SortedSurfacedMessages $StateDir).Count
}

function Test-DriverHookOutputAvailable {
    param([string]$StateDir)

    return (Test-Path -LiteralPath (Get-HookOutputFile $StateDir) -PathType Leaf) -and
        -not (Test-Path -LiteralPath (Get-HookOutputAckFile $StateDir) -PathType Leaf)
}

function Wait-ForDriverHookOutput {
    param([string]$StateDir)

    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        if (Test-DriverHookOutputAvailable $StateDir) {
            return $true
        }
        if (Test-Path -LiteralPath (Get-HookOutputAckFile $StateDir) -PathType Leaf) {
            return $false
        }
        Start-Sleep -Milliseconds 50
    }

    return (Test-DriverHookOutputAvailable $StateDir)
}

function Write-HookAdditionalContext {
    param(
        [string]$HookEvent,
        [string]$AdditionalContext
    )

    [ordered]@{
        hookSpecificOutput = [ordered]@{
            hookEventName = $HookEvent
            additionalContext = $AdditionalContext
        }
    } | ConvertTo-Json -Compress -Depth 20
}

function Write-DriverHookAdditionalContext {
    param(
        [string]$HookEvent,
        [string]$StateDir
    )

    if (-not (Wait-ForDriverHookOutput $StateDir)) {
        return $null
    }

    $outputObject = ConvertFrom-JsonSafe (Get-Content -Raw -LiteralPath (Get-HookOutputFile $StateDir) -ErrorAction SilentlyContinue)
    $additionalContext = [string](Get-JsonProperty $outputObject "additional_context" "")
    if ([string]::IsNullOrEmpty($additionalContext)) {
        return $null
    }

    return (Write-HookAdditionalContext $HookEvent $additionalContext)
}

function Confirm-DriverHookOutput {
    param([string]$StateDir)

    New-Item -ItemType File -Force -Path (Get-HookOutputAckFile $StateDir) | Out-Null
}

function Get-DriverPendingParentMessageCount {
    param([string]$StateDir)

    $pendingCount = Get-StagedMessageCount $StateDir
    if (-not (Test-Path -LiteralPath (Get-HookOutputAckFile $StateDir) -PathType Leaf)) {
        $pendingCount += Get-SurfacedMessageCount $StateDir
    }

    return $pendingCount
}

function Get-PendingParentMessageCount {
    param([string]$StateDir)

    if (Test-ListenerLifecycleManagedExternally) {
        return Get-DriverPendingParentMessageCount $StateDir
    }

    return Get-StagedMessageCount $StateDir
}

function Test-ListenerRunning {
    param([string]$StateDir)

    $pidFile = Get-ListenerPidFile $StateDir
    if (-not (Test-Path -LiteralPath $pidFile -PathType Leaf)) {
        return $false
    }

    $listenerPid = Get-Content -Raw -LiteralPath $pidFile -ErrorAction SilentlyContinue
    if ($null -eq $listenerPid) {
        $listenerPid = ""
    } else {
        $listenerPid = $listenerPid.Trim()
    }
    if ([string]::IsNullOrEmpty($listenerPid)) {
        return $false
    }

    try {
        return $null -ne (Get-Process -Id ([int]$listenerPid) -ErrorAction Stop)
    } catch {
        return $false
    }
}

function Stop-Listener {
    param([string]$StateDir)

    $pidFile = Get-ListenerPidFile $StateDir
    if (-not (Test-Path -LiteralPath $pidFile -PathType Leaf)) {
        return
    }

    $listenerPid = Get-Content -Raw -LiteralPath $pidFile -ErrorAction SilentlyContinue
    if ($null -eq $listenerPid) {
        $listenerPid = ""
    } else {
        $listenerPid = $listenerPid.Trim()
    }
    if (-not [string]::IsNullOrEmpty($listenerPid)) {
        try {
            Stop-Process -Id ([int]$listenerPid) -ErrorAction SilentlyContinue
        } catch {
        }
    }

    Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
}

function Initialize-LastSequenceFile {
    param([string]$StateDir)

    $path = Get-LastSequenceFile $StateDir
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        New-Item -ItemType File -Force -Path $path | Out-Null
    }
}

function Start-ListenerIfNeeded {
    param(
        [string]$ListenerScript,
        [string]$StateDir
    )

    if (Test-ListenerRunning $StateDir) {
        return
    }

    New-StateDir $StateDir
    Stop-Listener $StateDir

    # Start-Process joins ArgumentList arrays into a single command line. Quote
    # both paths explicitly so listener startup also works from paths containing
    # spaces, such as the default Windows user and plugin directories.
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" "{1}"' -f $ListenerScript, $StateDir
    $process = Start-Process -FilePath "powershell.exe" -ArgumentList $arguments -WindowStyle Hidden -PassThru
    [System.IO.File]::WriteAllText((Get-ListenerPidFile $StateDir), "$($process.Id)`n")
}

function Clear-HookState {
    param([string]$StateDir)

    Stop-Listener $StateDir
    Remove-Item -LiteralPath $StateDir -Recurse -Force -ErrorAction SilentlyContinue
}

function Get-StopLingerAttempts {
    $attempts = 240
    $parsed = 0
    if ([int]::TryParse($env:OZ_PARENT_STOP_LINGER_ATTEMPTS, [ref]$parsed) -and $parsed -ge 0) {
        $attempts = $parsed
    }
    return $attempts
}

function Get-StopLingerPollMilliseconds {
    $pollSeconds = 0.25
    $parsed = 0.0
    if ([double]::TryParse($env:OZ_PARENT_STOP_LINGER_POLL_SECONDS, [ref]$parsed) -and $parsed -ge 0) {
        $pollSeconds = $parsed
    }

    return [int]($pollSeconds * 1000)
}

function Wait-ForPendingParentMessages {
    param([string]$StateDir)

    $attempts = Get-StopLingerAttempts
    $pollMilliseconds = Get-StopLingerPollMilliseconds

    for ($attempt = 0; $attempt -le $attempts; $attempt++) {
        $pendingCount = Get-PendingParentMessageCount $StateDir
        if ($pendingCount -gt 0) {
            return $pendingCount
        }

        if ($attempt -lt $attempts) {
            Start-Sleep -Milliseconds $pollMilliseconds
        }
    }

    return 0
}

function Write-StopBlockIfPending {
    param([string]$StateDir)

    $pendingCount = Wait-ForPendingParentMessages $StateDir
    if ($pendingCount -le 0) {
        return $null
    }

    $reason = "There are $pendingCount pending parent message(s) from the lead Oz run. Continue so the next safe boundary can surface them."
    return ([ordered]@{
        decision = "block"
        reason = $reason
    } | ConvertTo-Json -Compress -Depth 10)
}

function Confirm-MessageDelivered {
    param([string]$MessageId)

    try {
        & $env:OZ_CLI run message mark-delivered $MessageId *> $null
        return
    } catch {
    }

    try {
        & $env:OZ_CLI run message delivered $MessageId *> $null
    } catch {
    }
}

function Remove-StagedMessage {
    param(
        [string]$StateDir,
        [string]$MessageId
    )

    Get-ChildItem -LiteralPath (Get-StagedDir $StateDir) -Filter "*-$MessageId.json" -File -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

function New-ParentContextFromStagedMessages {
    param(
        [string]$StateDir,
        [int]$MaxContextChars = 6000
    )

    $renderedContext = "Lead-agent updates arrived from Oz. Treat the latest parent instructions below as authoritative.`n"
    $surfacedIds = New-Object System.Collections.Generic.List[string]
    $totalStaged = 0

    foreach ($stagedFile in Get-SortedStagedMessages $StateDir) {
        $totalStaged += 1
        $messageObject = ConvertFrom-JsonSafe (Get-Content -Raw -LiteralPath $stagedFile -ErrorAction SilentlyContinue)
        $messageId = [string](Get-JsonProperty $messageObject "message_id" "")
        $senderRunId = [string](Get-JsonProperty $messageObject "sender_run_id" "")
        $subject = [string](Get-JsonProperty $messageObject "subject" "")
        $body = [string](Get-JsonProperty $messageObject "body" "")
        $sequence = [string](Get-JsonProperty $messageObject "sequence" "")

        if ([string]::IsNullOrEmpty($messageId)) {
            continue
        }
        if ([string]::IsNullOrEmpty($subject)) {
            $subject = "(no subject)"
        }

        $block = "---`nParent message"
        if (-not [string]::IsNullOrEmpty($sequence)) {
            $block = "$block #$sequence"
        }
        if (-not [string]::IsNullOrEmpty($senderRunId)) {
            $block = "$block from $senderRunId"
        }
        $block = "$block`nSubject: $subject`n`n$body"

        $separator = ""
        if ($surfacedIds.Count -gt 0) {
            $separator = "`n`n"
        }

        $candidate = "$renderedContext$separator$block"
        if ($candidate.Length -gt $MaxContextChars) {
            $remaining = $MaxContextChars - $renderedContext.Length - $separator.Length
            if ($remaining -le 3 -and $surfacedIds.Count -gt 0) {
                break
            }
            if ($remaining -gt 3 -and $block.Length -gt $remaining) {
                $block = $block.Substring(0, $remaining - 3) + "..."
            } elseif ($surfacedIds.Count -gt 0) {
                break
            }
        }

        $renderedContext = "$renderedContext$separator$block"
        $surfacedIds.Add($messageId)
    }

    if ($surfacedIds.Count -eq 0) {
        return $null
    }

    $remainingCount = $totalStaged - $surfacedIds.Count
    if ($remainingCount -gt 0) {
        $note = "`n`nMore parent messages are still staged and will be surfaced on a later turn."
        if (($renderedContext.Length + $note.Length) -le $MaxContextChars) {
            $renderedContext = "$renderedContext$note"
        }
    }

    return [pscustomobject]@{
        Context = $renderedContext
        SurfacedIds = @($surfacedIds.ToArray())
        RemainingCount = $remainingCount
    }
}

function Confirm-AndRemoveStagedMessages {
    param(
        [string]$StateDir,
        [string[]]$MessageIds
    )

    foreach ($messageId in $MessageIds) {
        Confirm-MessageDelivered $messageId
        Remove-StagedMessage $StateDir $messageId
    }
}
