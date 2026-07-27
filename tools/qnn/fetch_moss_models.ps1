param(
    [string]$Destination = (Join-Path $PSScriptRoot '..\..\model-sources\moss'),
    [string]$Python = $env:TALK2U_PYTHON
)

$ErrorActionPreference = 'Stop'
if (!$Python) {
    $candidates = @(
        'C:\Program Files\NVIDIA Corporation\Nsight Compute 2026.1.0\host\target-windows-x64\python\bin\python.exe',
        'python.exe'
    )
    $Python = $candidates | Where-Object { $_ -eq 'python.exe' -or (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1
}
if (!$Python) { throw 'Set TALK2U_PYTHON to a Python 3.10+ executable' }
$downloader = Join-Path $PSScriptRoot 'download_url.py'
$assets = @(
    @('OpenMOSS-Team/MOSS-TTS-Nano-100M-ONNX', 'f52645cb467506d8e18e746ddd59482685b74e58', 'MOSS-TTS-Nano-100M-ONNX', 'browser_poc_manifest.json', 503354, '097d80e993dc29f0bae427590b4f77084a161cb578b50d82c29f455d5faa9eee'),
    @('OpenMOSS-Team/MOSS-TTS-Nano-100M-ONNX', 'f52645cb467506d8e18e746ddd59482685b74e58', 'MOSS-TTS-Nano-100M-ONNX', 'tts_browser_onnx_meta.json', 4487, '3edf25232dcd0af3d061c837e9a968a39e2f8592e06777d740503c4f2244f95c'),
    @('OpenMOSS-Team/MOSS-TTS-Nano-100M-ONNX', 'f52645cb467506d8e18e746ddd59482685b74e58', 'MOSS-TTS-Nano-100M-ONNX', 'tokenizer.model', 470897, 'c353ee1479b536bf414c1b247f5542b6607fb8ae91320e5af1781fee200fddff'),
    @('OpenMOSS-Team/MOSS-TTS-Nano-100M-ONNX', 'f52645cb467506d8e18e746ddd59482685b74e58', 'MOSS-TTS-Nano-100M-ONNX', 'moss_tts_prefill.onnx', 283305, 'd56126dcd0574c2f15d98fc6b35eda68d0386b5bd9c5e38e28548d6f2ea8f3db'),
    @('OpenMOSS-Team/MOSS-TTS-Nano-100M-ONNX', 'f52645cb467506d8e18e746ddd59482685b74e58', 'MOSS-TTS-Nano-100M-ONNX', 'moss_tts_decode_step.onnx', 291483, '698cbc2fc1c2feca16e5895614ed52bbb32ded10f236c076f477b2e69abf32d8'),
    @('OpenMOSS-Team/MOSS-TTS-Nano-100M-ONNX', 'f52645cb467506d8e18e746ddd59482685b74e58', 'MOSS-TTS-Nano-100M-ONNX', 'moss_tts_local_fixed_sampled_frame.onnx', 471262, '40cdb00efc171c450cf91468e01429caa41b0252222cd308e978f58fe354afa8'),
    @('OpenMOSS-Team/MOSS-TTS-Nano-100M-ONNX', 'f52645cb467506d8e18e746ddd59482685b74e58', 'MOSS-TTS-Nano-100M-ONNX', 'moss_tts_global_shared.data', 440813568, 'bce8312c3df6a44545302cae229b61054fe0672e0b252ba59cba47adeed831dc'),
    @('OpenMOSS-Team/MOSS-TTS-Nano-100M-ONNX', 'f52645cb467506d8e18e746ddd59482685b74e58', 'MOSS-TTS-Nano-100M-ONNX', 'moss_tts_local_shared.data', 229678080, 'bae7782032c0fb12490ab42afe009f87ae6c75a0f0596fc7b5c08e4d5ee93916'),
    @('OpenMOSS-Team/MOSS-Audio-Tokenizer-Nano-ONNX', 'ceff0d0749bfb3fa2d61149794ec6feef0d1e1ae', 'MOSS-Audio-Tokenizer-Nano-ONNX', 'codec_browser_onnx_meta.json', 17036, '3e291c883bb7d11ff2fe8e964e3e495519760358859f35c951254c7741592731'),
    @('OpenMOSS-Team/MOSS-Audio-Tokenizer-Nano-ONNX', 'ceff0d0749bfb3fa2d61149794ec6feef0d1e1ae', 'MOSS-Audio-Tokenizer-Nano-ONNX', 'moss_audio_tokenizer_decode_full.onnx', 681902, '0fbbafe3fd4afa2a019af5c5ced204af6e2d1db044fa40f021525d2aee95b4ac'),
    @('OpenMOSS-Team/MOSS-Audio-Tokenizer-Nano-ONNX', 'ceff0d0749bfb3fa2d61149794ec6feef0d1e1ae', 'MOSS-Audio-Tokenizer-Nano-ONNX', 'moss_audio_tokenizer_decode_shared.data', 44198912, 'e69d52e0f4e84ca27850557ee54face46632d3a5a16c89bd246c7c408466dcad')
)

foreach ($asset in $assets) {
    $repository, $revision, $directory, $name, $expectedLength, $expectedSha256 = $asset
    $targetDirectory = Join-Path $Destination $directory
    $target = Join-Path $targetDirectory $name
    New-Item -ItemType Directory -Force -Path $targetDirectory | Out-Null
    $valid = Test-Path -LiteralPath $target -PathType Leaf
    if ($valid) {
        $file = Get-Item -LiteralPath $target
        $valid = $file.Length -eq $expectedLength -and (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -eq $expectedSha256
    }
    if ($valid) {
        Write-Host "Verified $directory/$name"
        continue
    }
    $urls = @(
        "https://huggingface.co/$repository/resolve/$revision/${name}?download=true",
        "https://hf-mirror.com/$repository/resolve/$revision/${name}?download=true"
    )
    Write-Host "Downloading $directory/$name"
    & $Python $downloader $target $urls
    if ($LASTEXITCODE -ne 0) { throw "All download sources failed for $directory/$name" }
    $file = Get-Item -LiteralPath $target
    if ($file.Length -ne $expectedLength) { throw "Size mismatch for $target" }
    $actualSha256 = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualSha256 -ne $expectedSha256) { throw "SHA-256 mismatch for $target" }
}

Write-Host "MOSS sources verified at $Destination"
