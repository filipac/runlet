#!/usr/bin/env python3
"""Adds a release to Runlet's appcast and signs it (#233). See docs/releasing.md.

Usage:
  scripts/appcast.py add <appcast.xml> <Runlet.zip> --version 0.4.0-beta.7 --build 13 \\
      --url https://github.com/filipac/runlet/releases/download/v0.4.0-beta.7/Runlet-0.4.0-beta.7.zip \\
      --notes notes.md (--ed-key-file <private key file> | --keychain) [--link <release page>]
  scripts/appcast.py verify <appcast.xml> (--ed-key-file <private key file> | --keychain)

`add` signs the archive with Sparkle's sign_update (EdDSA), puts an <item> for it at the top of
the appcast (replacing an item with the same build), and signs the whole feed, which Runlet
requires (SURequireSignedFeed). A version with a pre-release part (`-beta.7`) is tagged
<sparkle:channel>beta</sparkle:channel>, so only the Beta channel offers it. The notes file is
Markdown (the GitHub release's body); Runlet shows it in its update window.

The signing key: --ed-key-file reads a private key file kept outside the repository; --keychain
uses the key `generate_keys` stored in your login Keychain. One of them is required, so the
script never falls back to the Keychain by accident. The key is never printed or copied.

sign_update comes with the Sparkle package: build the app once (package.sh or the Debug build)
and it is found under build/*/SourcePackages/artifacts/sparkle/Sparkle/bin, or pass --sparkle-bin.
"""
import argparse
import email.utils
import os
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
DC = "http://purl.org/dc/elements/1.1/"
ET.register_namespace("sparkle", SPARKLE)
ET.register_namespace("dc", DC)
ROOT = Path(__file__).resolve().parent.parent
MINIMUM_SYSTEM = "15.0"


def s(name):
    return f"{{{SPARKLE}}}{name}"


def sign_update_path(explicit):
    candidates = [Path(explicit)] if explicit else [
        ROOT / "build/Release-DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin",
        ROOT / "build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin",
    ]
    for directory in candidates:
        tool = directory / "sign_update"
        if tool.is_file() and os.access(tool, os.X_OK):
            return str(tool)
    sys.exit("sign_update not found: build Runlet once (scripts/package.sh) or pass --sparkle-bin")


def key_arguments(args):
    if args.ed_key_file and args.keychain:
        sys.exit("Use either --ed-key-file or --keychain, not both")
    if args.ed_key_file:
        if not Path(args.ed_key_file).is_file():
            sys.exit(f"No key file at {args.ed_key_file}")
        return ["--ed-key-file", args.ed_key_file]
    if args.keychain:
        return []
    sys.exit("Pass --ed-key-file <private key file> or --keychain (the key generate_keys stored)")


def load(appcast):
    if appcast.exists():
        # Comments (the old feed signature) are dropped; the feed is signed again below.
        return ET.parse(appcast)
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "Runlet"
    ET.SubElement(channel, "link").text = "https://github.com/filipac/runlet/releases"
    ET.SubElement(channel, "description").text = "Runlet releases (stable and beta) for in-app updates."
    ET.SubElement(channel, "language").text = "en"
    return ET.ElementTree(rss)


def add(args):
    sign_update = sign_update_path(args.sparkle_bin)
    keys = key_arguments(args)
    archive = Path(args.archive)
    if not archive.is_file():
        sys.exit(f"No archive at {archive}")
    if not args.build.isdigit():
        sys.exit("--build is the CFBundleVersion, a number")
    notes = Path(args.notes).read_text() if args.notes else ""
    signature = subprocess.run([sign_update, "-p", *keys, str(archive)], check=True, capture_output=True, text=True).stdout.strip()
    if not signature or "\n" in signature:
        sys.exit("sign_update didn't print a signature")

    appcast = Path(args.appcast)
    tree = load(appcast)
    channel = tree.getroot().find("channel")
    for item in channel.findall("item"):
        if (item.findtext(s("version")) or "").strip() == args.build:
            channel.remove(item)
    item = ET.Element("item")
    ET.SubElement(item, "title").text = f"Runlet {args.version}"
    if args.link:
        ET.SubElement(item, "link").text = args.link
    ET.SubElement(item, "pubDate").text = email.utils.formatdate(usegmt=True)
    ET.SubElement(item, s("version")).text = args.build
    ET.SubElement(item, s("shortVersionString")).text = args.version
    ET.SubElement(item, s("minimumSystemVersion")).text = args.minimum_system
    if "-" in args.version:
        ET.SubElement(item, s("channel")).text = "beta"
    description = ET.SubElement(item, "description", {s("format"): "markdown"})
    description.text = notes
    ET.SubElement(item, "enclosure", {
        "url": args.url,
        "length": str(archive.stat().st_size),
        "type": "application/octet-stream",
        s("edSignature"): signature,
    })
    # Newest first, after the channel's own elements.
    position = next((index for index, child in enumerate(channel) if child.tag == "item"), len(channel))
    channel.insert(position, item)
    ET.indent(tree, space="  ")
    appcast.parent.mkdir(parents=True, exist_ok=True)
    tree.write(appcast, encoding="utf-8", xml_declaration=True)
    subprocess.run([sign_update, *keys, str(appcast)], check=True, capture_output=True)
    subprocess.run([sign_update, "--verify", *keys, str(appcast)], check=True, capture_output=True)
    beta = " (beta channel)" if "-" in args.version else ""
    print(f"{appcast}: Runlet {args.version} ({args.build}){beta}, {archive.stat().st_size} bytes, feed signed")


def verify(args):
    sign_update = sign_update_path(args.sparkle_bin)
    result = subprocess.run([sign_update, "--verify", *key_arguments(args), args.appcast], capture_output=True, text=True)
    print(result.stdout.strip() or result.stderr.strip() or ("signature valid" if result.returncode == 0 else "signature invalid"))
    sys.exit(result.returncode)


parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
commands = parser.add_subparsers(dest="command", required=True)
add_parser = commands.add_parser("add", help="add a release and sign the feed")
add_parser.add_argument("appcast")
add_parser.add_argument("archive")
add_parser.add_argument("--version", required=True, help="the tag without v: 0.4.0 or 0.4.0-beta.7")
add_parser.add_argument("--build", required=True, help="CFBundleVersion (CURRENT_PROJECT_VERSION)")
add_parser.add_argument("--url", required=True, help="where the archive is downloaded from")
add_parser.add_argument("--link", help="the release's page")
add_parser.add_argument("--notes", help="Markdown release notes")
add_parser.add_argument("--minimum-system", default=MINIMUM_SYSTEM)
for sub in (add_parser, commands.add_parser("verify", help="check the feed's signature")):
    sub.add_argument("--ed-key-file")
    sub.add_argument("--keychain", action="store_true")
    sub.add_argument("--sparkle-bin")
commands.choices["verify"].add_argument("appcast")
args = parser.parse_args()
add(args) if args.command == "add" else verify(args)
