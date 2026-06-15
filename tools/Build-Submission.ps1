<#
.SYNOPSIS
    Builds the driver package and assembles a .cab ready for Microsoft attestation
    signing via the Partner Center (Windows Hardware Developer) dashboard.

.DESCRIPTION
    1. Builds AmtPtpDeviceUniversalPkg (Release/x64).
    2. Collects the package output (INF(s), .sys/.dll, .cat).
    3. Packs them into AmtPtpDevice.cab with the layout the dashboard expects.
    4. Optionally signs the .cab with your EV cert:
         -EvThumbprint <hash>                 (USB token / local cert store)
         -KeyVaultUrl/-KeyVaultCert/...        (Azure Key Vault via AzureSignTool)
       If no signing params are given, it leaves the .cab unsigned and prints the
       exact signtool command to run yourself.

    Attestation signing covers software-only drivers (no HLK lab testing needed).

.NOTES
    Requires the build toolchain already set up (VS2017 C++ + WDK 1809).
    EV cert + Partner Center account are prerequisites you provide. See SIGNING.md.
#>
[CmdletBinding()]
param(
    [string]$SrcRoot   = "$env:USERPROFILE\imbushuoTrackpad\src",
    [string]$OutDir    = "$env:USERPROFILE\imbushuoTrackpad\submission",
    [string]$CabName   = 'AmtPtpDevice.cab',

    # --- EV signing via USB token / local cert store ---
    [string]$EvThumbprint,
    [string]$TimestampUrl = 'http://timestamp.digicert.com',

    # --- EV signing via Azure Key Vault (uses AzureSignTool) ---
    [string]$KeyVaultUrl,
    [string]$KeyVaultCert,
    [string]$KeyVaultClientId,
    [string]$KeyVaultClientSecret,
    [string]$KeyVaultTenantId
)
$ErrorActionPreference = 'Stop'

function Find-Tool($name) {
    $t = Get-ChildItem "C:\Program Files (x86)\Windows Kits\10\bin" -Recurse -Filter $name -ErrorAction SilentlyContinue |
         Where-Object { $_.FullName -match '\\x64\\' } | Select-Object -First 1
    if (-not $t) { throw "$name (x64) not found in the SDK bin." }
    return $t.FullName
}

$msbuild = "C:\Program Files (x86)\Microsoft Visual Studio\2017\Community\MSBuild\15.0\Bin\MSBuild.exe"
$signtool = Find-Tool 'signtool.exe'
$makecab = "$env:WINDIR\System32\makecab.exe"

# 1. Build the package.
$pkgProj = Join-Path $SrcRoot 'src\AmtPtpDeviceUniversalPkg\AmtPtpDeviceUniversalPkg.vcxproj'
Write-Host "Building release package..." -ForegroundColor Cyan
& $msbuild $pkgProj /p:Configuration=Release /p:Platform=x64 /p:WindowsTargetPlatformVersion=10.0.17763.0 /t:Build /m /v:minimal /nologo
if ($LASTEXITCODE -ne 0) { throw "Build failed ($LASTEXITCODE)." }

$pkgDir = Join-Path $SrcRoot 'src\AmtPtpDeviceUniversalPkg\build\AmtPtpDeviceUniversalPkg\x64\Release\AmtPtpDeviceUniversalPkg'
if (-not (Test-Path $pkgDir)) { throw "Package output not found at $pkgDir" }

# 2/3. Stage files and build the cab. Driver files go under a single folder inside
# the cab (dashboard requirement: relative paths, no drive letters).
if (Test-Path $OutDir) { Remove-Item $OutDir -Recurse -Force }
New-Item -ItemType Directory -Path $OutDir | Out-Null

$files = Get-ChildItem $pkgDir -File | Where-Object { $_.Extension -in '.inf','.sys','.dll','.cat' }
if (-not $files) { throw "No driver files found in $pkgDir" }
Write-Host "Including $($files.Count) files in the cab:" -ForegroundColor Cyan
$files | ForEach-Object { Write-Host "  $($_.Name)" }

$ddf = Join-Path $OutDir 'AmtPtpDevice.ddf'
$ddfLines = @(
    '.OPTION EXPLICIT'
    '.Set CabinetFileCountThreshold=0'
    '.Set FolderFileCountThreshold=0'
    '.Set FolderSizeThreshold=0'
    '.Set MaxCabinetSize=0'
    '.Set MaxDiskFileCount=0'
    '.Set MaxDiskSize=0'
    '.Set CompressionType=MSZIP'
    '.Set Cabinet=on'
    '.Set Compress=on'
    ".Set CabinetNameTemplate=$CabName"
    ".Set DiskDirectory1=$OutDir"
    '.Set DestinationDir=AmtPtpDevice'   # folder name inside the cab
)
foreach ($f in $files) { $ddfLines += "`"$($f.FullName)`"" }
Set-Content -Path $ddf -Value $ddfLines -Encoding ASCII

Write-Host "Packing cab with makecab..." -ForegroundColor Cyan
& $makecab /f $ddf | Out-Null
$cabPath = Join-Path $OutDir $CabName
if (-not (Test-Path $cabPath)) { throw "makecab did not produce $cabPath" }
Write-Host "Cab created: $cabPath" -ForegroundColor Green

# 4. Sign the cab (optional).
function Get-AzureSignTool {
    $ast = Get-Command AzureSignTool -ErrorAction SilentlyContinue
    if ($ast) { return $ast.Source }
    # dotnet global tool fallback
    $p = Join-Path $env:USERPROFILE '.dotnet\tools\AzureSignTool.exe'
    if (Test-Path $p) { return $p }
    return $null
}

if ($EvThumbprint) {
    Write-Host "Signing cab with EV cert (thumbprint $EvThumbprint)..." -ForegroundColor Cyan
    & $signtool sign /fd sha256 /sha1 $EvThumbprint /tr $TimestampUrl /td sha256 /v $cabPath
    if ($LASTEXITCODE -ne 0) { throw "signtool failed ($LASTEXITCODE)." }
    Write-Host "Signed: $cabPath" -ForegroundColor Green
}
elseif ($KeyVaultUrl) {
    $ast = Get-AzureSignTool
    if (-not $ast) { throw "AzureSignTool not found. Install with: dotnet tool install --global AzureSignTool" }
    Write-Host "Signing cab via Azure Key Vault..." -ForegroundColor Cyan
    & $ast sign --description-url "https://github.com/ckhordiasma/mac-precision-touchpad" `
        --azure-key-vault-url $KeyVaultUrl `
        --azure-key-vault-client-id $KeyVaultClientId `
        --azure-key-vault-client-secret $KeyVaultClientSecret `
        --azure-key-vault-tenant-id $KeyVaultTenantId `
        --azure-key-vault-certificate $KeyVaultCert `
        --timestamp-rfc3161 $TimestampUrl --timestamp-digest sha256 `
        --file-digest sha256 $cabPath
    if ($LASTEXITCODE -ne 0) { throw "AzureSignTool failed ($LASTEXITCODE)." }
    Write-Host "Signed: $cabPath" -ForegroundColor Green
}
else {
    Write-Host "`nCab is UNSIGNED. Sign it with your EV cert before uploading, e.g.:" -ForegroundColor Yellow
    Write-Host "  & `"$signtool`" sign /fd sha256 /sha1 <EV_THUMBPRINT> /tr $TimestampUrl /td sha256 /v `"$cabPath`"" -ForegroundColor DarkYellow
}

Write-Host "`nNext: upload $cabPath to Partner Center -> Drivers -> new submission -> attestation. See SIGNING.md." -ForegroundColor Cyan
