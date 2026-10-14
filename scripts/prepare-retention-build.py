#!/usr/bin/env python3
"""Create Bazel's local configuration from CI secrets, without printing them."""
import json
import datetime
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "build-system" / "Make"))
from BuildConfiguration import BuildConfiguration


def create_ci_profile(output_path, bundle_id, team_id):
    """Generate a build-only CMS fixture; it is not an Apple installation profile."""
    template = ROOT / "build-system" / "fake-codesigning" / "profiles" / "Telegram.mobileprovision"
    decoded = subprocess.run(
        ["openssl", "smime", "-inform", "der", "-verify", "-noverify", "-in", str(template)],
        check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    ).stdout
    profile = plistlib.loads(decoded)
    old_team, old_bundle = profile["Entitlements"]["application-identifier"].split(".", 1)

    def substitute(value):
        if isinstance(value, str):
            return value.replace(old_bundle, bundle_id).replace(old_team, team_id)
        if isinstance(value, list):
            return [substitute(item) for item in value]
        if isinstance(value, dict):
            return {key: substitute(item) for key, item in value.items()}
        return value

    profile = substitute(profile)
    now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
    profile.update(
        AppIDName="AfterGram CI", Name="AfterGram CI placeholder - requires re-signing",
        TeamName="AfterGram CI placeholder", UUID=str(uuid.uuid4()).upper(),
        CreationDate=now, ExpirationDate=now + datetime.timedelta(days=365),
        TimeToLive=365, DeveloperCertificates=[],
    )
    profile["Entitlements"]["aps-environment"] = "development"
    with tempfile.TemporaryDirectory(prefix="aftergram-ci-profile-") as temporary:
        directory = Path(temporary)
        plist = directory / "profile.plist"
        plist.write_bytes(plistlib.dumps(profile))
        key, certificate = directory / "key.pem", directory / "cert.pem"
        subprocess.run([
            "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256",
            "-keyout", str(key), "-out", str(certificate), "-days", "365",
            "-subj", "/CN=AfterGram CI build placeholder",
        ], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        subprocess.run([
            "openssl", "cms", "-sign", "-binary", "-nodetach", "-in", str(plist),
            "-signer", str(certificate), "-inkey", str(key), "-outform", "DER",
            "-out", str(output_path),
        ], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


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
    (directory / "provisioning" / "BUILD").write_text('exports_files(["Telegram.mobileprovision"])\n')
    configuration = BuildConfiguration(
        bundle_id="org.local.TelegramRetention", api_id=api_id, api_hash=api_hash,
        team_id="LOCALTEAM1", app_center_id="0", is_internal_build="false",
        is_appstore_build="false", appstore_id="0", app_specific_url_scheme="tgretention",
        premium_iap_product_id="", enable_siri=False, enable_icloud=False,
    )
    create_ci_profile(directory / "provisioning" / "Telegram.mobileprovision", configuration.bundle_id, configuration.team_id)
    configuration.write_to_variables_file(
        bazel_path=str(Path(bazel).resolve()), use_xcode_managed_codesigning=False,
        aps_environment="development", path=str(directory / "variables.bzl"),
    )
    versions = json.loads((ROOT / "versions.json").read_text())
    (ROOT / "build-input" / "retention-version.txt").write_text(versions["app"])
    print("Prepared configuration for the unofficial retention build.")


if __name__ == "__main__":
    main()
