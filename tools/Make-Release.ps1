<#
.SYNOPSIS
    Builds and publishes a GitHub release of the USB-C Magic Trackpad driver to your fork.

.DESCRIPTION
    1. Builds AmtPtpDeviceUniversalPkg (Release/x64).
    2. Stages the package + end-user Install.ps1 (+ public cert for self-signed builds).
    3. Zips it and creates a GitHub release with `gh release create`.

    Two modes:
      * Self-signed (default): re-signs the catalog with your dev cert and bundles the
        public .cer so users can trust it. Ships with a "test-mode" caveat.
      * Microsoft-signed: pass -SignedPackageDir pointing at the package downloaded from
        Partner Center attestation; that catalog is used as-is (no cert bundled).

.NOTES
    Requires gh (authenticated) and the build toolchain. Run from anywhere.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$Version,           # e.g. v0.1.0
    [string]$SrcRoot = "$env:USERPROFILE\imbushuoTrackpad\src",
    [string]$Repo    = 'ckhordiasma/mac-precision-touchpad',
    [string]$CertSubject = 'CN=MagicTrackpadForceBind',
    [string]$SignedPackageDir,                          # set for MS-signed release
    [switch]$Draft
)
$ErrorActionPreference = 'Stop'

function Find-Signtool {
    (Get-ChildItem "C:\Program Files (x86)\Windows Kits\10\bin" -Recurse -Filter signtool.exe -ErrorAction SilentlyContinue |
     Where-Object { $_.FullName -match '\\x64\\' } | Select-Object -First 1).FullName
}

$staging = Join-Path $env:TEMP "amtptp-release-$Version"
if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
New-Item -ItemType Directory -Path $staging | Out-Null

if ($SignedPackageDir) {
    Write-Host "Using Microsoft-signed package from $SignedPackageDir" -ForegroundColor Green
    Copy-Item "$SignedPackageDir\*" $staging -Recurse -Force
} else {
    # Build + self-sign.
    $msbuild = "C:\Program Files (x86)\Microsoft Visual Studio\2017\Community\MSBuild\15.0\Bin\MSBuild.exe"
    $pkgProj = Join-Path $SrcRoot 'src\AmtPtpDeviceUniversalPkg\AmtPtpDeviceUniversalPkg.vcxproj'
    Write-Host "Building release package..." -ForegroundColor Cyan
    & $msbuild $pkgProj /p:Configuration=Release /p:Platform=x64 /p:WindowsTargetPlatformVersion=10.0.17763.0 /t:Build /m /v:minimal /nologo
    if ($LASTEXITCODE -ne 0) { throw "Build failed." }

    $pkgDir = Join-Path $SrcRoot 'src\AmtPtpDeviceUniversalPkg\build\AmtPtpDeviceUniversalPkg\x64\Release\AmtPtpDeviceUniversalPkg'
    Copy-Item "$pkgDir\*" $staging -Recurse -Force

    $cert = Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Subject -eq $CertSubject } | Select-Object -First 1
    if (-not $cert) { throw "Dev cert $CertSubject not found." }
    $signtool = Find-Signtool
    Write-Host "Re-signing catalog with dev cert + exporting public cert..." -ForegroundColor Cyan
    & $signtool sign /fd SHA256 /sha1 $cert.Thumbprint /v (Join-Path $staging 'amtptpdevice.cat') | Out-Null
    Export-Certificate -Cert $cert -FilePath (Join-Path $staging 'MagicTrackpadCert.cer') -Force | Out-Null
}

# Bundle the end-user installer.
Copy-Item (Join-Path $SrcRoot 'tools\Install.ps1') $staging -Force

# Zip it.
$zip = Join-Path $env:TEMP "MagicTrackpad-USBC-$Version.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path "$staging\*" -DestinationPath $zip
Write-Host "Release zip: $zip" -ForegroundColor Green

# Publish.
$signedNote = if ($SignedPackageDir) {
    "Microsoft-signed (attestation). Installs directly: run Install.ps1 elevated. No test-signing needed."
} else {
    "Self-signed community build. Run Install.ps1 elevated; it imports the bundled cert and enables test-signing (reboot required). Expect a 'Test Mode' watermark."
}
$notes = @"
USB-C Magic Trackpad (VID_05AC / PID_0324) driver for Windows 10/11.
Adds right-click + multi-finger gestures over USB and Bluetooth.

$signedNote

Built from imbushuo/mac-precision-touchpad with PID_0324 support added.
"@

$env:Path = [System.Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path','User')
$ghArgs = @('release','create',$Version,$zip,'--repo',$Repo,'--title',"USB-C Magic Trackpad $Version",'--notes',$notes)
if ($Draft) { $ghArgs += '--draft' }
Write-Host "Creating GitHub release $Version on $Repo..." -ForegroundColor Cyan
& gh @ghArgs
Write-Host "Done." -ForegroundColor Green
