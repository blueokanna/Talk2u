[CmdletBinding()]
param(
    [string]$ApkPath = '',

    [switch]$RequireOfflineCubismCore
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$failures = [System.Collections.Generic.List[string]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()
Add-Type -AssemblyName System.Web.Extensions
$jsonSerializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$jsonSerializer.MaxJsonLength = [int]::MaxValue

function Write-Check {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][bool]$Passed,
        [Parameter(Mandatory = $true)][string]$Details
    )

    $status = if ($Passed) { 'PASS' } else { 'FAIL' }
    $color = if ($Passed) { 'Green' } else { 'Red' }
    Write-Host "[$status] $Name - $Details" -ForegroundColor $color
    if (-not $Passed) {
        $failures.Add("$Name`: $Details")
    }
}

function Test-Live2dModel {
    param([Parameter(Mandatory = $true)][string]$ModelSettingsPath)

    $settingsFile = Get-Item -LiteralPath $ModelSettingsPath
    $modelRoot = $settingsFile.Directory.FullName
    $settings = $jsonSerializer.DeserializeObject(
        (Get-Content -Raw -Encoding UTF8 -LiteralPath $settingsFile.FullName)
    )
    $name = $settingsFile.BaseName
    Write-Check "$name model3" ($settings['Version'] -eq 3) "Version=$($settings['Version'])"

    $references = $settings['FileReferences']
    $mocPath = Join-Path $modelRoot $references['Moc']
    if (-not (Test-Path -LiteralPath $mocPath -PathType Leaf)) {
        Write-Check "$name moc3" $false "missing $mocPath"
        return
    }
    $mocBytes = [System.IO.File]::ReadAllBytes($mocPath)
    $signature = if ($mocBytes.Length -ge 5) {
        [System.Text.Encoding]::ASCII.GetString($mocBytes, 0, 4)
    } else {
        ''
    }
    $mocVersion = if ($mocBytes.Length -ge 5) { [int]$mocBytes[4] } else { -1 }
    Write-Check "$name moc3" ($signature -eq 'MOC3' -and $mocVersion -eq 5) `
        "signature=$signature, version=$mocVersion, bytes=$($mocBytes.Length)"

    $displayInfoReference = $references['DisplayInfo']
    if ([string]::IsNullOrWhiteSpace($displayInfoReference)) {
        Write-Check "$name cdi3" $false 'FileReferences.DisplayInfo is missing'
        return
    }
    $displayInfoPath = Join-Path $modelRoot $displayInfoReference
    if (-not (Test-Path -LiteralPath $displayInfoPath -PathType Leaf)) {
        Write-Check "$name cdi3" $false "missing $displayInfoPath"
        return
    }
    $displayInfo = $jsonSerializer.DeserializeObject(
        (Get-Content -Raw -Encoding UTF8 -LiteralPath $displayInfoPath)
    )
    Write-Check "$name cdi3" ($displayInfo['Version'] -eq 3) "Version=$($displayInfo['Version'])"

    $lipSyncIds = @($settings['Groups'] | Where-Object { $_['Name'] -eq 'LipSync' } | ForEach-Object { $_['Ids'] })
    if ($lipSyncIds.Count -eq 0) {
        $lipSyncIds = @($displayInfo['Parameters'] | Where-Object {
            $_['Id'] -in @('ParamMouthOpenY', 'ParamA') -or $_['Name'] -eq 'Mouth Open'
        } | ForEach-Object { $_['Id'] })
    }
    Write-Check "$name LipSync" ($lipSyncIds.Count -gt 0) ($lipSyncIds -join ', ')

    $textures = @($references['Textures'])
    $missingTextures = @($textures | Where-Object {
        -not (Test-Path -LiteralPath (Join-Path $modelRoot $_) -PathType Leaf)
    })
    Write-Check "$name textures" ($missingTextures.Count -eq 0) `
        "declared=$($textures.Count), missing=$($missingTextures.Count)"
}

Push-Location $repositoryRoot
try {
    Test-Live2dModel 'model/mao/runtime/mao_pro.model3.json'
    $optionalReferenceModel = 'model/Custom_Suiika/Custom_Suiika_V1_03_2k.model3.json'
    if (Test-Path -LiteralPath $optionalReferenceModel -PathType Leaf) {
        Test-Live2dModel $optionalReferenceModel
    } else {
        $warnings.Add("Optional reference model was not found at $optionalReferenceModel; skipping it.")
        Write-Host '[WARN] Custom_Suiika - optional reference model not installed' -ForegroundColor Yellow
    }

    foreach ($runtimeFile in @(
        'assets/live2d/index.html',
        'assets/live2d/vendor/pixi.min.js',
        'assets/live2d/vendor/cubism4.min.js',
        'android/app/src/main/cpp/CMakeLists.txt',
        'android/app/src/main/cpp/gpu_backend_probe.cpp'
    )) {
        Write-Check $runtimeFile (Test-Path -LiteralPath $runtimeFile -PathType Leaf) 'required runtime file'
    }

    $corePath = 'assets/live2d/vendor/live2dcubismcore.min.js'
    $hasLocalCore = Test-Path -LiteralPath $corePath -PathType Leaf
    if ($RequireOfflineCubismCore) {
        Write-Check 'offline Cubism Core' $hasLocalCore $corePath
    } elseif ($hasLocalCore) {
        Write-Host "[PASS] offline Cubism Core - $corePath" -ForegroundColor Green
    } else {
        $warnings.Add('Cubism Core 5 is not local; Live2D needs the official HTTPS CDN at runtime.')
        Write-Host '[WARN] offline Cubism Core - not installed; online fallback only' -ForegroundColor Yellow
    }

    if ([string]::IsNullOrWhiteSpace($ApkPath)) {
        $ApkPath = 'build/app/outputs/flutter-apk/app-debug.apk'
    }
    if (Test-Path -LiteralPath $ApkPath -PathType Leaf) {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $ApkPath))
        try {
            $entries = @($archive.Entries | ForEach-Object { $_.FullName })
            foreach ($library in @(
                'lib/arm64-v8a/libflutter.so',
                'lib/arm64-v8a/librust_lib_talk2u.so',
                'lib/arm64-v8a/libtalk2u_gpu_probe.so'
            )) {
                Write-Check "APK $library" ($library -in $entries) $ApkPath
            }
            $otherAbis = @($entries | Where-Object {
                $_ -match '^lib/(armeabi-v7a|x86|x86_64)/.+\.so$'
            })
            Write-Check 'APK ABI scope' ($otherAbis.Count -eq 0) `
                "unexpected non-arm64 libraries=$($otherAbis.Count)"
        } finally {
            $archive.Dispose()
        }
    } else {
        $warnings.Add("APK was not found at $ApkPath; build it before release verification.")
        Write-Host "[WARN] APK - not found at $ApkPath" -ForegroundColor Yellow
    }
} finally {
    Pop-Location
}

foreach ($warning in $warnings) {
    Write-Warning $warning
}
if ($failures.Count -gt 0) {
    throw "Runtime verification failed with $($failures.Count) error(s)."
}
Write-Host 'Runtime verification completed without errors.' -ForegroundColor Green
