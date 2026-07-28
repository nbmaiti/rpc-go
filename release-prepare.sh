#!/bin/bash

# semantic-release `prepareCmd` wrapper.
#
# The release is split across jobs (see .github/workflows/release.yml) because
# Authenticode signing needs signtool.exe on a windows-latest runner while
# semantic-release itself runs on ubuntu-latest:
#
#   version -> build -> sign-windows (signtool) -> release (this script)
#
# By the time semantic-release runs, the artifacts have already been built and
# the Windows executables Authenticode-signed, so this script must NOT rebuild
# them — a rebuild would overwrite the signed PEs with unsigned ones. Set
# RPC_ARTIFACTS_PREBUILT=1 (the release job does) to skip the build.
#
# Cosign runs here, last, so it signs the final Authenticode-signed bytes.
# Reversing that order breaks `cosign verify-blob` against the shipped binary.
#
# When RPC_ARTIFACTS_PREBUILT is unset this script does the whole thing locally
# (build then sign), which is how a single-runner or local dry run behaves.

set -euo pipefail

version="${1:?usage: release-prepare.sh <version>}"

if [ "${RPC_ARTIFACTS_PREBUILT:-0}" = "1" ]; then
    echo "⏭️  RPC_ARTIFACTS_PREBUILT=1 — using artifacts from the build job."
    echo "    Skipping build.sh so Authenticode-signed .exe files are preserved."
else
    echo "🔨 Building release artifacts for $version"
    ./build.sh "$version"
    echo "🔏 Authenticode signing is a windows-latest job in CI; skipped here."
fi

# Cosign last: it must sign the final (Authenticode-signed) bytes.
./sign.sh

echo "🐳 Building container images for $version"
docker build \
    -t "vprodemo.azurecr.io/rpc-go:v${version}" \
    -t "vprodemo.azurecr.io/rpc-go:latest" \
    -t "docker.io/intel/oact-rpc-go:v${version}" \
    -t "docker.io/intel/oact-rpc-go:latest" \
    -t "docker.io/intel/device-mgmt-toolkit-rpc-go:v${version}" \
    -t "docker.io/intel/device-mgmt-toolkit-rpc-go:latest" \
    .
