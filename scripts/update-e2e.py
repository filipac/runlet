#!/usr/bin/env python3
"""#233: in-app updates end to end, with locally built versions, a local feed, and scratch data.

Usage: scripts/update-e2e.py [--shots <dir>] [scenario ...]
Scenarios: update rollback bad-signature bad-feed missing-feed read-only not-writable
           not-configured channels automatic (default: all)

Never touches /Applications, the real GitHub releases, ~/Library/Application Support/Runlet, or
the owner's Keychain. Everything lives in build/e2e:
- a throwaway Ed25519 key (CryptoKit), never the owner's;
- Debug builds with the bundle id dev.runlet.Runlet.prshots: 0.5.0 (20), 0.5.1 (21), and
  0.6.0-beta.1 (30), built with xcodebuild version settings and the throwaway public key; a
  "broken" 0.5.2 (22) whose executable exits at once (a validly signed app that doesn't start);
  and the plain Debug build without a key;
- zips made like package.sh's (ditto), with com.apple.quarantine set on the app inside, signed
  with scripts/appcast.py (the release tool), and feeds served from 127.0.0.1;
- each scenario copies the old app to build/e2e/<scenario>/Apps and runs it with
  RUNLET_DATA_DIR=build/e2e/<scenario>/data, RUNLET_UPDATE_FEED_URL (Debug only), and
  RUNLET_DEBUG_STEPS (ghosted: nothing shows on screen).

Prints PASS/FAIL per check and exits non-zero on a failure.
"""
import argparse
import email.utils
import http.server
import os
import plistlib
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WORK = ROOT / "build/e2e"
KEYS = WORK / "keys"
PRODUCTS = WORK / "products"
FEED = WORK / "feed"
DD = ROOT / "build/DerivedData"
BIN = DD / "SourcePackages/artifacts/sparkle/Sparkle/bin"
BUNDLE_ID = "dev.runlet.Runlet.prshots"
ALL = ["update", "rollback", "bad-signature", "bad-feed", "missing-feed", "read-only", "not-writable", "not-configured", "channels", "automatic"]

parser = argparse.ArgumentParser()
parser.add_argument("--shots", help="write window screenshots here")
parser.add_argument("--rate", type=float, default=0, help="serve archives at this many bytes per second (download screenshots)")
parser.add_argument("scenarios", nargs="*", default=ALL)
args = parser.parse_args()
SHOTS = Path(args.shots).resolve() if args.shots else None
failures = []


def check(name, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + name + (f": {detail}" if detail and not ok else ""))
    if not ok:
        failures.append(name)


def run(command, **kwargs):
    return subprocess.run(command, check=True, **kwargs)


# MARK: Keys and builds

def throwaway_key():
    KEYS.mkdir(parents=True, exist_ok=True)
    os.chmod(KEYS, 0o700)
    if not (KEYS / "throwaway-private.key").exists():
        script = KEYS / "make-key.swift"
        script.write_text("""import CryptoKit
import Foundation
let dir = CommandLine.arguments[1]
for name in ["throwaway", "other"] {
    let key = Curve25519.Signing.PrivateKey()
    try! (key.rawRepresentation.base64EncodedString() + "\\n").write(toFile: dir + "/\\(name)-private.key", atomically: true, encoding: .utf8)
    try! (key.publicKey.rawRepresentation.base64EncodedString() + "\\n").write(toFile: dir + "/\\(name)-public.txt", atomically: true, encoding: .utf8)
}
""")
        run(["swift", str(script), str(KEYS)])
        for key in KEYS.glob("*-private.key"):
            os.chmod(key, 0o600)
    return (KEYS / "throwaway-public.txt").read_text().strip()


def build(name, version, build_number, prerelease="", key=""):
    target = PRODUCTS / name / "Runlet.app"
    if target.exists():
        return target
    print(f"== Building {name}: {version}{'-' + prerelease if prerelease else ''} ({build_number})")
    run(["xcodebuild", "-quiet", "-project", str(ROOT / "Runlet.xcodeproj"), "-scheme", "Runlet", "-configuration", "Debug",
         "-derivedDataPath", str(DD), f"PRODUCT_BUNDLE_IDENTIFIER={BUNDLE_ID}", f"MARKETING_VERSION={version}",
         f"CURRENT_PROJECT_VERSION={build_number}", f"RUNLET_PRERELEASE={prerelease}", f"RUNLET_UPDATE_PUBLIC_KEY={key}", "build"])
    target.parent.mkdir(parents=True, exist_ok=True)
    run(["ditto", str(DD / "Build/Products/Debug/Runlet.app"), str(target)])
    return target


