#!/bin/sh
# Copies the installed Runlet's tabs, settings, targets, snippets, and history into Runlet Dev,
# the app Xcode builds (#267), once. Runlet's own data is only read. Runlet Dev's current state, if
# any, is moved aside first (State.before-copy-<time>), so nothing is lost.
#
#   scripts/copy-data-to-dev.sh
#
# It copies ~/Library/Application Support/Runlet/State to ~/Library/Application Support/Runlet Dev/State,
# and refuses while either app runs (they write their state when they quit). Not copied:
# passwords of saved database connections (they stay in Runlet's Keychain items; Runlet Dev asks
# for them again in Edit Connection), the sandbox install, Runlet's PHP, and caches, which Runlet
# Dev sets up itself.
set -eu

SUPPORT="${HOME}/Library/Application Support"
SOURCE="$SUPPORT/Runlet"
TARGET="$SUPPORT/Runlet Dev"

die() { echo "copy-data-to-dev: $*" >&2; exit 1; }

running() { # running <bundle id>
    [ "$(osascript -e "application id \"$1\" is running" 2>/dev/null || echo false)" = true ]
}
running dev.runlet.Runlet && die "quit Runlet first: it writes its state when it quits"
running dev.runlet.Runlet.dev && die "quit Runlet Dev first: it would write its state over the copy"

[ -d "$SOURCE/State" ] || die "no Runlet data in $SOURCE/State"
mkdir -p "$TARGET"
if [ -d "$TARGET/State" ]; then
    aside="$TARGET/State.before-copy-$(date +%Y%m%d-%H%M%S)"
    mv "$TARGET/State" "$aside"
    echo "Runlet Dev's previous state is in $aside"
fi
ditto "$SOURCE/State" "$TARGET/State"
echo "Copied Runlet's tabs, settings, targets, snippets, and history into Runlet Dev."
echo "Saved database connections need their passwords again in Runlet Dev (Edit Connection)."
