# Baut dist/Fightclub-<Version>.zip für CurseForge: nur Laufzeitdateien, oberster Ordner "Fightclub", Pfade mit "/".
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$toc = Get-Content (Join-Path $root 'Fightclub.toc')
$version = @($toc | Where-Object { $_ -match '^## Version:\s*(.+)$' } | ForEach-Object { $Matches[1].Trim() })[0]
if (-not $version) { throw 'Keine ## Version in Fightclub.toc' }

# Lua-Dateien in der .toc müssen alle existieren
$missing = $toc | Where-Object { $_ -match '\.lua$' } | Where-Object { -not (Test-Path (Join-Path $root $_.Trim())) }
if ($missing) { throw "In der .toc aber nicht vorhanden: $($missing -join ', ')" }

$dist = Join-Path $root 'dist'
New-Item -ItemType Directory -Force $dist | Out-Null
$zipPath = Join-Path $dist "Fightclub-$version.zip"
if (Test-Path $zipPath) { Remove-Item $zipPath }

Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$files = @(Get-ChildItem $root -File | Where-Object { $_.Extension -in '.lua', '.toc' -or $_.Name -eq 'LICENSE' })
$files += Get-ChildItem (Join-Path $root 'Media') -File -Recurse
$zip = [IO.Compression.ZipFile]::Open($zipPath, 'Create')
try {
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($root.Length + 1).Replace('\', '/')
        [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $f.FullName, "Fightclub/$rel", 'Optimal')
    }
} finally { $zip.Dispose() }
Write-Host "$zipPath ($($files.Count) Dateien)"