def broken(source, name, version, build_number):
    """A validly signed Runlet whose executable exits at once: the update installs, then never starts."""
    target = PRODUCTS / name / "Runlet.app"
    if target.exists():
        return target
    target.parent.mkdir(parents=True, exist_ok=True)
    run(["ditto", str(source), str(target)])
    stub = WORK / "stub"
    run(["clang", "-x", "c", "-", "-o", str(stub)], input=b"int main(void) { return 1; }\n")
    shutil.copy(stub, target / "Contents/MacOS/Runlet")
    info = target / "Contents/Info.plist"
    plist = plistlib.loads(info.read_bytes())
    plist["CFBundleShortVersionString"] = version
    plist["CFBundleVersion"] = build_number
    info.write_bytes(plistlib.dumps(plist))
    run(["codesign", "--force", "--sign", "-", str(target)], capture_output=True)
    return target


def info(app):
    return plistlib.loads((Path(app) / "Contents/Info.plist").read_bytes())


def quarantined_files(path):
    out = subprocess.run(["xattr", "-r", str(path)], capture_output=True, text=True).stdout
    return [line for line in out.splitlines() if line.endswith("com.apple.quarantine")]


# MARK: Archives and feeds

def archive(app, name):
    """Runlet-<name>.zip like package.sh makes it, with the app inside marked as downloaded."""
    zip_path = FEED / f"Runlet-{name}.zip"
    if zip_path.exists():
        return zip_path
    staging = WORK / "staging" / name
    shutil.rmtree(staging, ignore_errors=True)
    staging.mkdir(parents=True)
    run(["ditto", str(app), str(staging / "Runlet.app")])
    value = f"0083;{int(time.time()):08x};Safari;"
    run(["xattr", "-w", "-r", "com.apple.quarantine", value, str(staging / "Runlet.app")])
    FEED.mkdir(parents=True, exist_ok=True)
    run(["ditto", "-c", "-k", "--keepParent", str(staging / "Runlet.app"), str(zip_path)])
    run(["xattr", "-w", "com.apple.quarantine", value, str(zip_path)])
    return zip_path


NOTES = """## New in {version}

- **Faster startup.** Projects with many snippets open sooner.
- **Output pane**
  - Long tables scroll smoothly.
  - Copy as Markdown keeps column alignment.
- **Fix:** the status bar shows the target's PHP version again.

See the [changelog](https://github.com/filipac/runlet/blob/main/CHANGELOG.md) for everything else.
"""


def feed(name, entries, archive_key="throwaway", feed_key="throwaway"):
    """An appcast of (version, build, zip) entries, written with scripts/appcast.py."""
    path = FEED / f"{name}.xml"
    path.unlink(missing_ok=True)
    for version, build_number, zip_path in entries:
        notes = WORK / f"notes-{version}.md"
        notes.write_text(NOTES.format(version=version))
        run([sys.executable, str(ROOT / "scripts/appcast.py"), "add", str(path), str(zip_path), "--version", version, "--build", build_number,
             "--url", f"{server.url}/{zip_path.name}", "--link", f"https://github.com/filipac/runlet/releases/tag/v{version}",
             "--notes", str(notes), "--ed-key-file", str(KEYS / f"{archive_key}-private.key"), "--sparkle-bin", str(BIN)], capture_output=True)
    if feed_key != archive_key:
        run([str(BIN / "sign_update"), "--ed-key-file", str(KEYS / f"{feed_key}-private.key"), str(path)], capture_output=True)
    return f"{server.url}/{path.name}"


class Server:
    """Serves build/e2e/feed on 127.0.0.1; archives at `rate` bytes per second when set."""

    def __init__(self, rate):
        handler_rate = rate

        class Handler(http.server.SimpleHTTPRequestHandler):
            def __init__(self, *a, **k):
                super().__init__(*a, directory=str(FEED), **k)

            def copyfile(self, source, outputfile):
                if not handler_rate or not self.path.endswith(".zip"):
                    return super().copyfile(source, outputfile)
                try:
                    while chunk := source.read(64 * 1024):
                        outputfile.write(chunk)
                        time.sleep(len(chunk) / handler_rate)
                except (BrokenPipeError, ConnectionResetError):
                    pass

            def log_message(self, *a):
                pass

        self.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.httpd.server_address[1]}"
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()


# MARK: Running Runlet

START = ["ghost", "scale:2", "appearance:light", "wait"]


