<#
.SYNOPSIS
    End-user installer for the USB-C Magic Trackpad (PID_0324) driver release.

.DESCRIPTION
    Two modes, auto-detected from the release contents:

    * Microsoft-signed package (catalog signed by Microsoft via attestation):
        Just installs - no test-signing, no cert import, no watermark.

    * Self-signed package (development/community build):
        Imports the bundled public certificate into Trusted Root + TrustedPublisher,
        enables test-signing (reboot required), and installs.

    Run elevated (Administrator). Place this next to AmtPtpDevice.inf.
#>
[CmdletBinding()]
param(
    [string]$PackageDir = $PSScriptRoot
)
$ErrorActionPreference = 'Stop'

$p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw "Run elevated (Administrator)." }

$inf = Get-ChildItem $PackageDir -Filter 'AmtPtpDevice.inf' -Recurse | Select-Object -First 1
if (-not $inf) { throw "AmtPtpDevice.inf not found under $PackageDir" }
$cer = Get-ChildItem $PackageDir -Filter '*.cer' -Recurse | Select-Object -First 1

if ($cer) {
    Write-Host "Self-signed release detected." -ForegroundColor Yellow
    Write-Host "Importing certificate $($cer.Name) into Trusted Root + TrustedPublisher..." -ForegroundColor Cyan
    foreach ($store in 'Root','TrustedPublisher') {
        Import-Certificate -FilePath $cer.FullName -CertStoreLocation "Cert:\LocalMachine\$store" | Out-Null
    }
    if (-not (bcdedit /enum "{current}" | Select-String 'testsigning\s+Yes')) {
        Write-Host "Enabling test-signing (REBOOT REQUIRED afterwards)..." -ForegroundColor Cyan
        bcdedit /set testsigning on | Out-Null
        $rebootNeeded = $true
    }
} else {
    Write-Host "Microsoft-signed release detected - installing directly." -ForegroundColor Green
}

Write-Host "Installing driver..." -ForegroundColor Cyan
& pnputil /add-driver $inf.FullName /install
pnputil /scan-devices | Out-Null

if ($rebootNeeded) {
    Write-Host "`nREBOOT now to activate test-signing, then reconnect the trackpad." -ForegroundColor Yellow
} else {
    Write-Host "`nDone. Reconnect the trackpad (or toggle Bluetooth) if gestures aren't active yet." -ForegroundColor Green
}
