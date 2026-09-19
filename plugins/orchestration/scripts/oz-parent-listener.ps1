param(
    [Parameter(Mandatory = $true)]
    [string]$StateDir
)

. "$PSScriptRoot\oz-parent-common.ps1"

function Add-MessageFromWatchRecord {
    param(
        [string]$StateDir,
        [string]$Line
    )

    $messageObject = ConvertFrom-JsonSafe $Line
    $sequenceValue = Get-JsonProperty $messageObject "sequence" $null
    $messageId = [string](Get-JsonProperty $messageObject "message_id" "")

    if ($null -eq $sequenceValue -or [string]::IsNullOrEmpty($messageId)) {
        return
    }

    $sequence = [int64]$sequenceValue
    $target = Get-StagedMessagePath $StateDir $sequence $messageId
    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
        [System.IO.File]::WriteAllText($target, $Line + "`n")
    }

    [System.IO.File]::WriteAllText((Get-LastSequenceFile $StateDir), "$sequence`n")
}

New-StateDir $StateDir
Initialize-LastSequenceFile $StateDir

$lastSequence = Get-Content -Raw -LiteralPath (Get-LastSequenceFile $StateDir) -ErrorAction SilentlyContinue
if ($null -eq $lastSequence) {
    $lastSequence = ""
} else {
    $lastSequence = $lastSequence.Trim()
}
if ([string]::IsNullOrEmpty($lastSequence)) {
    $lastSequence = "0"
}

& $env:OZ_CLI run message watch $env:OZ_RUN_ID --since-sequence $lastSequence --output-format ndjson |
    ForEach-Object {
        if (-not [string]::IsNullOrEmpty($_)) {
            Add-MessageFromWatchRecord $StateDir $_
        }
    }
