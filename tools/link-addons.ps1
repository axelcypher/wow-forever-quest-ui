<#
.SYNOPSIS
  Verlinkt ForeverQuestUI und ForeverQuestUI_Data per Junction in den AddOns-Ordner von WoW Forever.

.DESCRIPTION
  Änderungen im Repo sind danach nach einem /reload im Spiel sichtbar.
  Bestehende echte Ordner werden nicht überschrieben.

.EXAMPLE
  .\tools\link-addons.ps1 -AddOnsPath "F:\Battle.net\World of Warcraft\_forever_\Interface\AddOns"
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$AddOnsPath
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$addons = @('ForeverQuestUI', 'ForeverQuestUI_Data')

if (-not (Test-Path $AddOnsPath)) {
    throw "AddOns-Ordner nicht gefunden: $AddOnsPath"
}

foreach ($name in $addons) {
    $source = Join-Path $root $name
    $target = Join-Path $AddOnsPath $name

    if (Test-Path $target) {
        $item = Get-Item $target -Force
        if ($item.LinkType -eq 'Junction') {
            Write-Host "$name ist schon verlinkt."
            continue
        }
        Write-Warning "$target existiert als echter Ordner und wird nicht angefasst."
        continue
    }

    New-Item -ItemType Junction -Path $target -Target $source | Out-Null
    Write-Host "$name -> $source"
}
