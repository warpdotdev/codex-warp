$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

function Assert-Equal {
    param(
        $Expected,
        $Actual,
        [string]$Message
    )

    if ($Expected -ne $Actual) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Invoke-PowerShellHook {
    param(
        [string]$ScriptPath,
        [string]$InputJson,
        [string[]]$ScriptArguments = @()
    )

    $powershellArguments = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $ScriptPath
    ) + $ScriptArguments

    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = @($InputJson | & powershell.exe @powershellArguments 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($exitCode -ne 0) {
        throw "$ScriptPath exited with code $exitCode.`n$($output -join "`n")"
    }

    return $output
}

function Test-PowerShellSyntax {
    $parseFailures = New-Object System.Collections.Generic.List[string]

    foreach ($script in Get-ChildItem -LiteralPath $repoRoot -Recurse -Filter "*.ps1") {
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile(
            $script.FullName,
            [ref]$tokens,
            [ref]$errors
        )

        foreach ($parseError in $errors) {
            [void]$parseFailures.Add("$($script.FullName): $($parseError.Message)")
        }
    }

    if ($parseFailures.Count -gt 0) {
        throw "PowerShell parse failures:`n$($parseFailures -join "`n")"
    }
}

function Test-WindowsHookCommands {
    $manifestPaths = @(
        (Join-Path $repoRoot "plugins\warp\hooks\hooks.json"),
        (Join-Path $repoRoot "plugins\orchestration\hooks\hooks.json")
    )

    foreach ($manifestPath in $manifestPaths) {
        $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
        $pluginRoot = Split-Path (Split-Path $manifestPath -Parent) -Parent

        foreach ($event in $manifest.hooks.PSObject.Properties) {
            foreach ($group in $event.Value) {
                foreach ($hook in $group.hooks) {
                    $commandWindows = [string]$hook.commandWindows
                    Assert-True (-not [string]::IsNullOrWhiteSpace($commandWindows)) "$manifestPath $($event.Name) is missing commandWindows."

                    if ($commandWindows -notmatch '-File\s+"?\$\{PLUGIN_ROOT\}/(?<scriptPath>[^"\s]+\.ps1)"?') {
                        throw "$manifestPath $($event.Name) has an invalid PowerShell commandWindows value: $commandWindows"
                    }

                    $scriptPath = Join-Path $pluginRoot ($Matches.scriptPath -replace "/", "\")
                    Assert-True (Test-Path -LiteralPath $scriptPath -PathType Leaf) "$manifestPath references missing script $scriptPath."
                }
            }
        }
    }
}

function Test-WarpPayload {
    . (Join-Path $repoRoot "plugins\warp\scripts\common.ps1")

    $payload = New-WarpPayload `
        '{"session_id":"session-1","cwd":"C:\\work\\project"}' `
        "test-event" `
        @{ detail = "ok" } |
        ConvertFrom-Json

    Assert-Equal "codex" $payload.agent "Warp payload agent mismatch."
    Assert-Equal "test-event" $payload.event "Warp payload event mismatch."
    Assert-Equal "session-1" $payload.session_id "Warp payload session mismatch."
    Assert-Equal "project" $payload.project "Warp payload project mismatch."
    Assert-Equal "ok" $payload.detail "Warp payload extra field mismatch."
}

function Test-WarpConsoleWriterInterop {
    . (Join-Path $repoRoot "plugins\warp\scripts\common.ps1")

    Initialize-WarpConsoleWriter
    Assert-True ($null -ne ("WarpConsoleWriter" -as [type])) "Warp console writer type was not loaded."
    [void][WarpConsoleWriter]::Write("")
}

function Test-WarpHookEntryPoints {
    $oldProtocolVersion = $env:WARP_CLI_AGENT_PROTOCOL_VERSION
    $oldClientVersion = $env:WARP_CLIENT_VERSION

    try {
        $env:WARP_CLI_AGENT_PROTOCOL_VERSION = "1"
        $env:WARP_CLIENT_VERSION = "test"
        $inputJson = '{"session_id":"session-1","cwd":"C:\\work\\project","prompt":"Test prompt","tool_name":"shell","tool_input":{"command":"echo test"},"last_assistant_message":"Done","transcript_path":"C:\\work\\transcript.jsonl"}'

        foreach ($script in Get-ChildItem -LiteralPath (Join-Path $repoRoot "plugins\warp\scripts") -Filter "on-*.ps1") {
            [void](Invoke-PowerShellHook $script.FullName $inputJson)
        }
    } finally {
        $env:WARP_CLI_AGENT_PROTOCOL_VERSION = $oldProtocolVersion
        $env:WARP_CLIENT_VERSION = $oldClientVersion
    }
}

function Test-ListenerLaunchWithSpaces {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "codex warp powershell tests $([guid]::NewGuid())"
    $listenerDir = Join-Path $tempRoot "listener scripts"
    $stateRoot = Join-Path $tempRoot "listener state"
    $stateDir = Join-Path $stateRoot "session-1"
    $fakeCli = Join-Path $tempRoot "fake oz cli.ps1"
    $oldOzCli = $env:OZ_CLI
    $oldOzRunId = $env:OZ_RUN_ID
    $oldOzParentRunId = $env:OZ_PARENT_RUN_ID
    $oldStateRoot = $env:OZ_PARENT_STATE_ROOT
    $oldManagedExternally = $env:OZ_PARENT_LISTENER_MANAGED_EXTERNALLY

    try {
        New-Item -ItemType Directory -Force -Path $listenerDir | Out-Null
        Copy-Item -LiteralPath (Join-Path $repoRoot "plugins\orchestration\scripts\oz-parent-common.ps1") -Destination $listenerDir
        Copy-Item -LiteralPath (Join-Path $repoRoot "plugins\orchestration\scripts\oz-parent-listener.ps1") -Destination $listenerDir
        Copy-Item -LiteralPath (Join-Path $repoRoot "plugins\orchestration\scripts\on-session-start.ps1") -Destination $listenerDir
        Copy-Item -LiteralPath (Join-Path $repoRoot "plugins\orchestration\scripts\on-session-end.ps1") -Destination $listenerDir

        @'
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$CliArguments
)

[ordered]@{
    sequence = 1
    message_id = "message-1"
    sender_run_id = "sender-1"
    subject = "Listener test"
    body = "Listener started from a path containing spaces."
} | ConvertTo-Json -Compress
'@ | Set-Content -LiteralPath $fakeCli -Encoding UTF8

        $env:OZ_CLI = $fakeCli
        $env:OZ_RUN_ID = "run-1"
        $env:OZ_PARENT_RUN_ID = "parent-1"
        $env:OZ_PARENT_STATE_ROOT = $stateRoot
        $env:OZ_PARENT_LISTENER_MANAGED_EXTERNALLY = ""

        [void](Invoke-PowerShellHook (Join-Path $listenerDir "on-session-start.ps1") '{"session_id":"session-1"}')

        $deadline = (Get-Date).AddSeconds(10)
        $stagedFiles = @()
        do {
            $stagedFiles = @(Get-ChildItem -LiteralPath (Join-Path $stateDir "staged") -Filter "*.json" -ErrorAction SilentlyContinue)
            if ($stagedFiles.Count -gt 0) {
                break
            }
            Start-Sleep -Milliseconds 100
        } while ((Get-Date) -lt $deadline)

        Assert-Equal 1 $stagedFiles.Count "Listener did not stage exactly one message."
        $message = Get-Content -Raw -LiteralPath $stagedFiles[0].FullName | ConvertFrom-Json
        Assert-Equal "message-1" $message.message_id "Listener staged the wrong message."

        [void](Invoke-PowerShellHook (Join-Path $listenerDir "on-session-end.ps1") '{"session_id":"session-1"}')
        Assert-True (-not (Test-Path -LiteralPath $stateDir)) "SessionEnd did not clean up listener state."
    } finally {
        if (Test-Path -LiteralPath $stateDir) {
            . (Join-Path $listenerDir "oz-parent-common.ps1")
            Stop-Listener $stateDir
        }
        $env:OZ_CLI = $oldOzCli
        $env:OZ_RUN_ID = $oldOzRunId
        $env:OZ_PARENT_RUN_ID = $oldOzParentRunId
        $env:OZ_PARENT_STATE_ROOT = $oldStateRoot
        $env:OZ_PARENT_LISTENER_MANAGED_EXTERNALLY = $oldManagedExternally
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-PowerShellSyntax
Test-WindowsHookCommands
Test-WarpPayload
Test-WarpConsoleWriterInterop
Test-WarpHookEntryPoints
Test-ListenerLaunchWithSpaces

Write-Host "PowerShell hook tests passed."
