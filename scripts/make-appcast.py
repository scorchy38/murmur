#!/usr/bin/env python3
"""Create a signed stable appcast for an already signed Mac app and its DMG.
Signing uses the dedicated local Keychain account, or SPARKLE_PRIVATE_KEY in CI.
The private key is piped to Sparkle, never passed as an argument or logged.
"""
import argparse
import datetime
import os
import pathlib
import plistlib
import subprocess
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)

def appcast(info, url, length, signature, published):
    root = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(root, "channel")
    ET.SubElement(channel, "title").text = "Murmur updates"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = "Murmur " + info["CFBundleShortVersionString"]
    ET.SubElement(item, "pubDate").text = published
    ET.SubElement(item, f"{{{SPARKLE}}}version").text = info["CFBundleVersion"]
    ET.SubElement(item, f"{{{SPARKLE}}}shortVersionString").text = info["CFBundleShortVersionString"]
    ET.SubElement(item, f"{{{SPARKLE}}}minimumSystemVersion").text = info.get("LSMinimumSystemVersion", "14.0")
    ET.SubElement(item, "link").text = "https://github.com/scorchy38/murmur/releases"
    ET.SubElement(item, "enclosure", {"url": url, "length": str(length), "type": "application/octet-stream", f"{{{SPARKLE}}}edSignature": signature})
    ET.indent(root)
    return ET.tostring(root, encoding="utf-8", xml_declaration=True)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=pathlib.Path, required=True)
    parser.add_argument("--dmg", type=pathlib.Path, required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--sign-tool", required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()
    info = plistlib.loads((args.app / "Contents/Info.plist").read_bytes())
    if not info.get("SUPublicEDKey"):
        raise SystemExit("The application has no trusted update public key")
    env = dict(os.environ)
    private_key = env.pop("SPARKLE_PRIVATE_KEY", "")
    base = [args.sign_tool]
    if private_key:
        options = ["--ed-key-file", "-"]
        secret_input = private_key.encode()
    else:
        options = ["--account", "com.murmur.updates"]
        secret_input = None
    signature = subprocess.run(base + options + ["-p", str(args.dmg)], input=secret_input, capture_output=True, check=True, env=env).stdout.decode().strip()
    # Verify against the PUBLIC KEY embedded in this exact binary, not just the
    # private signing identity, so a rotated/mismatched CI secret fails closed.
    verifier = pathlib.Path(__file__).with_name("verify-update.swift")
    subprocess.run(["swift", str(verifier), info["SUPublicEDKey"], signature, str(args.dmg)], check=True, env=env)
    from urllib.parse import quote
    url = f"https://github.com/scorchy38/murmur/releases/download/{quote(args.tag, safe='')}/{quote(args.dmg.name)}"
    date = datetime.datetime.now(datetime.timezone.utc).strftime("%a, %d %b %Y %H:%M:%S %z")
    args.output.write_bytes(appcast(info, url, args.dmg.stat().st_size, signature, date))
    print(f"Verified signed update feed for {info['CFBundleShortVersionString']} ({info['CFBundleVersion']})")

if __name__ == "__main__":
    main()
