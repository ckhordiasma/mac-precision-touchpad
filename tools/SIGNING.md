# Proper signing — Microsoft attestation signing

Goal: a Microsoft-signed driver package that installs on any Windows 10/11 with **no
test-signing and no watermark**. This replaces the self-signed flow used during
development.

## Prerequisites (you provide these)

1. **Partner Center – Windows Hardware Developer account**
   - Sign up at https://partner.microsoft.com/dashboard → Hardware program.
   - One-time registration fee (~$20).
2. **EV (Extended Validation) code-signing certificate**
   - From DigiCert, Sectigo, GlobalSign, etc. (~$250–600/yr).
   - Private key MUST be on FIPS 140-2 hardware: a shipped USB token, OR
     **Azure Key Vault** (a Premium HSM-backed vault — cheapest if you don't want a
     physical token).
   - Expect a few days of identity/organization validation.
3. **Link the EV cert to the dashboard** (one-time): in Partner Center, the first
   submission validates your EV signature and binds it to the account.

## One-time: choosing token vs Azure Key Vault

- **USB token**: CA ships you a hardware token. Sign locally with `signtool` using the
  cert thumbprint. Simplest if you already have it.
- **Azure Key Vault (recommended for no hardware)**: create a Premium (HSM) vault,
  generate/import the EV cert there, and sign with **AzureSignTool**:
  ```
  dotnet tool install --global AzureSignTool
  ```
  You'll need an Azure AD app registration (client id/secret) with `sign` permission
  on the vault.

## Build + package + sign the .cab

Run `Build-Submission.ps1`. It builds the package, makes `AmtPtpDevice.cab`, and signs it.

**Token / local cert:**
```powershell
.\Build-Submission.ps1 -EvThumbprint <EV_CERT_THUMBPRINT>
```

**Azure Key Vault:**
```powershell
.\Build-Submission.ps1 `
  -KeyVaultUrl https://<vault>.vault.azure.net `
  -KeyVaultCert <certName> `
  -KeyVaultClientId <appId> `
  -KeyVaultClientSecret <secret> `
  -KeyVaultTenantId <tenantId>
```

Output: `%USERPROFILE%\imbushuoTrackpad\submission\AmtPtpDevice.cab` (EV-signed).

## Submit for attestation signing

1. Go to **Partner Center → Drivers → Submit new driver**.
2. Upload the **EV-signed** `AmtPtpDevice.cab`.
3. When prompted, choose **attestation signing** (NOT full HLK certification — this is a
   software-only driver, so attestation is sufficient and free).
4. Select target OSes (e.g., **Windows 10 (1809+) x64** and **Windows 11 x64**).
5. Submit. Attestation signing usually completes in minutes to a few hours.
6. **Download** the signed package — the `.cat` inside is now Microsoft-signed.

## Ship it

- Replace the self-signed catalog in your release with the Microsoft-signed package.
- End users install with plain `pnputil /add-driver AmtPtpDevice.inf /install` (elevated)
  or right-click INF → Install. No test-signing, no cert import, no watermark.
- Update `Make-Release.ps1` to publish the MS-signed package as the release asset.

## Notes / gotchas

- Attestation signatures are valid only for the **OS versions you select** at submission
  time. Re-submit to add newer Windows builds later.
- Every code change = rebuild + re-sign the cab + re-submit (signing is per-package).
- The EV cert is only used to authenticate the **upload**; the trust users see comes from
  the **Microsoft** signature applied by the dashboard.
- Keep the EV cert renewed; an expired cert blocks new submissions (already-signed
  packages keep working).
