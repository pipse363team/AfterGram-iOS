#!/usr/bin/env python3
"""Create Bazel's local configuration from CI secrets, without printing them."""
import json
import os
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "build-system" / "Make"))
from BuildConfiguration import BuildConfiguration


def main():
    api_id = os.environ.get("TELEGRAM_API_ID", "")
    api_hash = os.environ.get("TELEGRAM_API_HASH", "")
    if not api_id.isdecimal() or int(api_id) <= 0 or not re.fullmatch(r"[0-9a-fA-F]{32}", api_hash):
        raise SystemExit("Add TELEGRAM_API_ID and TELEGRAM_API_HASH as GitHub Actions secrets (my.telegram.org/apps).")
    bazel = os.environ.get("RETENTION_BAZEL_PATH", "")
    if not bazel or not Path(bazel).is_file():
        raise SystemExit("RETENTION_BAZEL_PATH must point to the selected Bazel executable.")
    directory = ROOT / "build-input" / "configuration-repository"
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "provisioning").mkdir(exist_ok=True)
    (directory / "MODULE.bazel").write_text('module(name = "build_configuration")\n')
    (directory / "WORKSPACE").write_text("")
    (directory / "BUILD").write_text("")
    (directory / "provisioning" / "BUILD").write_text("exports_files([])\n")
    configuration = BuildConfiguration(
        bundle_id="org.local.TelegramRetention", api_id=api_id, api_hash=api_hash,
        team_id="LOCALTEAM1", app_center_id="0", is_internal_build="false",
        is_appstore_build="false", appstore_id="0", app_specific_url_scheme="tgretention",
        premium_iap_product_id="", enable_siri=False, enable_icloud=False,
    )
    configuration.write_to_variables_file(
        bazel_path=str(Path(bazel).resolve()), use_xcode_managed_codesigning=False,
        aps_environment="development", path=str(directory / "variables.bzl"),
    )
    versions = json.loads((ROOT / "versions.json").read_text())
    (ROOT / "build-input" / "retention-version.txt").write_text(versions["app"])
    print("Prepared configuration for the unofficial retention build.")


if __name__ == "__main__":
    main()