def prepare(scenario, app):
    base = WORK / scenario
    if base.exists():
        subprocess.run(["chmod", "-R", "u+w", str(base)], capture_output=True)
        shutil.rmtree(base)
    (base / "Apps").mkdir(parents=True)
    (base / "data").mkdir()
    installed = base / "Apps/Runlet.app"
    run(["ditto", str(app), str(installed)])
    return base, installed


def shot(name):
    return [f"shot:{name}@Software Update"] if SHOTS else []


def stop_own_processes(base):
    """Stops only this test's processes: Runlet and Sparkle's helpers run from under `base`."""
    prefix = str(base.resolve()) + "/"
    out = subprocess.run(["ps", "-axo", "pid=,comm="], capture_output=True, text=True).stdout
    for line in out.splitlines():
        pid, _, command = line.strip().partition(" ")
        if command.strip().startswith(prefix):
            print(f"   stopping {pid} {command.strip()[len(prefix):]}")
            subprocess.run(["kill", pid])


def launch(base, app, steps, feed_url=None, relaunch_steps=None, env=None, timeout=180):
    log = base / "runlet.log"
    log.write_text("")
    values = {"RUNLET_DATA_DIR": str(base / "data"), "RUNLET_DEBUG_STEPS": ",".join(START + steps), "SSH_AUTH_SOCK": "",
              "RUNLET_CREDENTIALS": "memory", "RUNLET_UPDATE_RELAUNCH_STDERR": str(base / "relaunch.log"), "RUNLET_UPDATE_RELAUNCH_BACKGROUND": "1"}
    if SHOTS:
        SHOTS.mkdir(parents=True, exist_ok=True)
        values["RUNLET_SNAPSHOT_DIR"] = str(SHOTS)
        values["RUNLET_RELAUNCH_SNAPSHOT_DIR"] = str(SHOTS)
    if feed_url:
        values["RUNLET_UPDATE_FEED_URL"] = feed_url
    if relaunch_steps:
        values["RUNLET_RELAUNCH_DEBUG_STEPS"] = ",".join(START + relaunch_steps)
    values.update(env or {})
    command = ["open", "-g", "-j", "-n", "-W"]
    for key, value in values.items():
        command += ["--env", f"{key}={value}"]
    try:
        subprocess.run(command + ["--stderr", str(log), str(app)], timeout=timeout)
    except subprocess.TimeoutExpired:
        check(f"{base.name}: Runlet ended within {timeout} s", False, log.read_text()[-1500:])
        stop_own_processes(base)
    return log.read_text()


def states(text):
    return [line for line in text.splitlines() if line.startswith("RUNLET_DEBUG_STATE") or line.startswith("RUNLET_UPDATE")]


def wait_for(predicate, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(0.5)
    return False


def read(path):
    try:
        return Path(path).read_text()
    except OSError:
        return ""


# MARK: Scenarios

def scenario_update():
    base, app = prepare("update", V1)
    url = feed("update", [("0.5.1", "21", ZIP_V2)])
    text = launch(base, app, ["update-state", "update:check", "update-wait:found:60", "update-state", *shot("update-found"),
                              "update:install", "update-wait:installing:300", "update-state"],
                  feed_url=url, relaunch_steps=["update-state", *shot("update-after-relaunch")])
    check("update: offered 0.5.1 (21) with its size", any("phase=found 0.5.1 (21) size=" in line for line in states(text)), "\n".join(states(text)))
    check("update: quit to install", "update-wait installing:300: reached" in text, "\n".join(states(text)))
    data = base / "data/Updates"
    done = wait_for(lambda: '"outcome":"updated"' in read(data / "result.json") and "RUNLET_DEBUG_STEPS: done" in read(base / "relaunch.log"), 120)
    check("update: the watchdog saw the new version start", done, read(data / "watchdog.log") + read(data / "result.json"))
    plist = info(app)
    check("update: bundle replaced in place", plist.get("CFBundleVersion") == "21" and plist.get("CFBundleShortVersionString") == "0.5.1", str(plist.get("CFBundleVersion")))
    check("update: no quarantine left on the installed app", not quarantined_files(app), "\n".join(quarantined_files(app)[:5]))
    check("update: signature still valid", subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], capture_output=True).returncode == 0)
    check("update: launched marker from the new version", read(data / "launched").startswith("21\n"), read(data / "launched"))
    check("update: backup removed", not (data / "Backup/Runlet.backup").exists())
    relaunch = read(base / "relaunch.log")
    check("update: the new version knows it was updated (#232 hook)", "launched after updating from 0.5.0 (20) to 0.5.1 (21)" in relaunch and "installed=0.5.0->0.5.1" in relaunch, relaunch[-2000:])
    check("update: pending record consumed", not (data / "pending.json").exists())


