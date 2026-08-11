$ErrorActionPreference = 'Stop'

$toolDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$gameDir = 'D:\SteamLibrary\steamapps\common\Dragons Dogma 2'
$archivePath = Join-Path $toolDir 'IRIS_Assets_v3.3_MultiPak_FluffyMod.zip'
$buildPath = Join-Path $toolDir 'IRIS_Assets_v3.3_MultiPak_FluffyMod.building.zip'
$backupPath = Join-Path $toolDir 'IRIS_Assets_v3.3.2_MultiPak_FluffyMod.backup.zip'

if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
    throw "Source archive missing: $archivePath"
}
if (Test-Path -LiteralPath $buildPath) {
    throw "Refusing to overwrite stale build output: $buildPath"
}

$pakNames = @(
    'IRIS_00_griffin_egg.pak',
    'IRIS_01_wild_horses.pak',
    'IRIS_02_wild_cats.pak',
    'IRIS_03_baby_bundle.pak',
    'IRIS_04_woodcutting.pak',
    'IRIS_05_ritual_music.pak',
    'IRIS_06_farmland.pak'
)

$runtimeFiles = [ordered]@{
    'reframework/autorun/IrisWildCats.lua' = Join-Path $gameDir 'reframework\autorun\IrisWildCats.lua'
    'reframework/autorun/IrisWildHorses.lua' = Join-Path $gameDir 'reframework\autorun\IrisWildHorses.lua'
    'reframework/data/PumaAudioManifest.json' = Join-Path $gameDir 'reframework\data\PumaAudioManifest.json'
    'reframework/data/HorseAudioManifest.json' = Join-Path $gameDir 'reframework\data\HorseAudioManifest.json'
}

$modInfo = @'
[Mod]
name=IRIS - Assets (multi-pak)
version=3.3.3
description=Every I.R.I.S. custom asset in one Fluffy mod: griffin egg/nest/shells, wild horses, wild cats (puma/panther), baby bundle + bassinet, woodcutting/mining tools, ritual music and farmland. Includes the Wild Cats/Horses runtime scripts and audio manifests. Horse locomotion uses the field-proven compressed Walk/Trot/Gallop motlist; v3.3.3 repairs horse durability and cat recognition, bank loading and native-template vocal fallback. Replaces the separate IRIS asset mods; uninstall those first. Requires REFramework.
author=Aurora, Lyra and Iris
'@

foreach ($path in $runtimeFiles.Values) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Runtime file missing: $path"
    }
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$source = [System.IO.Compression.ZipFile]::OpenRead($archivePath)
$output = [System.IO.Compression.ZipFile]::Open(
    $buildPath, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    $modEntry = $output.CreateEntry(
        'modinfo.ini', [System.IO.Compression.CompressionLevel]::Optimal)
    $modStream = $modEntry.Open()
    try {
        $writer = [System.IO.StreamWriter]::new(
            $modStream, [System.Text.UTF8Encoding]::new($false), 1024, $true)
        try { $writer.Write($modInfo) } finally { $writer.Dispose() }
    } finally { $modStream.Dispose() }

    foreach ($name in $pakNames) {
        $sourceEntry = $source.GetEntry($name)
        if ($null -eq $sourceEntry) { throw "PAK entry missing from source archive: $name" }
        $destEntry = $output.CreateEntry(
            $name, [System.IO.Compression.CompressionLevel]::Optimal)
        $inputStream = $sourceEntry.Open()
        $outputStream = $destEntry.Open()
        try { $inputStream.CopyTo($outputStream) }
        finally {
            $outputStream.Dispose()
            $inputStream.Dispose()
        }
    }

    foreach ($pair in $runtimeFiles.GetEnumerator()) {
        $entry = $output.CreateEntry(
            $pair.Key, [System.IO.Compression.CompressionLevel]::Optimal)
        $inputStream = [System.IO.File]::OpenRead($pair.Value)
        $outputStream = $entry.Open()
        try { $inputStream.CopyTo($outputStream) }
        finally {
            $outputStream.Dispose()
            $inputStream.Dispose()
        }
    }
} finally {
    $output.Dispose()
    $source.Dispose()
}

$expectedNames = @('modinfo.ini') + $pakNames + @($runtimeFiles.Keys)
$check = [System.IO.Compression.ZipFile]::OpenRead($buildPath)
try {
    foreach ($name in $expectedNames) {
        if ($null -eq $check.GetEntry($name)) { throw "Built archive is missing: $name" }
    }
    if ($check.Entries.Count -ne $expectedNames.Count) {
        throw "Built archive contains $($check.Entries.Count) entries; expected $($expectedNames.Count)"
    }
} finally {
    $check.Dispose()
}

if (-not (Test-Path -LiteralPath $backupPath)) {
    Copy-Item -LiteralPath $archivePath -Destination $backupPath
}
Move-Item -LiteralPath $buildPath -Destination $archivePath -Force

Get-Item -LiteralPath $archivePath | Select-Object FullName, Length, LastWriteTime
Get-FileHash -Algorithm SHA256 -LiteralPath $archivePath
