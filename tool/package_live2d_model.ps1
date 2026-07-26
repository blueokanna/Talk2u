[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ModelDirectory,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$resolvedModelDirectory = (Resolve-Path -LiteralPath $ModelDirectory).Path
$modelFiles = Get-ChildItem -LiteralPath $resolvedModelDirectory -Filter '*.model3.json' -File -Recurse

if ($modelFiles.Count -ne 1) {
    throw "Expected exactly one .model3.json below $resolvedModelDirectory; found $($modelFiles.Count)."
}
if (Test-Path -LiteralPath $OutputPath) {
    throw "Output already exists: $OutputPath"
}

$modelFile = $modelFiles[0]
$modelRoot = Split-Path -Parent $modelFile.FullName
Add-Type -AssemblyName System.Web.Extensions
$jsonSerializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$jsonSerializer.MaxJsonLength = [int]::MaxValue
$model = $jsonSerializer.DeserializeObject(
    (Get-Content -Raw -Encoding UTF8 -LiteralPath $modelFile.FullName)
)
if ($model['Version'] -ne 3) {
    throw 'The model settings file must be .model3.json Version 3.'
}
$references = $model['FileReferences']
if ($null -eq $references) {
    throw 'The model settings file has no FileReferences object.'
}

function Resolve-ModelReference {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    if ([string]::IsNullOrWhiteSpace($RelativePath) -or
        [System.IO.Path]::IsPathRooted($RelativePath) -or
        $RelativePath.Contains('://')) {
        throw "Invalid local model reference: $RelativePath"
    }
    $candidate = [System.IO.Path]::GetFullPath((Join-Path $modelRoot $RelativePath))
    $allowedRoot = $resolvedModelDirectory.TrimEnd('\') + '\'
    if (-not $candidate.StartsWith($allowedRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw "Missing or out-of-tree model resource: $RelativePath"
    }
    return $candidate
}

$mocPath = Resolve-ModelReference -RelativePath $references['Moc']
$mocHeader = [byte[]]::new(8)
$mocStream = [System.IO.File]::OpenRead($mocPath)
try {
    if ($mocStream.Read($mocHeader, 0, $mocHeader.Length) -ne $mocHeader.Length) {
        throw "Invalid moc3 header: $mocPath"
    }
} finally {
    $mocStream.Dispose()
}
$signature = [System.Text.Encoding]::ASCII.GetString($mocHeader, 0, 4)
$mocVersion = [int]$mocHeader[4]
if ($signature -ne 'MOC3' -or $mocVersion -lt 1 -or $mocVersion -gt 5) {
    throw "The model is not a Cubism 3-5 moc3 runtime file (signature=$signature, version=$mocVersion)."
}

$textures = @($references['Textures'])
if ($textures.Count -eq 0) {
    throw 'The model has no texture references.'
}
foreach ($texture in $textures) {
    [void](Resolve-ModelReference -RelativePath $texture)
}

foreach ($property in @('Physics', 'Pose', 'UserData')) {
    $reference = $references[$property]
    if (-not [string]::IsNullOrWhiteSpace($reference)) {
        [void](Resolve-ModelReference -RelativePath $reference)
    }
}
foreach ($expression in @($references['Expressions'])) {
    if ($null -ne $expression -and -not [string]::IsNullOrWhiteSpace($expression['File'])) {
        [void](Resolve-ModelReference -RelativePath $expression['File'])
    }
}
$motions = $references['Motions']
if ($null -ne $motions) {
    foreach ($groupName in $motions.Keys) {
        foreach ($motion in @($motions[$groupName])) {
            if ($null -ne $motion -and -not [string]::IsNullOrWhiteSpace($motion['File'])) {
                [void](Resolve-ModelReference -RelativePath $motion['File'])
            }
        }
    }
}

$lipSyncIds = @()
foreach ($group in @($model['Groups'])) {
    if ($null -ne $group -and $group['Name'] -eq 'LipSync') {
        $lipSyncIds += @($group['Ids'])
    }
}
$displayInfoReference = $references['DisplayInfo']
if (-not [string]::IsNullOrWhiteSpace($displayInfoReference)) {
    $displayInfoPath = Resolve-ModelReference -RelativePath $displayInfoReference
    $displayInfo = $jsonSerializer.DeserializeObject(
        (Get-Content -Raw -Encoding UTF8 -LiteralPath $displayInfoPath)
    )
    if ($displayInfo['Version'] -ne 3) {
        throw 'DisplayInfo must be a Version 3 .cdi3.json file.'
    }
    if ($lipSyncIds.Count -eq 0) {
        $lipSyncIds = @($displayInfo['Parameters'] | Where-Object {
            $_['Id'] -in @('ParamMouthOpenY', 'ParamA') -or $_['Name'] -eq 'mouth open'
        } | ForEach-Object { $_['Id'] })
    }
}
if ($lipSyncIds.Count -eq 0) {
    throw 'No LipSync parameter was found in Groups or DisplayInfo.'
}

$outputDirectory = Split-Path -Parent $OutputPath
if ($outputDirectory -and -not (Test-Path -LiteralPath $outputDirectory)) {
    New-Item -ItemType Directory -Path $outputDirectory | Out-Null
}

Compress-Archive -Path (Join-Path $resolvedModelDirectory '*') -DestinationPath $OutputPath -CompressionLevel Optimal
Write-Host "Created $OutputPath"
Write-Host "Model: $($modelFile.FullName)"
Write-Host "moc3 version: $mocVersion"
Write-Host "LipSync parameters: $($lipSyncIds -join ', ')"
