[CmdletBinding()]
param(
    [string]$SdkRoot = '',

    [string]$FlutterRoot = '',

    [Parameter(Mandatory = $true)]
    [switch]$AcceptAndroidLicenses
)

$ErrorActionPreference = 'Stop'

if (-not $AcceptAndroidLicenses) {
    throw 'Android SDK licenses must be reviewed and accepted before installation.'
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($SdkRoot)) {
    $SdkRoot = Join-Path $repositoryRoot '.android-sdk'
}
$resolvedSdkRoot = [System.IO.Path]::GetFullPath($SdkRoot)
$commandLineToolsUrl = 'https://dl.google.com/android/repository/commandlinetools-win-13114758_latest.zip'
$archivePath = Join-Path $resolvedSdkRoot 'commandlinetools-win-13114758_latest.zip'
$latestTools = Join-Path $resolvedSdkRoot 'cmdline-tools\latest'
$sdkManager = Join-Path $latestTools 'bin\sdkmanager.bat'

New-Item -ItemType Directory -Path $resolvedSdkRoot -Force | Out-Null

if (-not (Test-Path -LiteralPath $sdkManager -PathType Leaf)) {
    if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
        Write-Host "Downloading Android command-line tools from $commandLineToolsUrl"
        Invoke-WebRequest -UseBasicParsing $commandLineToolsUrl -OutFile $archivePath
    }

    $staging = Join-Path $resolvedSdkRoot ("cmdline-tools-staging-" + [DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
    Expand-Archive -LiteralPath $archivePath -DestinationPath $staging
    $extracted = Join-Path $staging 'cmdline-tools'
    if (-not (Test-Path -LiteralPath (Join-Path $extracted 'bin\sdkmanager.bat'))) {
        throw "Downloaded command-line tools have an unexpected layout: $archivePath"
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $latestTools) -Force | Out-Null
    Move-Item -LiteralPath $extracted -Destination $latestTools
}

$packages = @(
    'platform-tools',
    'platforms;android-36',
    'build-tools;36.0.0',
    'ndk;28.0.12674087',
    'cmake;3.22.1',
    'cmake;3.31.0'
)

$licenseAnswers = 1..30 | ForEach-Object { 'y' }
$licenseAnswers | & $sdkManager "--sdk_root=$resolvedSdkRoot" --licenses | Out-Host
& $sdkManager "--sdk_root=$resolvedSdkRoot" $packages | Out-Host
if ($LASTEXITCODE -ne 0) {
    throw "sdkmanager failed with exit code $LASTEXITCODE"
}

$localProperties = Join-Path $repositoryRoot 'android\local.properties'
if ([string]::IsNullOrWhiteSpace($FlutterRoot)) {
    $flutterCommand = Get-Command flutter -ErrorAction SilentlyContinue
    if ($null -eq $flutterCommand) {
        throw 'Flutter was not found on PATH. Pass -FlutterRoot C:\path\to\flutter.'
    }
    $FlutterRoot = Split-Path -Parent (Split-Path -Parent $flutterCommand.Source)
}
$resolvedFlutterRoot = (Resolve-Path -LiteralPath $FlutterRoot).Path
if (-not (Test-Path -LiteralPath (Join-Path $resolvedFlutterRoot 'bin\flutter.bat') -PathType Leaf)) {
    throw "Invalid Flutter SDK directory: $resolvedFlutterRoot"
}
$escapeForProperties = { param([string]$value) $value.Replace('\', '\\') }
$properties = @(
    "flutter.sdk=$(& $escapeForProperties $resolvedFlutterRoot)",
    "sdk.dir=$(& $escapeForProperties $resolvedSdkRoot)"
)
[System.IO.File]::WriteAllLines($localProperties, $properties, [System.Text.UTF8Encoding]::new($false))

Write-Host "Android SDK ready: $resolvedSdkRoot"
Write-Host "Updated: $localProperties"
