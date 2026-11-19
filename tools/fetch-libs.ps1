<#
.SYNOPSIS
  Holt die Bibliotheken für das Minimap-Symbol nach ForeverQuestUI\Libs.

.DESCRIPTION
  Die Libs werden nicht eingecheckt (siehe .gitignore). Beim Paketieren holt der BigWigs-Packager sie über die
  externals in .pkgmeta, lokal übernimmt das dieses Skript. Beide Stellen zusammen ändern.

  Ohne die Libs läuft das Addon trotzdem, nur ohne Minimap-Symbol.

  Quellen:
    LibStub, CallbackHandler-1.0  WoWUIDev/Ace3, neuester Release-Tag (Lizenz: LICENSE.txt aus Ace3)
    LibDataBroker-1.1             tekkub/libdatabroker-1-1, neuester Tag
    LibDBIcon-1.0                 WowAce-SVN libdbicon-1-0, trunk (es gibt kein offizielles Git-Repo)

.EXAMPLE
  .\tools\fetch-libs.ps1
#>
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$root = Split-Path -Parent $PSScriptRoot
$libs = Join-Path $root 'ForeverQuestUI\Libs'
$temp = Join-Path ([IO.Path]::GetTempPath()) ('fqui-libs-' + [Guid]::NewGuid().ToString('N'))

$ace3Url = 'https://github.com/WoWUIDev/Ace3'
$ldbUrl = 'https://github.com/tekkub/libdatabroker-1-1'
$dbiconUrl = 'https://repos.wowace.com/wow/libdbicon-1-0/trunk/LibDBIcon-1.0'

# Neuester Tag eines Git-Repos (wie "tag: latest" im Packager).
function Get-LatestTag([string]$url, [string]$pattern) {
    # Erst alles einlesen: Select-Object -First würde git vorzeitig beenden und den Exit-Code verfälschen.
    $lines = @(git ls-remote --tags --refs --sort=-v:refname $url $pattern)
    if ($LASTEXITCODE -ne 0 -or $lines.Count -eq 0) { throw "Kein Tag gefunden: $url ($pattern)" }
    return ($lines[0] -split 'refs/tags/')[1].Trim()
}

function Get-ShallowClone([string]$url, [string]$tag, [string]$name) {
    $dir = Join-Path $temp $name
    git -c advice.detachedHead=false clone --quiet --depth 1 --branch $tag $url $dir
    if ($LASTEXITCODE -ne 0) { throw "git clone fehlgeschlagen: $url ($tag)" }
    return $dir
}

# Leert den Zielordner einer Lib und legt ihn neu an.
function New-LibFolder([string]$name) {
    $target = Join-Path $libs $name
    if (Test-Path $target) { Remove-Item -Recurse -Force $target }
    New-Item -ItemType Directory -Force $target | Out-Null
    return $target
}

New-Item -ItemType Directory -Force $temp | Out-Null
try {
    # LibStub und CallbackHandler-1.0 aus Ace3
    $tag = Get-LatestTag $ace3Url 'Release-r*'
    $ace3 = Get-ShallowClone $ace3Url $tag 'Ace3'
    foreach ($name in @('LibStub', 'CallbackHandler-1.0')) {
        $target = New-LibFolder $name
        Copy-Item -Path (Join-Path $ace3 "$name\*") -Destination $target -Recurse
        Copy-Item -Path (Join-Path $ace3 'LICENSE.txt') -Destination $target
    }
    Write-Host "Ace3 $tag -> Libs\LibStub, Libs\CallbackHandler-1.0"

    # LibDataBroker-1.1 (keine eigene Lizenzdatei, die README geht mit)
    $tag = Get-LatestTag $ldbUrl 'v*'
    $ldb = Get-ShallowClone $ldbUrl $tag 'LibDataBroker'
    $target = New-LibFolder 'LibDataBroker-1.1'
    Copy-Item -Path (Join-Path $ldb 'LibDataBroker-1.1.lua') -Destination $target
    Copy-Item -Path (Join-Path $ldb 'README.textile') -Destination $target
    Write-Host "LibDataBroker-1.1 $tag -> Libs\LibDataBroker-1.1"

    # LibDBIcon-1.0: der SVN-Server liefert einzelne Dateien auch per HTTP aus, svn ist also nicht nötig.
    $listing = (Invoke-WebRequest -UseBasicParsing "$dbiconUrl/").Content
    $revision = if ($listing -match 'Revision (\d+)') { "r$($Matches[1])" } else { 'trunk' }
    $target = New-LibFolder 'LibDBIcon-1.0'
    foreach ($file in @('LibDBIcon-1.0.lua', 'lib.xml')) {
        Invoke-WebRequest -UseBasicParsing "$dbiconUrl/$file" -OutFile (Join-Path $target $file)
    }
    $minor = Select-String -Path (Join-Path $target 'LibDBIcon-1.0.lua') -Pattern 'DBICON10_MINOR = (\d+)' |
        Select-Object -First 1
    $minorText = if ($minor) { "MINOR $($minor.Matches[0].Groups[1].Value)" } else { 'MINOR ?' }
    Write-Host "LibDBIcon-1.0 $revision ($minorText) -> Libs\LibDBIcon-1.0"
}
finally {
    if (Test-Path $temp) { Remove-Item -Recurse -Force $temp }
}
