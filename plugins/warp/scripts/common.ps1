$ErrorActionPreference = "Stop"

$PluginCurrentProtocolVersion = 1

function Test-ShouldUseStructured {
    if ([string]::IsNullOrEmpty($env:WARP_CLI_AGENT_PROTOCOL_VERSION)) {
        return $false
    }
    if ([string]::IsNullOrEmpty($env:WARP_CLIENT_VERSION)) {
        return $false
    }
    return $true
}

function Read-HookInput {
    $reader = [System.IO.StreamReader]::new([Console]::OpenStandardInput(), [System.Text.UTF8Encoding]::new($false))
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

function Get-TruncatedText {
    param(
        [string]$Value,
        [int]$MaxLength
    )

    if ($null -eq $Value) {
        return ""
    }

    if ($Value.Length -gt $MaxLength) {
        return $Value.Substring(0, $MaxLength - 3) + "..."
    }

    return $Value
}

function Get-ProtocolVersion {
    $warpVersion = 1
    $parsed = 0
    if ([int]::TryParse($env:WARP_CLI_AGENT_PROTOCOL_VERSION, [ref]$parsed)) {
        $warpVersion = $parsed
    }

    if ($warpVersion -lt $PluginCurrentProtocolVersion) {
        return $warpVersion
    }

    return $PluginCurrentProtocolVersion
}

function New-WarpPayload {
    param(
        [string]$InputJson,
        [string]$Event,
        [hashtable]$ExtraFields = @{}
    )

    $inputObject = ConvertFrom-JsonSafe $InputJson
    $sessionId = [string](Get-JsonProperty $inputObject "session_id" "")
    $cwd = [string](Get-JsonProperty $inputObject "cwd" "")
    $project = ""

    if (-not [string]::IsNullOrEmpty($cwd)) {
        $project = Split-Path -Leaf $cwd
    }

    $payload = [ordered]@{
        v = Get-ProtocolVersion
        agent = "codex"
        event = $Event
        session_id = $sessionId
        cwd = $cwd
        project = $project
    }

    foreach ($key in $ExtraFields.Keys) {
        $payload[$key] = $ExtraFields[$key]
    }

    return ($payload | ConvertTo-Json -Compress -Depth 50)
}

function Initialize-WarpConsoleWriter {
    if ("WarpConsoleWriter" -as [type]) {
        return
    }

    Add-Type -Path (Join-Path $PSScriptRoot "console-writer.cs")
}

function Send-WarpNotification {
    param(
        [string]$Title,
        [string]$Body
    )

    $escape = [char]27
    $bell = [char]7
    $message = "$escape]777;notify;$Title;$Body$bell"

    try {
        Initialize-WarpConsoleWriter
        if (-not [WarpConsoleWriter]::Write($message)) {
            [Console]::Error.WriteLine("[codex-warp] notification delivery failed: $([WarpConsoleWriter]::LastError)")
        }
    } catch {
        # Hook stdout is reserved for Codex hook control JSON, not notification bytes.
        [Console]::Error.WriteLine("[codex-warp] notification delivery failed: console interop unavailable")
    }
}
