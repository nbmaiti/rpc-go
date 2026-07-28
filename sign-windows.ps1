# Authenticode-sign the Windows release executables with signtool.exe.
#
# This embeds a Microsoft-recognised Authenticode signature *inside* each PE so
# Windows SmartScreen stops flagging the download as "not commonly downloaded".
# It is distinct from and complementary to Cosign (sign.sh): Cosign proves
# supply-chain provenance across all platforms via Sigstore; Authenticode is the
# signature Windows itself trusts.
#
# ORDER MATTERS: run this BEFORE sign.sh. Authenticode modifies the .exe bytes,
# so Cosign must sign the final (already Authenticode-signed) file — otherwise
# `cosign verify-blob` fails against the shipped binary. In CI that ordering is
# enforced by the job graph in .github/workflows/release.yml: this script runs on
# a windows-latest runner between the build job and the release job.
#
# signtool.exe is Windows-only, hence the separate runner. Required environment:
#   WINDOWS_PFX_BASE64   base64 of the code-signing .pfx (GitHub secret)
#   WINDOWS_PFX_PASSWORD password for that .pfx (GitHub secret)
# Optional:
#   WINDOWS_TIMESTAMP_URL  RFC3161 timestamp server (default: DigiCert)
#
# If WINDOWS_PFX_BASE64 is unset (local dev, forks without the cert), this
# script logs and exits 0 so the release still succeeds with Cosign signing
# only and the unsigned .exe files pass through unchanged.
#
# NOTE ON SMARTSCREEN: a signature alone does not clear SmartScreen. Reputation
# accrues against the publisher identity in the certificate — immediately with
# an EV certificate, gradually with an OV one. Signing is the prerequisite, not
# the whole fix.

$ErrorActionPreference = 'Stop'

# Windows executables produced by build.sh.
$artifacts = @(
    'rpc_windows_x64.exe',
    'rpc_windows_x86.exe'
)

if ([string]::IsNullOrWhiteSpace($env:WINDOWS_PFX_BASE64)) {
    Write-Host 'SKIP: WINDOWS_PFX_BASE64 not set - skipping Authenticode signing.'
    Write-Host '      (Windows binaries ship unsigned by Authenticode; Cosign still applies.)'
    exit 0
}

if ([string]::IsNullOrWhiteSpace($env:WINDOWS_PFX_PASSWORD)) {
    Write-Error 'WINDOWS_PFX_BASE64 is set but WINDOWS_PFX_PASSWORD is empty.'
    exit 1
}

# Locate the newest signtool.exe in the installed Windows SDKs. Do not hardcode
# an SDK version — the runner image bumps it without notice.
$signtool = Get-ChildItem -Path 'C:\Program Files (x86)\Windows Kits\10\bin\*\x64\signtool.exe' -ErrorAction SilentlyContinue |
    Where-Object { $_.Directory.Parent.Name -match '^\d+\.\d+\.\d+\.\d+$' } |
    Sort-Object { [version]$_.Directory.Parent.Name } -Descending |
    Select-Object -First 1

if (-not $signtool) {
    # Older SDK layouts put signtool directly under bin\x64.
    $signtool = Get-Item 'C:\Program Files (x86)\Windows Kits\10\bin\x64\signtool.exe' -ErrorAction SilentlyContinue
}

if (-not $signtool) {
    Write-Error 'signtool.exe not found. Is the Windows SDK installed on this runner?'
    exit 1
}

Write-Host "Using signtool: $($signtool.FullName)"

$timestampUrl = if ([string]::IsNullOrWhiteSpace($env:WINDOWS_TIMESTAMP_URL)) {
    'http://timestamp.digicert.com'
} else {
    $env:WINDOWS_TIMESTAMP_URL
}

# Decode the certificate to a file outside the workspace so it cannot be picked
# up by a later artifact upload, and delete it on the way out no matter what.
$pfxPath = Join-Path ([System.IO.Path]::GetTempPath()) "rpc-codesign-$PID.pfx"

try {
    [System.IO.File]::WriteAllBytes(
        $pfxPath,
        [System.Convert]::FromBase64String($env:WINDOWS_PFX_BASE64)
    )

    foreach ($artifact in $artifacts) {
        if (-not (Test-Path $artifact)) {
            Write-Error "Windows artifact not found, cannot sign: $artifact"
            exit 1
        }

        Write-Host '--------------------------------'
        Write-Host "Authenticode signing: $artifact"
        Write-Host '--------------------------------'

        # /fd + /td SHA256: file and timestamp digests. /tr uses an RFC3161
        # timestamp server so signatures stay valid past cert expiry.
        & $signtool.FullName sign `
            /fd sha256 `
            /td sha256 `
            /tr $timestampUrl `
            /f $pfxPath `
            /p $env:WINDOWS_PFX_PASSWORD `
            $artifact

        if ($LASTEXITCODE -ne 0) {
            Write-Error "signtool sign failed for $artifact (exit $LASTEXITCODE)"
            exit $LASTEXITCODE
        }

        # /pa checks against the Authenticode policy rather than the default
        # Windows-driver policy, which is what a normal .exe is signed under.
        & $signtool.FullName verify /pa /v $artifact

        if ($LASTEXITCODE -ne 0) {
            Write-Error "signtool verify failed for $artifact (exit $LASTEXITCODE)"
            exit $LASTEXITCODE
        }

        Write-Host "Authenticode signed $artifact"
    }
} finally {
    if (Test-Path $pfxPath) {
        Remove-Item $pfxPath -Force -ErrorAction SilentlyContinue
    }
}

Write-Host 'Authenticode signing complete.'
