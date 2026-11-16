# Runs the same gates as .github/workflows/quality.yml on a developer machine.
#
#   pwsh tools/run_quality_checks.ps1
#   pwsh tools/run_quality_checks.ps1 -SkipRust -SkipAndroid
#
# Every step prints the command it runs and stops on the first failure, so the
# local result matches the CI job order.
[CmdletBinding()]
param(
    [switch]$SkipRust,
    [switch]$SkipFlutter,
    [switch]$SkipAndroid
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$script:failed = 0
$script:step = 0

function Invoke-Step {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Command,
        [string]$WorkingDirectory = $repoRoot
    )
    $script:step++
    Write-Host "==> [$script:step] $Name"
    Write-Host "    $Command" -ForegroundColor DarkGray
    $started = Get-Date
    Push-Location $WorkingDirectory
    try {
        & ([scriptblock]::Create($Command))
        if ($LASTEXITCODE -ne 0) { throw "exit code $LASTEXITCODE" }
    }
    catch {
        $script:failed++
        Write-Host "    FAILED: $_" -ForegroundColor Red
    }
    finally {
        Pop-Location
        $elapsed = (Get-Date) - $started
        Write-Host ("    {0:hh\:mm\:ss}" -f $elapsed) -ForegroundColor DarkGray
    }
}

if (-not $SkipRust) {
    Invoke-Step 'Rust formatting'         'cargo fmt --check' 'rust'
    Invoke-Step 'Rust lints'              'cargo clippy --all-targets -- -D warnings' 'rust'
    Invoke-Step 'Rust tests'              'cargo test --all-targets' 'rust'
}

if (-not $SkipFlutter) {
    Invoke-Step 'Flutter dependencies'    'flutter pub get'
    Invoke-Step 'Dart formatting'         'dart format --output=none --set-exit-if-changed lib test'
    Invoke-Step 'Dart analyzer'           'flutter analyze lib test'
    Invoke-Step 'Flutter tests'           'flutter test --no-pub'
    Invoke-Step 'Avatar frame gate'       'node --test --test-isolation=none test/rendering/avatar_frame_gate_test.cjs'
    Invoke-Step 'Native host tooling'     'python -m unittest discover -s tools -p "test_*.py" -v'
}

if (-not $SkipAndroid) {
    Invoke-Step 'Android JVM unit tests' `
        'bash gradlew --no-daemon :app:testDebugUnitTest -Ptalk2u.cubismSdkRoot=/nonexistent -Ptalk2u.requireCubism=false' `
        'android'
}

if ($script:failed -gt 0) {
    Write-Host "$script:failed step(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host 'All quality gates passed.' -ForegroundColor Green
