#!/usr/bin/env python3
"""Optional Developer ID setup in an ephemeral CI keychain; never export keys.
MACOS_SIGNING_ENABLED must be explicitly true. Unconfigured repositories keep
using the existing ad-hoc release path. Partial signed configurations fail closed.
"""
import base64
import os
import pathlib
import re
import secrets
import subprocess


def run(args):
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode:
        raise SystemExit(f"Signing setup failed in {args[0]}; check certificate and keychain configuration.")
    return result.stdout


def main():
    outputs = {"identity": "-", "team": "", "runtime": "NO", "notarize": "false", "signflags": "", "style": "Automatic"}
    if os.environ.get("MACOS_SIGNING_ENABLED", "").lower() == "true":
        names = ["DEVELOPER_ID_P12_BASE64", "DEVELOPER_ID_P12_PASSWORD", "APPLE_TEAM_ID",
                 "APPLE_NOTARY_KEY_ID", "APPLE_NOTARY_ISSUER_ID", "APPLE_NOTARY_PRIVATE_KEY"]
        missing = [name for name in names if not os.environ.get(name)]
        if missing:
            raise SystemExit("Missing signed-release secrets: " + ", ".join(missing))
        team = os.environ["APPLE_TEAM_ID"]
        if not re.fullmatch(r"[A-Z0-9]{10}", team):
            raise SystemExit("APPLE_TEAM_ID must be a ten-character team identifier")
        directory = pathlib.Path(os.environ["RUNNER_TEMP"])
        keychain = directory / "murmur-signing.keychain-db"
        certificate = directory / "murmur-developer-id.p12"
        password = secrets.token_urlsafe(32)
        try:
            certificate.write_bytes(base64.b64decode(os.environ["DEVELOPER_ID_P12_BASE64"], validate=True))
            certificate.chmod(0o600)
            run(["security", "create-keychain", "-p", password, str(keychain)])
            run(["security", "set-keychain-settings", "-lut", "21600", str(keychain)])
            run(["security", "unlock-keychain", "-p", password, str(keychain)])
            run(["security", "import", str(certificate), "-P", os.environ["DEVELOPER_ID_P12_PASSWORD"],
                 "-k", str(keychain), "-T", "/usr/bin/codesign", "-T", "/usr/bin/security"])
            run(["security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", password, str(keychain)])
            listed = run(["security", "list-keychains", "-d", "user"])
            paths = re.findall(r'"([^"]+)"', listed)
            run(["security", "list-keychains", "-d", "user", "-s", str(keychain), *paths])
            identities = run(["security", "find-identity", "-v", "-p", "codesigning", str(keychain)])
            matches = re.findall(r'([A-F0-9]{40}) "Developer ID Application:[^"\n]+ \(' + team + r'\)"', identities)
            if len(matches) != 1:
                raise SystemExit("Expected one valid Developer ID Application certificate for APPLE_TEAM_ID")
            outputs.update(identity=matches[0], team=team, runtime="YES", notarize="true", signflags="--timestamp", style="Manual")
        finally:
            certificate.unlink(missing_ok=True)
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        for key, value in outputs.items():
            output.write(f"{key}={value}\n")
    print("Developer ID signing configured." if outputs["notarize"] == "true" else "Using existing ad-hoc signing; notarization is not enabled.")


if __name__ == "__main__":
    main()
