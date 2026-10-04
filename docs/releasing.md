# Releasing Runlet

How a release (stable or beta) is built, signed for in-app updates, and published. In-app updates
are [#233](https://github.com/filipac/runlet/issues/233); Developer ID signing and notarization
are still [#24](https://github.com/filipac/runlet/issues/24), so releases stay ad-hoc signed.

## How updates reach users

Runlet checks one **appcast** (Sparkle's RSS feed) for both channels:

```text
https://raw.githubusercontent.com/filipac/runlet/appcast/appcast.xml
```

- **Where it lives.** It is `appcast.xml` on an orphan branch, `appcast`, that holds nothing else.
- **Why not a release asset.** GitHub's `releases/latest/download/…` never points at a
  pre-release, so a feed there would hide betas from the Beta channel. A branch gives one fixed
  URL for every release.
- **Items.** Each `<item>` is one release.
  - Its download URL is the release's own asset:
    `releases/download/v0.4.0-beta.7/Runlet-0.4.0-beta.7.zip`, which works for pre-releases too.
  - Betas carry `<sparkle:channel>beta</sparkle:channel>`. The Stable channel ignores them; Beta
    sees everything.
- **Signatures.** Every archive has an EdDSA signature (`sparkle:edSignature`), and the feed
  itself is signed (a `sparkle-signatures` comment at its end). Runlet's Info.plist requires both
  (`SURequireSignedFeed`, `SUVerifyUpdateBeforeExtraction`), and checks them against its public key
  (`SUPublicEDKey`, from `RUNLET_UPDATE_PUBLIC_KEY` in `project.yml`).
- **Caching.** raw.githubusercontent.com caches files for about five minutes, so a pushed feed
  reaches users within minutes.
- **No feed yet.** Until the branch exists, checks get a 404. Runlet says it couldn't check, and
  automatic checks stay quiet.

**Alternative.** If the website moves to GitHub Pages, the same file can be served from there:
change `SUFeedURL` in `project.yml`. Nothing else changes.

## One-time setup (the owner)

### 1. The update signing key

The private key signs every update. Whoever has it can ship updates to every Runlet user, so:

- keep it out of this repository and out of any CI that doesn't need it;
- back it up. Without it, users can't verify new releases and have to reinstall by hand.

Sparkle's tools come with its Swift package. After any build (for example `scripts/package.sh`),
they are in `build/Release-DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/`. Pick one way
to generate the key:

- **In your login Keychain** (Sparkle's default). This prints the public key:

  ```sh
  build/Release-DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys
  ```

  Back it up with `generate_keys -x <file outside the repo>`. Sign later with `--keychain`.
- **In a key file outside the repository.** The file holds the base64 Ed25519 seed, which is what
  `sign_update --ed-key-file` reads. macOS's own `openssl` (LibreSSL) can't make Ed25519 keys, so use
  OpenSSL 3 (Homebrew's `openssl@3`):

  ```sh
  OPENSSL=/opt/homebrew/opt/openssl@3/bin/openssl
  umask 077
  $OPENSSL genpkey -algorithm ed25519 -outform DER -out /tmp/runlet-update.der
  tail -c 32 /tmp/runlet-update.der | base64 > ~/Secrets/runlet-update.key      # private
  $OPENSSL pkey -in /tmp/runlet-update.der -inform DER -pubout -outform DER | tail -c 32 | base64   # public
  rm /tmp/runlet-update.der
  ```

  Sign later with `--ed-key-file ~/Secrets/runlet-update.key`.

### 2. The public key in the app

Put the **public** key (44 characters of base64) in `project.yml`, in the Runlet target's settings:

```yaml
RUNLET_UPDATE_PUBLIC_KEY: "<public key>"
```

Run `xcodegen generate` and commit. Until this is set, builds refuse to install updates:
Check for Updates says updates aren't set up, and `--self-test` reports "no update key".

### 3. The appcast branch

Create the `appcast` branch once, from a separate worktree:

```sh
git worktree add --detach ../runlet-appcast
cd ../runlet-appcast
git switch --orphan appcast
```

The first `scripts/appcast.py add` (below) creates and signs `appcast.xml` there. Commit it and
`git push origin appcast`.

### 4. The first updater-capable release is installed by hand

Releases before the first one with the updater (0.4.0 betas 1–6 and older) can't update themselves.
Install the first updater-capable release by hand, once:

1. Download the DMG and drag Runlet to Applications, replacing the old copy.
2. Remove the quarantine flag (see the readme's First launch).

From then on, Runlet updates itself. The release notes of that release should say so.

## Every release

The examples are for a beta, `0.4.0-beta.7` with build 13. For a stable release, use `0.4.0`, an
empty `RUNLET_PRERELEASE`, and a normal (not pre-release) GitHub release.

1. **Version.** Make a release commit on the commit you release.
   - In `project.yml`, set `MARKETING_VERSION: "0.4.0"` and `RUNLET_PRERELEASE: "beta.7"` (empty
     for a stable release).
   - Raise `CURRENT_PROJECT_VERSION` (`"13"`) above every earlier release, beta or stable. Sparkle
     compares build numbers and refuses an update with a lower one.
   - Run `xcodegen generate`.
   - **What's New.** Add What's New entries for the release's important features to
     `Runlet/WhatsNew.json`, keyed by this version and build (`0.4.0`, `13`, labelled
     "0.4.0 beta 7"), with Show Me tours for the important ones (see
     [whats-new.md](whats-new.md#adding-entries-for-a-release),
     [#232](https://github.com/filipac/runlet/issues/232)). `WhatsNewTests` fail when this
     version isn't covered.
   - **Tests.** Run `scripts/test.sh full` with the fixtures running and the `RUNLET_TEST_*`
     variables set ([validation.md](validation.md#package-tests),
     [#242](https://github.com/filipac/runlet/issues/242)). It takes about a minute and must pass
     without warnings about missing fixtures.
   - Commit (`Pre-release 0.4.0 beta 7: version 0.4.0 (13)`) and tag it (`v0.4.0-beta.7`).
2. **Build.** Run `scripts/package.sh`. It must end with a passing self-test, and its `updater`
   check must say "update key set". It warns when What's New has no entry for the packaged
   version and build.
3. **Files.** Rename the archives and write the checksums:

   ```sh
   cd dist
   mv Runlet.zip Runlet-0.4.0-beta.7.zip
   mv Runlet.dmg Runlet-0.4.0-beta.7.dmg
   shasum -a 256 Runlet-0.4.0-beta.7.zip Runlet-0.4.0-beta.7.dmg > SHA256SUMS.txt
   ```

4. **GitHub release.** Publish it with the three files (`--prerelease` for a beta). Its body is
   the release notes.
5. **Appcast.** Sign the zip you uploaded and add it to the feed. `appcast.py` signs the archive,
   adds the item (tagged beta for a pre-release), and signs the feed again:

   ```sh
   gh release view v0.4.0-beta.7 --json body -q .body > /tmp/runlet-notes.md
   scripts/appcast.py add ../runlet-appcast/appcast.xml dist/Runlet-0.4.0-beta.7.zip \
       --version 0.4.0-beta.7 --build 13 \
       --url https://github.com/filipac/runlet/releases/download/v0.4.0-beta.7/Runlet-0.4.0-beta.7.zip \
       --link https://github.com/filipac/runlet/releases/tag/v0.4.0-beta.7 \
       --notes /tmp/runlet-notes.md \
       --keychain            # or: --ed-key-file ~/Secrets/runlet-update.key
   cd ../runlet-appcast && git add appcast.xml && git commit -m "Runlet 0.4.0 beta 7" && git push origin appcast
   ```

   - The signature covers the archive's bytes. Sign the exact file you uploaded, and upload
     before you push the feed, or users get an item whose download fails.
   - Never edit `appcast.xml` by hand afterwards. Change it with `appcast.py`, or sign it again
     with `sign_update`.
6. **Check.** Run `scripts/appcast.py verify ../runlet-appcast/appcast.xml --keychain` (or
   `--ed-key-file …`). After a few minutes, an older build's **Runlet ▸ Check for Updates…**
   offers the release on its channel.

## What a user's update does

1. Sparkle downloads the zip and checks its EdDSA signature against the app's key before
   extracting it.
2. It checks that the app inside has a valid code signature and isn't older (by build number),
   and removes the quarantine attribute.
3. Runlet copies itself to `Updates/Backup` in its data folder and starts a watchdog. It then quits,
   and Sparkle's installer swaps the new bundle in, in one atomic step.
4. The watchdog checks the new bundle (identifier, build, no quarantine), starts it, and waits for
   its "launched" marker. Without the marker in 60 seconds, it puts the backup back, starts the old
   version, and that version says what happened. With the marker, it removes the backup.
5. If Runlet's folder isn't writable (an administrator owns it), macOS asks for an administrator's
   name and password before installing. If Runlet runs from the DMG or a translocated copy, it
   asks you to move it to Applications first.

Details are in [architecture.md](architecture.md#in-app-updates-233).

## Testing the updater

`scripts/update-e2e.py` runs the whole flow locally:

- builds 0.5.0 (20), 0.5.1 (21), a 0.6.0 beta (30), and a 0.5.2 (22) that can't start, with a
  throwaway key in `build/e2e/keys`;
- serves feeds made with `appcast.py` from 127.0.0.1;
- updates copies of the app in `build/e2e/<scenario>/Apps`, with scratch data, Debug builds, and
  the bundle id `dev.runlet.Runlet.prshots`.

The scenarios are: update and relaunch, rollback, a bad archive signature, a bad feed signature, a
missing feed, a read-only disk image, a folder that isn't writable, a build without a key, the
channels and Skip This Version, and the automatic launch check. The test never uses the real feed,
GitHub releases, or `/Applications`.
