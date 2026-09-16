# Timestamped release build.
#
# Every run gets its own output folder and every artifact carries the UTC
# build stamp in its name, e.g.
#
#   dist\LeopardWM-0.2.9-20260616-143005\
#     leopardwm-0.2.9-20260616-143005.exe
#     leopardwm-cli-0.2.9-20260616-143005.exe
#     lwm-0.2.9-20260616-143005.exe
#     leopardwm-watchdog-0.2.9-20260616-143005.exe
#
# The same stamp is embedded in the binaries (--version, startup banner) and
# in the Windows file properties (FileVersion / ProductVersion / Comments)
# because the script exports LEOPARDWM_BUILD_STAMP_EPOCH, which every
# build.rs honors.
#
# Usage:
#   pwsh -File tools\build_timestamped.ps1
#   pwsh -File tools\build_timestamped.ps1 -OutputRoot D:\builds

[CmdletBinding()]
param(
    [string]$RepoRoot = $(if ($PSScriptRoot) { (Resolve-Path (Join-Path $PSScriptRoot '..')).Path } else { (Get-Location).Path }),
    [string]$OutputRoot = 'dist'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Push-Location $RepoRoot
try {
    $utc = [DateTime]::UtcNow
    $stamp = $utc.ToString('yyyyMMdd-HHmmss')
    $unixEpoch = [datetime]::SpecifyKind([datetime]'1970-01-01', [DateTimeKind]::Utc)
    $epoch = [int64]($utc - $unixEpoch).TotalSeconds

    $cargoToml = Get-Content -LiteralPath (Join-Path $RepoRoot 'Cargo.toml') -Raw
    if ($cargoToml -notmatch '(?ms)^\[workspace\.package\].*?^version\s*=\s*"([^"]+)"') {
        throw 'Could not read [workspace.package].version from Cargo.toml'
    }
    $version = $Matches[1]
    $suffix = "$version-$stamp"

    Write-Host "Building LeopardWM $version (stamp $stamp, epoch $epoch)..."
    $env:LEOPARDWM_BUILD_STAMP_EPOCH = $epoch.ToString()
    & cargo build --release
    if ($LASTEXITCODE -ne 0) {
        throw "cargo build --release failed with exit code $LASTEXITCODE"
    }

    $releaseDir = Join-Path $RepoRoot 'target\x86_64-pc-windows-msvc\release'
    if (-not (Test-Path -LiteralPath $releaseDir)) {
        throw "Release directory not found: $releaseDir"
    }

    $outDir = Join-Path (Join-Path $RepoRoot $OutputRoot) "LeopardWM-$suffix"
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null

    $artifacts = @(
        @{ Source = 'leopardwm.exe';          Name = "leopardwm-$suffix.exe" },
        @{ Source = 'leopardwm-cli.exe';      Name = "leopardwm-cli-$suffix.exe" },
        @{ Source = 'lwm.exe';                Name = "lwm-$suffix.exe" },
        @{ Source = 'leopardwm-watchdog.exe'; Name = "leopardwm-watchdog-$suffix.exe" }
    )

    $checksums = New-Object System.Collections.Generic.List[string]
    foreach ($artifact in $artifacts) {
        $source = Join-Path $releaseDir $artifact.Source
        if (-not (Test-Path -LiteralPath $source)) {
            throw "Missing artifact: $source"
        }
        $destination = Join-Path $outDir $artifact.Name
        Copy-Item -LiteralPath $source -Destination $destination -Force
        $hash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
        $checksums.Add("$hash  $($artifact.Name)")
        Write-Host "  $($artifact.Name)"
    }

    # Canonical-name aliases so `lwm run` finds the daemon/watchdog siblings
    # (the CLI resolves them by their standard names via current_exe().parent()).
    # Hardlinks keep this zero-copy on NTFS; copy if the volume does not support it.
    foreach ($artifact in $artifacts) {
        $aliasPath = Join-Path $outDir $artifact.Source
        $targetPath = Join-Path $outDir $artifact.Name
        if (Test-Path -LiteralPath $aliasPath) {
            Remove-Item -LiteralPath $aliasPath -Force
        }
        try {
            New-Item -ItemType HardLink -Path $aliasPath -Target $targetPath -ErrorAction Stop | Out-Null
        }
        catch {
            Copy-Item -LiteralPath $targetPath -Destination $aliasPath -Force
        }
    }

    foreach ($doc in @('README.md', 'LICENSE')) {
        $source = Join-Path $RepoRoot $doc
        if (Test-Path -LiteralPath $source) {
            Copy-Item -LiteralPath $source -Destination (Join-Path $outDir $doc) -Force
        }
    }
    $checksums | Set-Content -LiteralPath (Join-Path $outDir 'checksums.txt') -Encoding ASCII

    Write-Host "Artifacts: $outDir"
}
finally {
    Remove-Item Env:LEOPARDWM_BUILD_STAMP_EPOCH -ErrorAction SilentlyContinue
    Pop-Location
}
