[CmdletBinding()]
param([switch] $Apply)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$applicationRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$tempRoot = [IO.Path]::GetFullPath((Join-Path $applicationRoot "temp\imagemagick"))
if (-not (Test-Path -LiteralPath $tempRoot -PathType Container)) {
    Write-Host "No ImageMagick temp directory exists."
    return
}

$allowedPrefix = $tempRoot + [IO.Path]::DirectorySeparatorChar
$runs = @(Get-ChildItem -LiteralPath $tempRoot -Directory)
if ($runs.Count -eq 0) {
    Write-Host "No ImageMagick temp runs exist."
    return
}

foreach ($run in $runs) {
    $resolved = [IO.Path]::GetFullPath($run.FullName)
    if (-not $resolved.StartsWith($allowedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing unexpected temp path: $resolved"
    }
    if ($Apply) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
        Write-Host "Removed $resolved"
    }
    else {
        Write-Host "Would remove $resolved"
    }
}

if (-not $Apply) {
    Write-Host "Preview only. Run again with -Apply to remove these temp runs."
}
