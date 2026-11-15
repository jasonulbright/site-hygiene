<#
.SYNOPSIS
    Copies the guide images that the README shows over the README image files.

.DESCRIPTION
    The README shows images that live outside docs\images. The file readme-images.json maps each README
    image path to the docs\images file that it is a copy of. Run the guide capture first, then this script.
    The command stops when a source image is missing.

.PARAMETER RepoRoot
    The repository folder. The default is the repository that holds this script.

.EXAMPLE
    .\tools\guide-capture\Sync-ReadmeImages.ps1
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
)
$ErrorActionPreference = 'Stop'
$mapPath = Join-Path $PSScriptRoot 'readme-images.json'
$map = Get-Content -LiteralPath $mapPath -Raw | ConvertFrom-Json
$missing = @()
foreach ($entry in $map.PSObject.Properties) {
    $source = Join-Path $RepoRoot ($entry.Value -replace '/', '\')
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { $missing += $entry.Value }
}
if ($missing.Count) { throw ('A source image is missing: ' + ($missing -join ', ')) }
foreach ($entry in $map.PSObject.Properties) {
    $source = Join-Path $RepoRoot ($entry.Value -replace '/', '\')
    $target = Join-Path $RepoRoot ($entry.Name -replace '/', '\')
    Copy-Item -LiteralPath $source -Destination $target -Force
    Write-Verbose ('{0} <- {1}' -f $entry.Name, $entry.Value)
}