def scenario_rollback():
    base, app = prepare("rollback", V1)
    url = feed("rollback", [("0.5.2", "22", ZIP_BROKEN)])
    text = launch(base, app, ["update:check", "update-wait:found:60", "update:install", "update-wait:installing:300"],
                  feed_url=url, relaunch_steps=["update-state", *shot("update-rolled-back")], env={"RUNLET_UPDATE_LAUNCH_TIMEOUT": "10"})
    check("rollback: quit to install 0.5.2", "update-wait installing:300: reached" in text, "\n".join(states(text)))
    data = base / "data/Updates"
    done = wait_for(lambda: "RUNLET_DEBUG_STEPS: done" in read(base / "relaunch.log"), 120)
    log = read(data / "watchdog.log")
    check("rollback: the restored version ran", done, log)
    check("rollback: watchdog restored the backup", "restoring the previous version" in log and "didn't start within 10 seconds" in log, log)
    check("rollback: 0.5.0 (20) is back in place", info(app).get("CFBundleVersion") == "20", str(info(app).get("CFBundleVersion")))
    check("rollback: the version that didn't start was kept aside", info(data / "Failed.backup").get("CFBundleVersion") == "22")
    relaunch = read(base / "relaunch.log")
    check("rollback: the restored version says so", "afterUpdate" in relaunch and "rolledBack" in relaunch, relaunch[-2000:])


def scenario_bad_signature():
    base, app = prepare("bad-signature", V1)
    url = feed("bad-signature", [("0.5.1", "21", ZIP_V2)], archive_key="other", feed_key="throwaway")
    text = launch(base, app, ["update:check", "update-wait:found:60", "update:install", "update-wait:problem:300", "update-state", *shot("update-bad-signature")], feed_url=url)
    lines = "\n".join(states(text))
    check("bad-signature: refused as unverified", "couldn't be verified" in lines, lines)
    check("bad-signature: app unchanged", info(app).get("CFBundleVersion") == "20")
    check("bad-signature: nothing pending", not (base / "data/Updates/pending.json").exists() and not (base / "data/Updates/Backup").exists())


def scenario_bad_feed():
    base, app = prepare("bad-feed", V1)
    url = feed("bad-feed", [("0.5.1", "21", ZIP_V2)], archive_key="throwaway", feed_key="other")
    text = launch(base, app, ["update:check", "update-wait:problem:60", "update-state"], feed_url=url)
    lines = "\n".join(states(text))
    check("bad-feed: a feed signed with another key isn't read", "couldNotCheck" in lines, lines)
    check("bad-feed: app unchanged", info(app).get("CFBundleVersion") == "20")


def scenario_missing_feed():
    base, app = prepare("missing-feed", V1)
    text = launch(base, app, ["update:check", "update-wait:problem:60", "update-state", *shot("update-missing-feed")], feed_url=f"{server.url}/missing.xml")
    lines = "\n".join(states(text))
    check("missing-feed: calm 'couldn't check'", "couldNotCheck" in lines and "404" in lines, lines)


def scenario_read_only():
    base = WORK / "read-only"
    shutil.rmtree(base, ignore_errors=True)
    (base / "dmg-root").mkdir(parents=True)
    (base / "data").mkdir()
    run(["ditto", str(V1), str(base / "dmg-root/Runlet.app")])
    dmg = base / "Runlet.dmg"
    run(["hdiutil", "create", "-quiet", "-volname", "Runlet", "-srcfolder", str(base / "dmg-root"), "-format", "UDZO", str(dmg)])
    mount = base / "mount"
    mount.mkdir()
    run(["hdiutil", "attach", "-quiet", "-readonly", "-nobrowse", "-mountpoint", str(mount), str(dmg)])
    try:
        url = feed("read-only", [("0.5.1", "21", ZIP_V2)])
        text = launch(base, mount / "Runlet.app", ["update:check", "update-wait:problem:60", "update-state", *shot("update-move-to-applications")], feed_url=url)
        lines = "\n".join(states(text))
        check("read-only: asks to move Runlet to Applications", "mustMove" in lines and "readOnlyVolume" in lines, lines)
    finally:
        subprocess.run(["hdiutil", "detach", "-quiet", str(mount)])


def scenario_not_writable():
    base, app = prepare("not-writable", V1)
    url = feed("not-writable", [("0.5.1", "21", ZIP_V2)])
    os.chmod(base / "Apps", 0o555)
    try:
        text = launch(base, app, ["update:check", "update-wait:found:60", "update-state", *shot("update-needs-administrator"), "update:later"], feed_url=url)
        lines = "\n".join(states(text))
        check("not-writable: offers the update and explains the password prompt", "phase=found" in lines and "needsAdministrator" in lines, lines)
    finally:
        os.chmod(base / "Apps", 0o755)
    check("not-writable: app unchanged", info(app).get("CFBundleVersion") == "20")


