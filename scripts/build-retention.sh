#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
  echo "This build requires macOS and Xcode. Use the GitHub Actions workflow from Windows." >&2
  exit 1
fi

XCODE_RETENTION_VERSION="$(python3 -c 'import json; print(json.load(open("versions.json"))["xcode"])')"
export DEVELOPER_DIR="/Applications/Xcode_${XCODE_RETENTION_VERSION}.app/Contents/Developer"
test -d "$DEVELOPER_DIR"
export USE_BAZEL_VERSION="$(python3 -c 'import json; print(json.load(open("versions.json"))["bazel"].split(":")[0])')"
RETENTION_BAZEL_PATH="$(command -v bazelisk)"
export RETENTION_BAZEL_PATH
python3 scripts/prepare-retention-build.py

RETENTION_BUILD_NUMBER="${GITHUB_RUN_NUMBER:-10000}"
RETENTION_BAZEL_FLAGS=(
  --define="buildNumber=$RETENTION_BUILD_NUMBER"
  --//Telegram:disableExtensions
  --ios_signing_cert_name=-
  --verbose_failures
  --features=swift.use_global_module_cache
)

if [[ "${RETENTION_RUN_TESTS:-true}" == true ]]; then
  "$RETENTION_BAZEL_PATH" test //submodules/TelegramCore:TelegramCoreTests \
    "${RETENTION_BAZEL_FLAGS[@]}" --ios_multi_cpus=sim_arm64 \
    --test_filter=DeletedMessageRetentionTests --test_output=errors
fi

"$RETENTION_BAZEL_PATH" build //Telegram:Telegram \
  "${RETENTION_BAZEL_FLAGS[@]}" -c opt --ios_multi_cpus=arm64 \
  --watchos_cpus=arm64_32 --features=swift.opt_uses_wmo \
  --features=swift.opt_uses_osize
mkdir -p build/artifacts
cp bazel-bin/Telegram/Telegram.ipa build/artifacts/TelegramRetention.ipa
echo "IPA prepared for re-signing: build/artifacts/TelegramRetention.ipa"
