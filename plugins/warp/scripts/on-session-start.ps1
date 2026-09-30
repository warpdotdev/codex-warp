# Hook script for Codex SessionStart event.
# Emits plugin version via warp://cli-agent so Warp can track the session.

. "$PSScriptRoot\common.ps1"

if (-not (Test-ShouldUseStructured)) {
    exit 0
}

$pluginVersion = "0.4.2"
$inputJson = Read-HookInput
$body = New-WarpPayload $inputJson "session_start" @{
    plugin_version = $pluginVersion
}

Send-WarpNotification "warp://cli-agent" $body