def scenario_not_configured():
    base, app = prepare("not-configured", NO_KEY)
    text = launch(base, app, ["update:check", "update-wait:problem:30", "update-state", *shot("update-not-configured")], feed_url=f"{server.url}/update.xml")
    lines = "\n".join(states(text))
    check("not-configured: no key, no install", "configured=false" in lines and "notConfigured" in lines, lines)


def scenario_channels():
    base, app = prepare("channels", V1)
    url = feed("channels", [("0.5.1", "21", ZIP_V2), ("0.6.0-beta.1", "30", ZIP_BETA)])
    text = launch(base, app, [
        "update:check", "update-wait:found:60", "update-state", "update:later",
        "update:channel:beta", "update:check", "update-wait:found:60", "update-state", *shot("update-beta-found"), "update:skip",
        "update:auto", "wait", "wait", "update-state",
        "update:check", "update-wait:found:60", "update-state", "update:later",
    ], feed_url=url)
    lines = [line for line in states(text) if "update-state" in line]
    check("channels: Stable offers the release 0.5.1", len(lines) > 0 and "channel=stable" in lines[0] and "found 0.5.1 (21)" in lines[0], "\n".join(lines))
    check("channels: Beta offers 0.6.0 beta 1", len(lines) > 1 and "channel=beta" in lines[1] and "found 0.6.0 beta 1 (30)" in lines[1], "\n".join(lines))
    check("channels: an automatic check skips the skipped version", len(lines) > 2 and "phase=idle" in lines[2], "\n".join(lines))
    check("channels: Check for Updates shows it again", len(lines) > 3 and "found 0.6.0 beta 1 (30)" in lines[3], "\n".join(lines))
    # On the newest build: nothing to offer.
    base2, latest = prepare("channels-latest", V2)
    text = launch(base2, latest, ["update:check", "update-wait:upToDate:60", "update-state", *shot("update-up-to-date")], feed_url=url)
    lines = "\n".join(states(text))
    check("channels: up to date on the latest stable", "phase=upToDate" in lines, lines)


def scenario_automatic():
    base, app = prepare("automatic", V1)
    url = feed("automatic", [("0.5.1", "21", ZIP_V2)])
    text = launch(base, app, ["update-wait:found:60", "update-state", "update:later"], feed_url=url, env={"RUNLET_UPDATE_AUTOMATIC": "1"})
    lines = "\n".join(states(text))
    check("automatic: the launch check offers the update", "phase=found 0.5.1 (21)" in lines and "automatic=on" in lines, lines)
    base2, app2 = prepare("automatic-off", V1)
    text = launch(base2, app2, ["wait", "wait", "wait", "wait", "update-state"], feed_url=url)
    lines = "\n".join(states(text))
    check("automatic: Debug and scripted sessions never check on their own", "phase=idle" in lines and "automatic=scripted Debug session" in lines, lines)


# MARK: Main

PUBLIC = throwaway_key()
NO_KEY = build("no-key", "0.5.0", "20")
V1 = build("v1", "0.5.0", "20", key=PUBLIC)
V2 = build("v2", "0.5.1", "21", key=PUBLIC)
BETA = build("beta", "0.6.0", "30", prerelease="beta.1", key=PUBLIC)
BROKEN = broken(V2, "broken", "0.5.2", "22")
server = Server(args.rate)
ZIP_V2 = archive(V2, "0.5.1")
ZIP_BETA = archive(BETA, "0.6.0-beta.1")
ZIP_BROKEN = archive(BROKEN, "0.5.2")

# The archives carry the quarantine attribute inside, as a browser download would.
probe = WORK / "probe"
shutil.rmtree(probe, ignore_errors=True)
run(["ditto", "-x", "-k", str(ZIP_V2), str(probe)])
check("setup: the served archive's app is quarantined", bool(quarantined_files(probe / "Runlet.app")))
check("setup: builds carry their versions", info(V1)["CFBundleVersion"] == "20" and info(V2)["CFBundleShortVersionString"] == "0.5.1" and info(BETA).get("RunletPrerelease") == "beta.1")

for name in args.scenarios:
    print(f"== {name}")
    globals()["scenario_" + name.replace("-", "_")]()

for name in args.scenarios:
    stop_own_processes(WORK / name)
print(f"{len(failures)} failure(s)" if failures else "All checks passed")
sys.exit(1 if failures else 0)
