[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ModelDirectory,
    [string]$SdkRoot = 'D:\Qualcomm AI Engine Direct SDK',
    [string]$OutputDirectory = 'qairt-build\qwen3-4b-instruct-2507',
    [ValidateSet('Z4', 'Q4', 'Z8', 'Q5_K')]
    [string]$Quantization = 'Z4',
    [string]$PythonExe = '.tools\python310-embed\python.exe',
    [string]$HtpDeploymentDirectory,
    [switch]$ReuseExistingModelBin,
    [switch]$CreateZip
)

$ErrorActionPreference = 'Stop'
$workspace = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modelRoot = (Resolve-Path $ModelDirectory).Path
$sdk = (Resolve-Path $SdkRoot).Path
$python = (Resolve-Path (Join-Path $workspace $PythonExe)).Path
$output = [IO.Path]::GetFullPath((Join-Path $workspace $OutputDirectory))
$package = Join-Path $output 'package'

$sourceConfig = Get-Content -LiteralPath (Join-Path $modelRoot 'config.json') -Raw | ConvertFrom-Json
if ($sourceConfig.model_type -ne 'qwen3' -or
    $sourceConfig.architectures -notcontains 'Qwen3ForCausalLM') {
    throw 'The source model must declare model_type=qwen3 and Qwen3ForCausalLM.'
}
if ($sourceConfig.vocab_size -ne 151936 -or $sourceConfig.num_hidden_layers -ne 36) {
    throw 'The source model does not match Qwen3-4B-Instruct-2507 dimensions.'
}

New-Item -ItemType Directory -Force $package | Out-Null
$modelBinName = "qwen3-4b-instruct-2507-$($Quantization.ToLowerInvariant()).bin"
$modelBin = Join-Path $package $modelBinName
$composer = Join-Path $sdk 'bin\x86_64-windows-msvc\qnn-genai-transformer-composer'
$env:QNN_SDK_ROOT = $sdk
$env:PYTHONPATH = @(
    (Join-Path $sdk 'lib\python'),
    (Join-Path $workspace '.tools\python310-packages')
) -join ';'
$env:PATH = @(
    (Join-Path $sdk 'bin\x86_64-windows-msvc'),
    (Join-Path $sdk 'lib\x86_64-windows-msvc'),
    $env:PATH
) -join ';'

if ($ReuseExistingModelBin) {
    if (-not (Test-Path -LiteralPath $modelBin -PathType Leaf) -or
        (Get-Item -LiteralPath $modelBin).Length -le 0) {
        throw "Cannot reuse missing or empty Composer output: $modelBin"
    }
} else {
    & $python $composer --model $modelRoot --quantize $Quantization --outfile $modelBin
    if ($LASTEXITCODE -ne 0) { throw "Composer failed with exit code $LASTEXITCODE" }
}
if (-not (Test-Path -LiteralPath $modelBin -PathType Leaf)) {
    throw "Composer did not create $modelBin"
}

$exportedTokenizer = Join-Path (Split-Path $modelBin) 'tokenizer.json'
$sourceTokenizer = Join-Path $modelRoot 'tokenizer.json'
if (-not (Test-Path -LiteralPath $sourceTokenizer -PathType Leaf)) {
    throw 'The source model has no tokenizer.json.'
}
Copy-Item -LiteralPath $sourceTokenizer -Destination $exportedTokenizer -Force

$cpuConfig = [ordered]@{
    dialog = [ordered]@{
        version = 1
        type = 'basic'
        'max-num-tokens' = 768
        context = [ordered]@{
            version = 1
            size = 8192
            'n-vocab' = 151936
            'bos-token' = -1
            'eos-token' = @(151645, 151643)
            'pad-token' = 151643
            'n-embd' = 2560
        }
        sampler = [ordered]@{
            version = 1; seed = 42; temp = 0.7; 'top-k' = 40; 'top-p' = 0.9; greedy = $false
        }
        tokenizer = [ordered]@{ version = 1; path = './tokenizer.json' }
        engine = [ordered]@{
            version = 1
            'n-threads' = 4
            backend = [ordered]@{
                version = 1
                type = 'QnnGenAiTransformer'
                QnnGenAiTransformer = [ordered]@{
                    version = 1; 'kv-quantization' = $true; 'shared-engine' = $false
                }
            }
            model = [ordered]@{
                version = 1
                type = 'library'
                library = [ordered]@{ version = 1; 'model-bin' = "./$modelBinName" }
            }
        }
    }
}
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$cpuConfigJson = $cpuConfig | ConvertTo-Json -Depth 20
[IO.File]::WriteAllText((Join-Path $package 'dialog-cpu.json'), $cpuConfigJson, $utf8NoBom)

$backends = [Collections.ArrayList]::new()
if ($HtpDeploymentDirectory) {
    $resolved = (Resolve-Path $HtpDeploymentDirectory).Path
    $validationPath = Join-Path $resolved 'qnn-validation.json'
    $validation = Get-Content -LiteralPath $validationPath -Raw | ConvertFrom-Json
    if (-not $validation.valid -or $validation.target.soc -ne 'SM8850' -or
        $validation.target.htpArchitecture -ne 'v81') {
        throw 'HTP deployment must include a valid SM8850/v81 qnn-validation.json.'
    }
    Copy-Item -Recurse -Force -Path (Join-Path $resolved '*') -Destination $package
    if (-not (Test-Path -LiteralPath (Join-Path $package 'dialog-htp.json') -PathType Leaf)) {
        throw 'HTP deployment does not contain dialog-htp.json.'
    }
    [void]$backends.Add([ordered]@{
        id = 'qnn-htp'; config = 'dialog-htp.json'; targetSoc = 'SM8850'; htpArchitecture = 'v81'
        contextValidated = $true
    })
}
[void]$backends.Add([ordered]@{ id = 'cpu'; config = 'dialog-cpu.json' })

$files = Get-ChildItem -LiteralPath $package -Recurse -File |
    Where-Object { $_.Name -ne 'talk2u-genie-manifest.json' } |
    ForEach-Object {
    [ordered]@{
        path = $_.FullName.Substring($package.Length + 1).Replace('\', '/')
        bytes = $_.Length
        sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    }
$manifest = [ordered]@{
    schemaVersion = 1
    modelId = 'Qwen/Qwen3-4B-Instruct-2507'
    architecture = 'Qwen3ForCausalLM'
    quantization = $Quantization
    composer = [ordered]@{
        sdkVersion = '2.48.0'; outputBackend = 'QnnGenAiTransformer'; execution = 'host-cpu'
    }
    backends = $backends
    files = @($files)
}
$manifestJson = $manifest | ConvertTo-Json -Depth 20
[IO.File]::WriteAllText(
    (Join-Path $package 'talk2u-genie-manifest.json'),
    $manifestJson,
    $utf8NoBom
)

if ($CreateZip) {
    $zip = Join-Path $output "talk2u-qwen3-4b-instruct-2507-$($Quantization.ToLowerInvariant()).zip"
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip }
    & tar.exe -a -c -f $zip -C $package .
    if ($LASTEXITCODE -ne 0) { throw "ZIP creation failed with exit code $LASTEXITCODE" }
    Write-Output $zip
} else {
    Write-Output $package
}
