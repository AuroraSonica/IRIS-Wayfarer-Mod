$ErrorActionPreference = 'Stop'

$toolDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$gameDir = 'D:\SteamLibrary\steamapps\common\Dragons Dogma 2'
$archivePath = Join-Path $toolDir 'IRIS_Assets_v3.3_MultiPak_FluffyMod.zip'

$expectedPakMd5 = [ordered]@{
    'IRIS_00_griffin_egg.pak' = '4ECD13F8'
    'IRIS_01_wild_horses.pak' = '43430146'
    'IRIS_02_wild_cats.pak' = '73A6F4C5'
    'IRIS_03_baby_bundle.pak' = '62331671'
    'IRIS_04_woodcutting.pak' = '85DFC467'
    'IRIS_05_ritual_music.pak' = '4A1DA6D0'
    'IRIS_06_farmland.pak' = '7ED4B3A7'
}

$runtimeFiles = [ordered]@{
    'reframework/autorun/IrisWildCats.lua' = Join-Path $gameDir 'reframework\autorun\IrisWildCats.lua'
    'reframework/autorun/IrisWildHorses.lua' = Join-Path $gameDir 'reframework\autorun\IrisWildHorses.lua'
    'reframework/data/PumaAudioManifest.json' = Join-Path $gameDir 'reframework\data\PumaAudioManifest.json'
    'reframework/data/HorseAudioManifest.json' = Join-Path $gameDir 'reframework\data\HorseAudioManifest.json'
}

Add-Type -AssemblyName System.IO.Compression.FileSystem

function Get-ZipEntryHash {
    param(
        [Parameter(Mandatory)] [System.IO.Compression.ZipArchiveEntry] $Entry,
        [Parameter(Mandatory)] [ValidateSet('MD5', 'SHA256')] [string] $Algorithm
    )
    $stream = $Entry.Open()
    try {
        $hasher = [System.Security.Cryptography.HashAlgorithm]::Create($Algorithm)
        try { return [Convert]::ToHexString($hasher.ComputeHash($stream)) }
        finally { $hasher.Dispose() }
    } finally {
        $stream.Dispose()
    }
}

$rows = [System.Collections.Generic.List[object]]::new()
$zip = [System.IO.Compression.ZipFile]::OpenRead($archivePath)
try {
    if ($zip.Entries.Count -ne 12) {
        throw "Archive contains $($zip.Entries.Count) entries; expected 12"
    }

    $modEntry = $zip.GetEntry('modinfo.ini')
    if ($null -eq $modEntry) { throw 'modinfo.ini is missing' }
    $reader = [System.IO.StreamReader]::new($modEntry.Open())
    try { $modInfo = $reader.ReadToEnd() } finally { $reader.Dispose() }
    if ($modInfo -notmatch '(?m)^version=3\.3\.3$') {
        throw 'modinfo.ini does not contain version=3.3.3'
    }
    $rows.Add([pscustomobject]@{ Entry='modinfo.ini'; Match=$true; Hash='version 3.3.3' })

    foreach ($pair in $expectedPakMd5.GetEnumerator()) {
        $entry = $zip.GetEntry($pair.Key)
        if ($null -eq $entry) { throw "Missing PAK entry: $($pair.Key)" }
        $hash = Get-ZipEntryHash -Entry $entry -Algorithm MD5
        $match = $hash.StartsWith($pair.Value)
        $rows.Add([pscustomobject]@{ Entry=$pair.Key; Match=$match; Hash=$hash })
        if (-not $match) {
            throw "$($pair.Key) MD5 $hash does not begin with $($pair.Value)"
        }
    }

    foreach ($pair in $runtimeFiles.GetEnumerator()) {
        $entry = $zip.GetEntry($pair.Key)
        if ($null -eq $entry) { throw "Missing runtime entry: $($pair.Key)" }
        $insideHash = Get-ZipEntryHash -Entry $entry -Algorithm SHA256
        $liveHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $pair.Value).Hash
        $match = $insideHash -eq $liveHash
        $rows.Add([pscustomobject]@{ Entry=$pair.Key; Match=$match; Hash=$insideHash })
        if (-not $match) { throw "$($pair.Key) does not match the live file" }
    }
} finally {
    $zip.Dispose()
}

$rows | Format-Table -AutoSize
Get-Item -LiteralPath $archivePath | Select-Object FullName, Length, LastWriteTime | Format-List
Get-FileHash -Algorithm SHA256 -LiteralPath $archivePath | Format-List
