#!/bin/sh
# Turns a Runlet crash report's addresses back into function names, files, and lines, with the
# symbols (dSYMs) published with the release that crashed (#258, docs/crash-logs.md).
#
#   curl -fsSL https://raw.githubusercontent.com/filipac/runlet/main/scripts/symbolicate-crash.sh | sh
#   curl -fsSL …/symbolicate-crash.sh | sh -s -- ~/Library/Logs/DiagnosticReports/Runlet-2026-10-05-120000.ips
#   scripts/symbolicate-crash.sh --all [report.ips]     # every thread, not only the one that crashed
#
# With no report it takes the newest Runlet (or runlet command) report in
# ~/Library/Logs/DiagnosticReports. It downloads Runlet-<version>-dSYMs.zip from that version's
# GitHub release once, checks it against the release's SHA256SUMS.txt, keeps it in
# ~/Library/Caches/Runlet-dSYMs/<version>, and checks that its UUIDs are the crashed build's.
# Frames the report already names (system code, betas, which keep their symbols) are printed as
# they are. It reads the report and prints; it changes nothing else. It needs Xcode's command line
# tools for atos and dwarfdump (`xcode-select --install`).
set -eu

REPO="filipac/runlet"
CACHE="${HOME}/Library/Caches/Runlet-dSYMs"
ALL=0
REPORT=""
for argument in "$@"; do
    case "$argument" in
        --all|-a) ALL=1 ;;
        -h|--help) sed -n '2,16p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) REPORT="$argument" ;;
    esac
done

die() { echo "symbolicate-crash: $*" >&2; exit 1; }

if [ -z "$REPORT" ]; then
    REPORT="$(ls -t "$HOME"/Library/Logs/DiagnosticReports/Runlet*.ips "$HOME"/Library/Logs/DiagnosticReports/runlet*.ips 2>/dev/null | head -n 1 || true)"
    [ -n "$REPORT" ] || die "no Runlet crash report in ~/Library/Logs/DiagnosticReports; pass the .ips file's path"
fi
[ -f "$REPORT" ] || die "$REPORT isn't a file"
xcode-select -p >/dev/null 2>&1 && xcrun --find atos >/dev/null 2>&1 \
    || die "needs Xcode's command line tools (atos, dwarfdump): run xcode-select --install, then try again"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/runlet-crash.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT INT TERM

# The report is two JSON documents: a one-line header, then the body. JavaScript for Automation
# (built into macOS) reads them and prints tab-separated lines for the shell:
#   INFO  name version build arch thread
#   IMAGE name uuid base                (Runlet and the runlet command only)
#   THREAD number crashed
#   FRAME number image address symbol   (symbol empty when the report has none)
cat >"$WORK/parse.js" <<'JS'
ObjC.import('Foundation');
function run(argv) {
    const text = $.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null);
    if (!text || text.isNil()) { throw new Error('cannot read ' + argv[0]); }
    const all = argv[1] === '1';
    const s = text.js;
    const newline = s.indexOf('\n');
    const header = JSON.parse(s.slice(0, newline));
    const body = JSON.parse(s.slice(newline + 1));
    const images = body.usedImages || [];
    const archOf = (cpu) => /ARM/i.test(cpu || '') ? 'arm64' : 'x86_64';
    const out = [];
    const hex = (n) => '0x' + n.toString(16);
    const imageName = (i) => (images[i] && (images[i].name || (images[i].path || '').split('/').pop())) || '???';
    const threads = body.threads || [];
    const crashed = typeof body.faultingThread === 'number' ? body.faultingThread : threads.findIndex((t) => t.triggered);
    out.push(['INFO', header.app_name || header.name || 'Runlet', header.app_version || '', header.build_version || '',
              (images.find((i) => i.name === 'Runlet' || i.name === 'runlet') || {}).arch || archOf(body.cpuType), crashed].join('\t'));
    images.forEach((image) => {
        if (image.name === 'Runlet' || image.name === 'runlet') {
            out.push(['IMAGE', image.name, (image.uuid || '').toUpperCase(), hex(image.base)].join('\t'));
        }
    });
    threads.forEach((thread, number) => {
        if (!all && number !== crashed) { return; }
        out.push(['THREAD', number, number === crashed ? 'crashed' : (thread.name || thread.queue || '')].join('\t'));
        (thread.frames || []).forEach((frame, n) => {
            const image = images[frame.imageIndex] || {};
            const address = (image.base || 0) + (frame.imageOffset || 0);
            let symbol = frame.symbol ? frame.symbol + (frame.symbolLocation ? ' + ' + frame.symbolLocation : '') : '';
            if (symbol && frame.sourceFile) { symbol += ' (' + frame.sourceFile + (frame.sourceLine ? ':' + frame.sourceLine : '') + ')'; }
            out.push(['FRAME', n, imageName(frame.imageIndex), hex(address), symbol.replace(/\t/g, ' ')].join('\t'));
        });
    });
    return out.join('\n');
}
JS
osascript -l JavaScript "$WORK/parse.js" "$REPORT" "$ALL" >"$WORK/report.tsv" 2>"$WORK/parse.err" \
    || die "can't read $REPORT as a crash report: $(cat "$WORK/parse.err")"

