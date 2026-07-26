[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SdkRoot,

    [Parameter(Mandatory = $true)]
    [switch]$AcceptLive2DLicense
)

$ErrorActionPreference = 'Stop'

if (-not $AcceptLive2DLicense) {
    throw 'Read and accept the Live2D Proprietary Software License before installing Cubism Core.'
}

$resolvedSdkRoot = (Resolve-Path -LiteralPath $SdkRoot).Path
$candidatePaths = @(
    (Join-Path $resolvedSdkRoot 'Core\live2dcubismcore.min.js'),
    (Join-Path $resolvedSdkRoot 'live2dcubismcore.min.js')
)
$sourcePath = $candidatePaths | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1

if ($null -eq $sourcePath) {
    $sourcePath = Get-ChildItem -LiteralPath $resolvedSdkRoot -Filter 'live2dcubismcore.min.js' -File -Recurse |
        Select-Object -First 1 -ExpandProperty FullName
}
if ($null -eq $sourcePath) {
    throw "live2dcubismcore.min.js was not found below $resolvedSdkRoot"
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$targetPath = Join-Path $repositoryRoot 'assets\live2d\vendor\live2dcubismcore.min.js'
Copy-Item -LiteralPath $sourcePath -Destination $targetPath -Force

$installed = Get-Item -LiteralPath $targetPath
$hash = Get-FileHash -LiteralPath $targetPath -Algorithm SHA256
Write-Host "Installed Cubism Core: $($installed.FullName)"
Write-Host "Size: $($installed.Length) bytes"
Write-Host "SHA256: $($hash.Hash)"
Write-Host 'Rebuild the APK so Flutter packages the newly installed asset.'
