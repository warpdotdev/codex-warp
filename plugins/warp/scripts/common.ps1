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

    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class WarpConsoleWriter
{
    private const uint GenericWrite = 0x40000000;
    private const uint FileShareRead = 0x00000001;
    private const uint FileShareWrite = 0x00000002;
    private const uint OpenExisting = 3;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateFileW(
        string fileName,
        uint desiredAccess,
        uint shareMode,
        IntPtr securityAttributes,
        uint creationDisposition,
        uint flagsAndAttributes,
        IntPtr templateFile);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool WriteConsoleW(
        IntPtr consoleOutput,
        string buffer,
        uint charsToWrite,
        out uint charsWritten,
        IntPtr reserved);

    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);

    public static bool Write(string message)
    {
        IntPtr handle = CreateFileW(
            "CONOUT$",
            GenericWrite,
            FileShareRead | FileShareWrite,
            IntPtr.Zero,
            OpenExisting,
            0,
            IntPtr.Zero);

        if (handle == new IntPtr(-1))
        {
            return false;
        }

        try
        {
            int offset = 0;
            while (offset < message.Length)
            {
                int chunkLength = Math.Min(16384, message.Length - offset);
                if (offset + chunkLength < message.Length
                    && char.IsHighSurrogate(message[offset + chunkLength - 1]))
                {
                    chunkLength--;
                }

                string chunk = message.Substring(offset, chunkLength);
                uint written;
                if (!WriteConsoleW(handle, chunk, (uint)chunk.Length, out written, IntPtr.Zero)
                    || written == 0)
                {
                    return false;
                }

                offset += (int)written;
            }

            return true;
        }
        finally
        {
            CloseHandle(handle);
        }
    }
}
"@
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
        [void][WarpConsoleWriter]::Write($message)
    } catch {
        # Hook stdout is reserved for Codex hook control JSON. If there is no
        # attached console device, drop the notification rather than emitting
        # OSC text to captured stdout and making the hook fail.
    }
}