INFO="$(grep '^INFO' "$WORK/report.tsv" | head -n 1)"
NAME="$(printf '%s' "$INFO" | cut -f 2)"
VERSION="$(printf '%s' "$INFO" | cut -f 3)"
BUILD="$(printf '%s' "$INFO" | cut -f 4)"
ARCH="$(printf '%s' "$INFO" | cut -f 5)"
[ -n "$VERSION" ] || die "$REPORT has no app version: is it a Runlet crash report?"

# Runlet's own frames the report left as addresses: they need the dSYMs.
NEEDS="$(awk -F '\t' '$1 == "FRAME" && ($3 == "Runlet" || $3 == "runlet") && $5 == "" { print $3 }' "$WORK/report.tsv" | sort -u)"

if [ -n "$NEEDS" ]; then
    DSYMS="$CACHE/$VERSION"
    if [ ! -f "$DSYMS/.verified" ]; then
        URL="https://github.com/$REPO/releases/download/v$VERSION"
        ZIP="Runlet-$VERSION-dSYMs.zip"
        echo "Downloading $ZIP…" >&2
        curl -fsSL "$URL/$ZIP" -o "$WORK/$ZIP" \
            || die "no $ZIP in the v$VERSION release: dSYMs are published for stable releases from 0.4.2 on"
        curl -fsSL "$URL/SHA256SUMS.txt" -o "$WORK/SHA256SUMS.txt" || die "couldn't download v$VERSION's SHA256SUMS.txt"
        (cd "$WORK" && grep " $ZIP\$" SHA256SUMS.txt | shasum -a 256 -c - >/dev/null) || die "$ZIP doesn't match v$VERSION's SHA256SUMS.txt"
        rm -rf "$DSYMS" && mkdir -p "$DSYMS"
        ditto -x -k "$WORK/$ZIP" "$DSYMS"
        : >"$DSYMS/.verified"
    fi
    for image in $NEEDS; do
        # The zip's top folder is Runlet-<version>-dSYMs (or Runlet-dSYMs); find the dSYM in it.
        bundle="$([ "$image" = Runlet ] && echo Runlet.app.dSYM || echo runlet.dSYM)"
        dsym="$(find "$DSYMS" -path "*/$bundle/Contents/Resources/DWARF/$image" -type f | head -n 1)"
        [ -n "$dsym" ] || die "the v$VERSION dSYMs have no symbols for $image"
        uuid="$(awk -F '\t' -v i="$image" '$1 == "IMAGE" && $2 == i { print $3; exit }' "$WORK/report.tsv")"
        base="$(awk -F '\t' -v i="$image" '$1 == "IMAGE" && $2 == i { print $4; exit }' "$WORK/report.tsv")"
        dwarfdump --uuid "$dsym" | grep -qi "$uuid" \
            || die "the v$VERSION dSYMs aren't the build that crashed ($image $uuid, $VERSION ($BUILD)); was it a beta or a local build?"
        # One atos run per image, in frame order; the results are read back in the same order.
        awk -F '\t' -v i="$image" '$1 == "FRAME" && $3 == i && $5 == "" { print $4 }' "$WORK/report.tsv" >"$WORK/$image.addresses"
        # shellcheck disable=SC2046
        atos -o "$dsym" -arch "$ARCH" -l "$base" $(cat "$WORK/$image.addresses") >"$WORK/$image.symbols"
    done
fi

echo "$NAME $VERSION ($BUILD), $ARCH: $(basename "$REPORT")"
awk -F '\t' -v big="$WORK/Runlet.symbols" -v small="$WORK/runlet.symbols" '
    $1 == "THREAD" { printf "\nThread %s%s\n", $2, ($3 == "crashed" ? " (crashed)" : ($3 != "" ? " (" $3 ")" : "")) }
    $1 == "FRAME" {
        symbol = $5
        if (symbol == "" && $3 == "Runlet") { getline symbol < big }
        else if (symbol == "" && $3 == "runlet") { getline symbol < small }
        sub(/ \(in (Runlet|runlet)\)/, "", symbol)
        printf "%3d  %-28s %s\n", $2, $3, (symbol == "" ? $4 : symbol)
    }' "$WORK/report.tsv"
