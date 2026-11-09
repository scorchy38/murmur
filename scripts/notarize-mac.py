#!/usr/bin/env python3
"""Notarize/staple a Developer-ID app or the final DMG before Sparkle signing.
Only CI calls this when Developer ID signing is explicitly enabled.
"""
import argparse
import json
import os
import pathlib
import subprocess
import tempfile


def checked(args):
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode:
        raise SystemExit(f"Notarization step failed: {pathlib.Path(args[0]).name} {args[1]}. Check Apple credentials and the signing configuration.")
    return result.stdout


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("artifact", type=pathlib.Path)
    parser.add_argument("--identity", required=True)
    args = parser.parse_args()
    path = args.artifact.resolve()
    if path.suffix not in (".app", ".dmg") or not path.exists() or args.identity == "-":
        raise SystemExit("A Developer ID-signed app or DMG is required")
    names = ("APPLE_NOTARY_PRIVATE_KEY", "APPLE_NOTARY_KEY_ID", "APPLE_NOTARY_ISSUER_ID")
    if any(not os.environ.get(name) for name in names):
        raise SystemExit("Missing App Store Connect notarization credentials")
    with tempfile.TemporaryDirectory(prefix="murmur-notary-") as directory:
        root = pathlib.Path(directory)
        key = root / "AuthKey.p8"
        key.write_text(os.environ["APPLE_NOTARY_PRIVATE_KEY"])
        key.chmod(0o600)
        upload = path
        if path.suffix == ".app":
            upload = root / "Murmur.zip"
            checked(["codesign", "--verify", "--deep", "--strict", str(path)])
            checked(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(path), str(upload)])
        else:
            checked(["codesign", "--force", "--timestamp", "--sign", args.identity, str(path)])
        result = json.loads(checked(["xcrun", "notarytool", "submit", str(upload), "--key", str(key),
                                    "--key-id", os.environ["APPLE_NOTARY_KEY_ID"], "--issuer", os.environ["APPLE_NOTARY_ISSUER_ID"],
                                    "--wait", "--timeout", "20m", "--output-format", "json"]))
        if result.get("status") != "Accepted":
            raise SystemExit("Apple did not accept this artifact. Submission ID: " + str(result.get("id", "unavailable")))
        checked(["xcrun", "stapler", "staple", str(path)])
        checked(["xcrun", "stapler", "validate", str(path)])
        if path.suffix == ".app":
            checked(["spctl", "--assess", "--type", "execute", "--verbose", str(path)])
    print("Apple accepted the artifact; stapled ticket validated.")


if __name__ == "__main__":
    main()
