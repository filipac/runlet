#!/usr/bin/env bash
# Guided release of Runlet, beta or stable (#263). It asks, does the mechanical work, and stops
# before anything leaves this Mac. docs/releasing.md explains every step.
#
#   scripts/release.sh                       prepare the release PR, wait for the merge, publish
#   scripts/release.sh prepare               only the release PR
#   scripts/release.sh publish [<version>]   after the PR is merged: package, release, appcast
#   scripts/release.sh clean <version>       remove a release's worktrees, local branch, and progress
#   add --dry-run to any of them: it works locally and only prints what it would push or publish
#   add --claude to have Claude Code (claude -p, model haiku) draft the CHANGELOG summary, the What's
#     New lines, and the release notes' "What changed" for you to edit; without it, it asks once
#     when the claude command is installed. RUNLET_RELEASE_MODEL picks another model.
#
# prepare: release issue → branch in its own worktree (build/release/…) → project.yml version and
#   build → leftover changelog.d fragments (#277) → CHANGELOG section (stable) → What's New entry →
#   tests → commit, push, PR.
# publish: tag the merge commit → scripts/package.sh (stripped + dSYMs for stable) → files and
#   SHA256SUMS.txt → release notes (edited in $EDITOR) → GitHub release → download check →
#   appcast.py add/verify --keychain (your Keychain asks) → push the appcast branch.
# Progress is kept in .git/runlet-release/<version>, so a stopped run can be resumed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="filipac/runlet"
# The release branch starts here; another ref only for trying the script itself (#263).
BASE="${RUNLET_RELEASE_BASE:-origin/main}"
COMMON="$(cd "$ROOT" && cd "$(git rev-parse --git-common-dir)" && pwd)"
STATE_DIR="$COMMON/runlet-release"
DRY_RUN=0
CLAUDE="${RUNLET_RELEASE_CLAUDE:-}"
MODEL="${RUNLET_RELEASE_MODEL:-haiku}"
COMMAND=""
ARG_VERSION=""
for argument in "$@"; do
    case "$argument" in
        --dry-run) DRY_RUN=1 ;;
        prepare|publish|clean) COMMAND="$argument" ;;
        --claude) CLAUDE=1 ;;
        -h|--help) awk 'NR > 1 && !/^#/ {exit} NR > 1 {sub(/^# ?/, ""); print}' "$0"; exit 0 ;;
        *) ARG_VERSION="$argument" ;;
    esac
done

# ── Output and questions ─────────────────────────────────────────────────────────────────────
bold() { printf '\033[1m%s\033[0m\n' "$*"; }
step() { printf '\n\033[1;34m▸ %s\033[0m\n' "$*"; }
note() { printf '  %s\n' "$*"; }
warn() { printf '\033[33m  ! %s\033[0m\n' "$*" >&2; }
die() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
ask() { # ask "Question" default → prints the answer
    local answer
    read -r -p "  $1${2:+ [$2]}: " answer || true
    printf '%s' "${answer:-${2:-}}"
}
confirm() { # confirm "Question" [Y|N default]
    local answer default="${2:-N}"
    read -r -p "  $1 $([[ "$default" == Y ]] && echo '[Y/n]' || echo '[y/N]') " answer || true
    answer="${answer:-$default}"
    [[ "$answer" == [yY]* ]]
}
outward() { # outward "what it does" command…: asks first; in a dry run only prints
    local what="$1"
    shift
    if [[ "$DRY_RUN" == 1 ]]; then
        note "[dry run] would $what: $*"
        return 0
    fi
    confirm "$what?" Y || die "stopped before: $what. Run it again to continue."
    "$@"
}
editor() { # opens a file in the user's editor and waits for it
    local command="${VISUAL:-${EDITOR:-nano}}"
    case "$(basename "${command%% *}")" in
        code|cursor|zed) [[ "$command" == *--wait* || "$command" == *" -w"* ]] || command="$command --wait" ;;
        subl) [[ "$command" == *" -w"* ]] || command="$command -w" ;;
    esac
    note "Opening $(basename "$1") in ${command%% *}; save and close it to continue."
    # Terminal editors need the terminal even when this script's input is piped.
    if { : </dev/tty; } 2>/dev/null; then
        # shellcheck disable=SC2086
        $command "$1" </dev/tty
    else
        # shellcheck disable=SC2086
        $command "$1"
    fi
}

# ── Drafts from Claude Code (#263) ─────────────────────────────────────────────────────────────
use_claude() { # whether to draft texts with Claude: --claude, or asked once
    command -v claude >/dev/null 2>&1 || return 1
    if [[ -z "$CLAUDE" ]]; then
        confirm "Let Claude ($MODEL) draft the texts for you to edit?" N && CLAUDE=1 || CLAUDE=0
    fi
    [[ "$CLAUDE" == 1 ]]
}
claude_draft() { # claude_draft "task" < input: prints the draft; fails quietly so the script asks instead
    local dir out
    dir="$(mktemp -d "${TMPDIR:-/tmp}/runlet-release-claude.XXXXXX")"
    # No tools, no MCP servers, nothing saved, and outside the repository: it only sees what is
    # piped in, and only writes text.
    out="$(cd "$dir" && claude -p --model "$MODEL" --tools "" --strict-mcp-config --no-session-persistence \
        --output-format text ${RUNLET_RELEASE_CLAUDE_FLAGS:-} \
        --system-prompt "You write release text for Runlet, a free, open-source PHP scratchpad for macOS. Write for its users: plain, concrete sentences, no marketing words, no emoji. Output only the requested text: no preamble, no headings, no code fences." \
        "$1" 2>/dev/null)" || { rm -rf "$dir"; return 1; }
    rm -rf "$dir"
    out="$(printf '%s\n' "$out" | sed '/^```/d')"
    [[ -n "${out//[[:space:]]/}" ]] || return 1
    printf '%s\n' "$out"
}

# ── Versions ──────────────────────────────────────────────────────────────────────────────────
yml_value() { # yml_value <project.yml text> KEY
    printf '%s\n' "$1" | grep -E "^ +$2:" | head -n 1 | sed -E 's/^[^:]+: *"?([^"]*)"?.*/\1/'
}
tag_for() { [[ -n "$2" ]] && echo "v$1-$2" || echo "v$1"; }           # tag_for 0.5.0 beta.1
label_for() { [[ -n "$2" ]] && echo "$1 ${2/./ }" || echo "$1"; }     # "0.5.0 beta 1"
highest_build() {
    local main_build appcast_build
    main_build="$(yml_value "$(git -C "$ROOT" show origin/main:project.yml)" CURRENT_PROJECT_VERSION)"
    appcast_build="$(git -C "$ROOT" show origin/appcast:appcast.xml 2>/dev/null | grep -oE '<sparkle:version>[0-9]+' | grep -oE '[0-9]+$' | sort -n | tail -n 1 || true)"
    echo $(( main_build > ${appcast_build:-0} ? main_build : ${appcast_build:-0} ))
}

save_state() { # save_state <version-tag> KEY=value…
    mkdir -p "$STATE_DIR"
    local file="$STATE_DIR/$1"
    shift
    for pair in "$@"; do
        grep -v "^${pair%%=*}=" "$file" 2>/dev/null >"$file.tmp" || true
        echo "$pair" >>"$file.tmp"
        mv "$file.tmp" "$file"
    done
}
load_state() { # load_state <version-tag>: sets the saved variables
    [[ -f "$STATE_DIR/$1" ]] || return 1
    # shellcheck disable=SC1090
    source "$STATE_DIR/$1"
}

need() { command -v "$1" >/dev/null 2>&1 || die "needs $1${2:+ ($2)}"; }

preflight() {
    need git
    need gh "brew install gh"
    need xcodegen "brew install xcodegen"
    need python3
    gh auth status >/dev/null 2>&1 || die "gh isn't signed in: run gh auth login"
    git -C "$ROOT" fetch -q origin --tags
    git -C "$ROOT" fetch -q origin appcast 2>/dev/null || warn "no appcast branch on origin yet (docs/releasing.md, one-time setup)"
}

# ── CHANGELOG fragments (#277) ───────────────────────────────────────────────────────────────
fragments_at() { # fragments_at <ref>: the changelog.d fragments there, one per line
    git -C "$ROOT" ls-tree --name-only "$1" changelog.d/ 2>/dev/null | grep -E '^changelog\.d/[0-9][^/]*\.md$' || true
}
wait_for_collection() { # the Changelog workflow collects main's fragments after each merge; waits for it
    local left tries=0
    left="$(fragments_at origin/main)"
    [[ -n "$left" ]] || return 0
    step "CHANGELOG fragments"
    note "main has fragments the Changelog workflow hasn't collected into CHANGELOG.md yet:"
    printf '%s\n' "$left" | sed 's/^/    • /'
    note "Waiting for it (up to two minutes), so the release branch starts after its commit…"
    while (( tries < 24 )); do
        sleep 5
        tries=$((tries + 1))
        git -C "$ROOT" fetch -q origin main
        if [[ -z "$(fragments_at origin/main)" ]]; then
            note "Collected."
            return 0
        fi
    done
    warn "still not collected (see Actions ▸ Changelog): the release collects them itself"
}

ensure_fixtures() { # ensure_fixtures <worktree>: what the tests and package.sh need
    local worktree="$1"
    [[ -f "$worktree/Resources/Sandbox/laravel/vendor/autoload.php" ]] || (cd "$worktree" && scripts/build-sandbox.sh >/dev/null)
    [[ -f "$worktree/Tests/Fixtures/custom-driver/vendor/autoload.php" ]] || (cd "$worktree" && scripts/setup-fixtures.sh >/dev/null)
}

# ── prepare ───────────────────────────────────────────────────────────────────────────────────
prepare() {
    step "Checking"
    preflight
    local main_yml current current_pre
    main_yml="$(git -C "$ROOT" show origin/main:project.yml)"
    current="$(yml_value "$main_yml" MARKETING_VERSION)"
    current_pre="$(yml_value "$main_yml" RUNLET_PRERELEASE)"
    note "main is at $(label_for "$current" "$current_pre") (build $(yml_value "$main_yml" CURRENT_PROJECT_VERSION)); the highest released build is $(highest_build)."

    step "Which release"
    local kind version prerelease="" build suggested major minor patch
    kind="$(ask "Stable or beta? (s/b)" s)"
    IFS=. read -r major minor patch <<<"$current"
    if [[ "$kind" == b* ]]; then
        local next_beta=1
        if [[ "$current_pre" == beta.* ]]; then
            suggested="$current"
            next_beta=$(( ${current_pre#beta.} + 1 ))
        else
            suggested="$major.$((minor + 1)).0"
        fi
        version="$(ask "Version (the beta of which release)" "$suggested")"
        prerelease="beta.$(ask "Beta number" "$next_beta")"
    else
        # Betas of a version become that version; otherwise the next patch.
        [[ -n "$current_pre" ]] && suggested="$current" || suggested="$major.$minor.$((patch + 1))"
        version="$(ask "Version" "$suggested")"
    fi
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "$version isn't x.y.z"
    build=$(( $(highest_build) + 1 ))
    local tag label
    tag="$(tag_for "$version" "$prerelease")"
    label="$(label_for "$version" "$prerelease")"
    git -C "$ROOT" ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1 && die "$tag already exists"
    bold "  Runlet $label, build $build, tag $tag"
    confirm "Prepare it?" Y || exit 0
    save_state "$tag" "VERSION=$version" "PRERELEASE=$prerelease" "BUILD=$build" "TAG=$tag" "LABEL='$label'"

    step "Release issue"
    local issue="${ISSUE:-}"
    load_state "$tag" || true
    if [[ -z "${ISSUE:-}" ]]; then
        local body
        body="$(printf 'Release Runlet %s (build %s), guided by `scripts/release.sh` (#263).\n\n- [ ] project.yml, CHANGELOG, What'"'"'s New, tests: the release PR\n- [ ] After merge: tag `%s`, `scripts/package.sh`, GitHub release, appcast item signed by the owner\n\nSteps: docs/releasing.md.' "$label" "$build" "$tag")"
        if [[ "$DRY_RUN" == 1 ]]; then
            note "[dry run] would create the issue \"Release $label\""
            issue=0
        else
            confirm "Create the GitHub issue \"Release $label\"?" Y || die "stopped"
            issue="$(gh issue create --repo "$REPO" --title "Release $label" --label documentation --label area:distribution --label priority:P2 --body "$body" | grep -oE '[0-9]+$')"
        fi
        save_state "$tag" "ISSUE=$issue"
    else
        issue="$ISSUE"
    fi
    note "Issue #$issue"

    local branch="release/$tag" worktree="$ROOT/build/release/$tag"
    [[ -d "$worktree" || "$BASE" != origin/main ]] || wait_for_collection
    step "Branch"
    if [[ ! -d "$worktree" ]]; then
        mkdir -p "$ROOT/build/release"
        git -C "$ROOT" worktree add -q -b "$branch" "$worktree" "$BASE"
    fi
    note "$worktree (branch $branch)"
    cd "$worktree"

    step "Version in project.yml"
    sed -i '' -E \
        -e "s/^(        MARKETING_VERSION: )\"[^\"]*\"/\1\"$version\"/" \
        -e "s/^(        CURRENT_PROJECT_VERSION: )\"[^\"]*\"/\1\"$build\"/" \
        -e "s/^(        RUNLET_PRERELEASE: )\"[^\"]*\"/\1\"$prerelease\"/" project.yml
    xcodegen generate >/dev/null
    grep -E '^        (MARKETING_VERSION|CURRENT_PROJECT_VERSION|RUNLET_PRERELEASE):' project.yml | sed 's/^ */  /'

    unreleased_text() { awk '/^## Unreleased/{f=1;next} f&&/^## /{exit} f' CHANGELOG.md; }
    step "CHANGELOG"
    # Fragments the workflow didn't collect go in with the release (#277).
    if [[ -n "$(fragments_at HEAD)" ]]; then
        note "Collecting the fragments still in changelog.d:"
        python3 scripts/changelog.py collect | sed 's/^/    /'
    fi
    local unreleased
    unreleased="$(awk '/^## Unreleased/{f=1;next} f&&/^## /{exit} f&&/^### /' CHANGELOG.md | sed -E 's/^### [0-9-]+ — //; s/ \(\[#([0-9]+)\][^)]*\)\)?$/ (#\1)/')"
    if [[ -z "$unreleased" ]]; then
        warn "nothing under ## Unreleased in CHANGELOG.md"
        confirm "Release anyway?" N || die "stopped: merge the changes (with their changelog.d fragments) first"
    else
        note "Under Unreleased:"
        printf '%s\n' "$unreleased" | sed 's/^/    • /'
    fi
    if [[ -z "$prerelease" ]] && ! grep -q "^## $version — " CHANGELOG.md; then
        local summary="$worktree/build/release-summary.md"
        mkdir -p "$worktree/build"
        { echo "# The summary at the top of CHANGELOG.md's \"## $version\" section: a few sentences or"
          echo "# bullets about what this release brings. Lines starting with # are left out."
          echo "# Under Unreleased:"
          printf '%s\n' "$unreleased" | sed 's/^/#   • /'
          echo; } >"$summary"
        if use_claude; then
            note "Asking Claude ($MODEL) for a draft…"
            unreleased_text | claude_draft "Below are the CHANGELOG entries of Runlet $version. Write the summary for the top of its \"## $version\" section: two to five sentences, or a short bullet list with \"- \", about what users get, most important first. Wrap lines at 100 characters." >>"$summary" \
                || warn "no draft from Claude: write it yourself"
        fi
        editor "$summary"
        python3 - "$version" "$summary" <<'PY'
import sys, datetime, textwrap
version, summary_path = sys.argv[1], sys.argv[2]
text = "\n".join(l for l in open(summary_path).read().splitlines() if not l.startswith("#")).strip()
if not text:
    sys.exit("the summary is empty")
p = "CHANGELOG.md"
s = open(p).read()
anchor = "## Unreleased\n\n"
assert anchor in s, "CHANGELOG.md has no '## Unreleased' heading"
section = f"## {version} — {datetime.date.today().isoformat()}\n\n{text}\n\n"
open(p, "w").write(s.replace(anchor, anchor + section, 1))
PY
        note "Added \"## $version — $(date +%F)\" with your summary."
    elif [[ -n "$prerelease" ]]; then
        note "A beta keeps its changes under Unreleased; the stable release gets the section."
    fi

    step "What's New"
    if python3 -c "import json,sys; m=json.load(open('Runlet/WhatsNew.json')); sys.exit(0 if any(r['version']=='$version' and r['build']==$build for r in m['releases']) else 1)"; then
        note "Runlet/WhatsNew.json already has $label ($build)."
    else
        note "What's New shows each release once after an update. Give it one or more short lines for"
        note "\"Also in this version\" (empty line to finish), or type e to edit Runlet/WhatsNew.json yourself"
        note "(features with Show Me tours: docs/whats-new.md)."
        local lines=() line=""
        if use_claude; then
            note "Asking Claude ($MODEL) for lines…"
            local draft
            if draft="$( { unreleased_text; awk -v v="$version" '$0 ~ "^## " v " — "{f=1;next} f&&/^## /{exit} f' CHANGELOG.md; } \
                | claude_draft "Below are the changes in Runlet $label. Write one to three short lines for the app's What's New window, one per line, without bullets: each one sentence a user understands, about what they can do now or what works better. Skip development-only changes such as tests and scripts.")"; then
                printf '%s\n' "$draft" | sed 's/^[-•*] *//' | sed '/^[[:space:]]*$/d' >"$worktree/build/whats-new-lines.txt"
                note "Claude suggests:"
                sed 's/^/    · /' "$worktree/build/whats-new-lines.txt"
                local choice
                choice="$(ask "Use them (y), edit them (e), or type your own (n)?" y)"
                [[ "$choice" == e* ]] && editor "$worktree/build/whats-new-lines.txt"
                if [[ "$choice" == [ye]* ]]; then
                    while IFS= read -r line; do [[ -n "$line" ]] && lines+=("$line"); done <"$worktree/build/whats-new-lines.txt"
                    line=""
                fi
            else
                warn "no draft from Claude: type the lines yourself"
            fi
        fi
        while [[ ${#lines[@]} -eq 0 ]]; do
            read -r -p "  · " line || line=""
            [[ -z "$line" ]] && break
            [[ "$line" == e ]] && break
            lines+=("$line")
        done
        if [[ "${line:-}" == e && ${#lines[@]} -eq 0 ]]; then
            python3 - "$version" "$build" "$label" "$tag" <<'PY'
import sys, json, datetime
version, build, label, tag = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
p = "Runlet/WhatsNew.json"; s = open(p).read()
entry = {"version": version, "build": build, "label": label, "date": datetime.date.today().isoformat(),
         "notes": f"https://github.com/filipac/runlet/releases/tag/{tag}", "also": ["TODO: what's new in " + label]}
body = json.dumps(entry, indent=2, ensure_ascii=False).replace("\n", "\n    ")
s = s.replace('"releases": [\n', '"releases": [\n    ' + body + ',\n', 1)
open(p, "w").write(s)
PY
            editor Runlet/WhatsNew.json
        else
            [[ ${#lines[@]} -gt 0 ]] || die "What's New needs at least one line for $label"
            python3 - "$version" "$build" "$label" "$tag" "${lines[@]}" <<'PY'
import sys, json, datetime
version, build, label, tag, *also = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], *sys.argv[5:]
p = "Runlet/WhatsNew.json"; s = open(p).read()
entry = {"version": version, "build": build, "label": label, "date": datetime.date.today().isoformat(),
         "notes": f"https://github.com/filipac/runlet/releases/tag/{tag}", "also": also}
body = json.dumps(entry, indent=2, ensure_ascii=False).replace("\n", "\n    ")
assert '"releases": [\n' in s, "Runlet/WhatsNew.json has no releases list"
s = s.replace('"releases": [\n', '"releases": [\n    ' + body + ',\n', 1)
open(p, "w").write(s)
PY
        fi
        grep -q "TODO: what's new" Runlet/WhatsNew.json && die "replace the TODO line in Runlet/WhatsNew.json, then run this again"
        note "Added $label ($build) to Runlet/WhatsNew.json."
    fi
    ensure_fixtures "$worktree"
    note "Checking What's New…"
    scripts/test.sh fast --filter WhatsNewTests >/dev/null 2>&1 || { scripts/test.sh fast --filter WhatsNewTests | tail -20; die "WhatsNewTests failed: fix Runlet/WhatsNew.json, then run this again"; }

    step "Tests"
    if docker ps -q --filter label=com.docker.compose.project=runlet-fixtures 2>/dev/null | grep -q .; then
        if confirm "Run the full tests (about a minute)?" Y; then
            # The live database tests read their servers from these variables; setup reuses the containers.
            eval "$(scripts/setup-fixtures.sh databases 2>/dev/null | grep -E "^export RUNLET_TEST_[A-Z_]+=")"
            scripts/test.sh full || die "the tests failed"
        fi
    else
        warn "the runlet-fixtures containers aren't running: running the fast tests (scripts/setup-fixtures.sh databases for full)"
        scripts/test.sh fast || die "the tests failed"
    fi

    step "Release PR"
    git add -A project.yml Runlet.xcodeproj/project.pbxproj CHANGELOG.md Runlet/WhatsNew.json changelog.d
    git diff --cached --quiet || git commit -q -m "Release $label: version $version ($build), CHANGELOG, What's New (#$issue)"
    git log -1 --format='  %h %s'
    local pr="${PR:-}"
    load_state "$tag" || true
    pr="${PR:-}"
    if [[ -z "$pr" ]]; then
        outward "push $branch" git push -q -u origin "$branch"
        local pr_body
        pr_body="$(printf 'Closes #%s\n\nRelease Runlet %s (build %s), prepared by `scripts/release.sh`.\n\n- [x] project.yml: %s (%s)%s\n- [x] CHANGELOG\n- [x] What'"'"'s New entry for %s (%s)\n- [x] Tests\n- [ ] After merge: `scripts/release.sh publish %s`' "$issue" "$label" "$build" "$version" "$build" "${prerelease:+, $prerelease}" "$label" "$build" "$tag")"
        if [[ "$DRY_RUN" == 1 ]]; then
            note "[dry run] would open the PR \"Release $label\""
            pr=0
        else
            confirm "Open the PR \"Release $label\"?" Y || die "stopped"
            pr="$(gh pr create --repo "$REPO" --base main --head "$branch" --title "Release $label" --body "$pr_body" | grep -oE '[0-9]+$')"
        fi
        save_state "$tag" "PR=$pr" "BRANCH=$branch"
    fi
    bold "  PR #$pr: https://github.com/$REPO/pull/$pr"
    PREPARED_TAG="$tag"
}

wait_for_merge() { # wait_for_merge <tag>
    load_state "$1" || die "no release in progress for $1"
    [[ "$DRY_RUN" == 1 ]] && { note "[dry run] the PR would be merged now"; return 0; }
    step "Merge"
    note "Review and merge PR #$PR on GitHub. Then press Enter here; type q to stop and run"
    note "scripts/release.sh publish $1 later."
    while true; do
        local state answer
        state="$(gh pr view "$PR" --repo "$REPO" --json state -q .state)"
        [[ "$state" == MERGED ]] && { note "#$PR is merged."; return 0; }
        [[ "$state" == CLOSED ]] && die "#$PR was closed without merging"
        read -r -p "  Waiting for #$PR ($state)… " answer || answer=q
        [[ "$answer" == q ]] && exit 0
    done
}

# ── publish ───────────────────────────────────────────────────────────────────────────────────
publish() { # publish <tag>
    local tag="$1"
    preflight
    load_state "$tag" || die "no release in progress for $tag (run scripts/release.sh prepare first)"
    local commit
    if [[ "$DRY_RUN" == 1 ]]; then
        commit="$(git -C "$ROOT" rev-parse "${BRANCH:-origin/main}")"
        note "[dry run] packaging $commit, the release branch, as if it were merged"
    else
        commit="$(gh pr view "$PR" --repo "$REPO" --json mergeCommit -q .mergeCommit.oid)"
        [[ -n "$commit" ]] || die "#$PR isn't merged yet"
    fi
    local yml
    yml="$(git -C "$ROOT" show "$commit:project.yml")"
    [[ "$(yml_value "$yml" MARKETING_VERSION)" == "$VERSION" && "$(yml_value "$yml" CURRENT_PROJECT_VERSION)" == "$BUILD" ]] \
        || die "$commit doesn't have $VERSION ($BUILD) in project.yml"

    step "Tag and package"
    local worktree="$ROOT/build/release/$tag-publish"
    [[ -d "$worktree" ]] || git -C "$ROOT" worktree add -q --detach "$worktree" "$commit"
    cd "$worktree"
    if [[ "$DRY_RUN" == 1 ]]; then
        note "[dry run] would tag $commit as $tag"
    else
        local remote_tag
        remote_tag="$(git ls-remote --tags origin "refs/tags/$tag^{}" | cut -f 1)"
        [[ -z "$remote_tag" || "$remote_tag" == "$commit" ]] || die "$tag on GitHub points at $remote_tag, not the merge commit $commit"
        if git rev-parse -q --verify "refs/tags/$tag" >/dev/null && [[ "$(git rev-parse "$tag^{}")" != "$commit" ]]; then
            warn "the local $tag (from a dry run?) isn't the merge commit: making it again"
            git tag -d "$tag" >/dev/null
        fi
        git rev-parse -q --verify "refs/tags/$tag" >/dev/null || git tag -a "$tag" -m "Runlet $LABEL" "$commit"
    fi
    ensure_fixtures "$worktree"
    if [[ ! -f dist/self-test.json || ! -d dist/Runlet.app ]] || ! confirm "dist/ has a package already; use it?" Y; then
        note "Building the universal app, signing, self-testing (a few minutes)…"
        mkdir -p build
        scripts/package.sh >build/package.log 2>&1 || { tail -30 build/package.log; die "package.sh failed: build/package.log"; }
    fi
    grep -q '"ok" : false' dist/self-test.json && die "the packaged self-test failed: dist/self-test.json"
    grep -q "update key set" dist/self-test.json || die "the package has no update key"
    local plist="dist/Runlet.app/Contents/Info.plist"
    [[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$plist")" == "$VERSION" \
       && "$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$plist")" == "$BUILD" ]] || die "the package isn't $VERSION ($BUILD)"
    note "$(du -sh dist/Runlet.app | cut -f1) app, self-test passed, update key set."

    step "Files"
    local name="${tag#v}" files=()
    ( cd dist
      [[ -f Runlet.zip ]] && mv Runlet.zip "Runlet-$name.zip"
      [[ -f Runlet.dmg ]] && mv Runlet.dmg "Runlet-$name.dmg"
      [[ -f Runlet-dSYMs.zip ]] && mv Runlet-dSYMs.zip "Runlet-$name-dSYMs.zip"
      true )
    files=("Runlet-$name.zip" "Runlet-$name.dmg")
    if [[ -z "$PRERELEASE" ]]; then
        [[ -f "dist/Runlet-$name-dSYMs.zip" ]] || die "a stable package must have its dSYMs zip (#258)"
        files+=("Runlet-$name-dSYMs.zip")
    fi
    (cd dist && shasum -a 256 "${files[@]}" >SHA256SUMS.txt && sed 's/^/  /' SHA256SUMS.txt)

    step "Release notes"
    local notes="$worktree/build/release-notes.md"
    if [[ ! -f "$notes" ]]; then
        local changes="$worktree/build/what-changed.md"
        rm -f "$changes"
        if use_claude; then
            note "Asking Claude ($MODEL) for the \"What changed\" bullets…"
            local heading="^## $VERSION — "
            [[ -n "$PRERELEASE" ]] && heading="^## Unreleased"
            awk -v h="$heading" '$0 ~ h {f=1;next} f&&/^## /{exit} f' CHANGELOG.md \
                | claude_draft "Below are the CHANGELOG entries of Runlet $LABEL. Write the \"What changed\" list for its GitHub release notes: one bullet per change that matters to users, starting with \"- \" and a short bold name, one or two sentences each, with the issue number in parentheses when the entry has one, like (#257). Put development-only changes last, in one bullet." >"$changes" \
                || { warn "no draft from Claude: the notes list the CHANGELOG headings"; rm -f "$changes"; }
        fi
        WHAT_CHANGED="$changes" python3 - "$VERSION" "$PRERELEASE" "$LABEL" "$name" "$commit" >"$notes" <<'PY'
import sys, re, os
version, prerelease, label, name, commit = sys.argv[1:6]
drafted = os.environ.get("WHAT_CHANGED", "")
drafted = [l for l in open(drafted).read().splitlines() if l.strip()] if drafted and os.path.isfile(drafted) else []
s = open("CHANGELOG.md").read()
def section(heading_re):
    m = re.search(heading_re, s, re.M)
    if not m: return ""
    rest = s[m.end():]
    end = re.search(r"^## ", rest, re.M)
    return rest[:end.start()] if end else rest
def titles(text):
    return [re.sub(r" \(\[#(\d+)\]\([^)]*\)\)$", r" (#\1)", re.sub(r"^### [0-9-]+ — ", "", l)) for l in text.splitlines() if l.startswith("### ")]
if prerelease:
    body = section(r"^## Unreleased\s*$")
    out = [f"**Pre-release for testing.** Built from `main` at {commit[:7]} with the version set to {version} ({label}).", "",
           "Update from an earlier beta with **Runlet ▸ Check for Updates…** (Beta channel), or install the DMG by hand.", "",
           f"## New in {label}", ""]
    out += drafted or [f"- {t}" for t in titles(body)] or ["- (describe the changes)"]
else:
    body = section(rf"^## {re.escape(version)} — .*$")
    summary = body.split("\n### ")[0].strip()
    out = [summary, "", "## Install or update", "",
           "- **With 0.4.0 or later:** use **Runlet ▸ Check for Updates…** and choose **Install and Relaunch**.",
           "- **New install, or 0.3.0 and older:** download the DMG, drag Runlet to Applications, and open it. It's ad-hoc signed, so the first time go to System Settings ▸ Privacy & Security and click **Open Anyway**.",
           "", "Runlet runs on macOS 15 (Sequoia) or later, on Apple silicon and Intel.", "", "## What changed", ""]
    out += drafted or [f"- {t}" for t in titles(body)]
    out += ["", f"The full list is in [CHANGELOG.md](https://github.com/filipac/runlet/blob/v{name}/CHANGELOG.md). `SHA256SUMS.txt` has the checksums.", "",
            f"Crash logs: `Runlet-{name}-dSYMs.zip` has the symbols ([how to use them](https://github.com/filipac/runlet/blob/main/docs/crash-logs.md))."]
print("\n".join(out))
PY
        editor "$notes"
    fi
    sed 's/^/  │ /' "$notes" | head -40

    step "GitHub release"
    local kind_flag="--latest"
    [[ -n "$PRERELEASE" ]] && kind_flag="--prerelease"
    outward "push the tag $tag" git push -q origin "$tag"
    if [[ "$DRY_RUN" == 1 ]] || ! gh release view "$tag" --repo "$REPO" >/dev/null 2>&1; then
        local paths=()
        for file in "${files[@]}" SHA256SUMS.txt; do paths+=("dist/$file"); done
        outward "publish the release Runlet $LABEL ($kind_flag)" gh release create "$tag" --repo "$REPO" "$kind_flag" --title "Runlet $LABEL" --notes-file "$notes" "${paths[@]}"
    else
        note "The $tag release exists already."
    fi
    if [[ "$DRY_RUN" == 0 ]]; then
        local check="$worktree/build/release-download"
        rm -rf "$check" && mkdir -p "$check"
        gh release download "$tag" --repo "$REPO" --dir "$check"
        (cd "$check" && shasum -c SHA256SUMS.txt | sed 's/^/  /') || die "the downloaded files don't match SHA256SUMS.txt"
        cmp -s "$check/Runlet-$name.zip" "dist/Runlet-$name.zip" || die "the downloaded zip isn't the one built here"
        rm -rf "$check"
    fi

    step "Appcast"
    local appcast_dir
    appcast_dir="$(git -C "$ROOT" worktree list --porcelain | awk '/^worktree /{w=$2} /^branch refs\/heads\/appcast$/{print w}')"
    if [[ -z "$appcast_dir" ]]; then
        appcast_dir="$ROOT/build/appcast"
        git -C "$ROOT" worktree add -q "$appcast_dir" appcast 2>/dev/null || git -C "$ROOT" worktree add -q -b appcast "$appcast_dir" origin/appcast
    fi
    git -C "$appcast_dir" pull -q --ff-only origin appcast
    note "$appcast_dir"
    if grep -q "<sparkle:version>$BUILD</sparkle:version>" "$appcast_dir/appcast.xml"; then
        note "The appcast has build $BUILD already."
    elif [[ "$DRY_RUN" == 1 ]]; then
        note "[dry run] would sign and add: scripts/appcast.py add $appcast_dir/appcast.xml dist/Runlet-$name.zip --version $name --build $BUILD … --keychain"
    else
        note "Signing with your update key: allow the Keychain prompt."
        scripts/appcast.py add "$appcast_dir/appcast.xml" "dist/Runlet-$name.zip" --version "$name" --build "$BUILD" \
            --url "https://github.com/$REPO/releases/download/$tag/Runlet-$name.zip" \
            --link "https://github.com/$REPO/releases/tag/$tag" --notes "$notes" --keychain
        scripts/appcast.py verify "$appcast_dir/appcast.xml" --keychain
    fi
    if [[ "$DRY_RUN" == 0 ]] && ! git -C "$appcast_dir" diff --quiet; then
        git -C "$appcast_dir" add appcast.xml
        git -C "$appcast_dir" commit -q -m "Runlet $LABEL"
        outward "push the appcast (installed apps see $LABEL)" git -C "$appcast_dir" push -q origin appcast
        # raw.githubusercontent.com caches each file for up to five minutes, separately for each
        # kind of request (Accept-Encoding), ignores query strings, and caches "not found" too; so
        # polling it can keep seeing the old feed. GitHub's API has no cache in front of it and has
        # the push at once.
        local tries=0
        note "Checking that GitHub has it…"
        until gh api -H "Accept: application/vnd.github.raw" "repos/$REPO/contents/appcast.xml?ref=appcast" 2>/dev/null \
            | grep -q "<sparkle:version>$BUILD</sparkle:version>"; do
            tries=$((tries + 1)); [[ $tries -gt 12 ]] && { warn "GitHub's API doesn't show build $BUILD on the appcast branch yet: check it"; break; }
            sleep 5
        done
        note "Pushed. Installed apps see $LABEL within about five minutes (GitHub caches the branch URL)."
    fi

    step "Done"
    if [[ "$DRY_RUN" == 0 ]]; then
        gh issue comment "$ISSUE" --repo "$REPO" --body "Released: https://github.com/$REPO/releases/tag/$tag. Downloads checked with \`shasum -c\`; appcast item $LABEL ($BUILD) signed and pushed (scripts/release.sh)." >/dev/null || true
        cd "$ROOT"
        if confirm "Remove the release worktrees (build/release/$tag*)?" Y; then
            git worktree remove --force "$worktree"
            [[ -d "$ROOT/build/release/$tag" ]] && git worktree remove --force "$ROOT/build/release/$tag"
            git branch -D "release/$tag" >/dev/null 2>&1 || true
            git push -q origin --delete "release/$tag" >/dev/null 2>&1 || true
            rm -f "$STATE_DIR/$tag"
        fi
    fi
    if [[ "$DRY_RUN" == 1 ]]; then
        note "Dry run finished: dist/ is in $worktree. scripts/release.sh clean $tag removes it all."
        return 0
    fi
    bold "  Runlet $LABEL: https://github.com/$REPO/releases/tag/$tag"
    note "Test it: Runlet ▸ Check for Updates… in an older version offers $LABEL."
}

clean() { # clean <tag>: a release's worktrees, local branch, local tag (unless pushed), and progress
    local tag="$1"
    cd "$ROOT"
    for dir in "$ROOT/build/release/$tag" "$ROOT/build/release/$tag-publish"; do
        [[ -d "$dir" ]] && git worktree remove --force "$dir" && note "removed $dir"
    done
    git branch -D "release/$tag" >/dev/null 2>&1 && note "removed the local branch release/$tag"
    if git rev-parse -q --verify "refs/tags/$tag" >/dev/null && ! git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1; then
        git tag -d "$tag" >/dev/null && note "removed the local tag $tag"
    fi
    rm -f "$STATE_DIR/$tag"
    true
}

# ── main ──────────────────────────────────────────────────────────────────────────────────────
[[ "$DRY_RUN" == 1 ]] && bold "Dry run: nothing is pushed, opened, published, or signed."
case "$COMMAND" in
    prepare) prepare ;;
    publish)
        tag="$ARG_VERSION"
        if [[ -z "$tag" ]]; then
            tag="$(ls -t "$STATE_DIR" 2>/dev/null | head -n 1 || true)"
            [[ -n "$tag" ]] || die "which release? scripts/release.sh publish <tag, e.g. v0.4.4>"
        fi
        [[ "$tag" == v* ]] || tag="v$tag"
        publish "$tag" ;;
    clean)
        [[ -n "$ARG_VERSION" ]] || die "which release? scripts/release.sh clean <tag>"
        tag="$ARG_VERSION"; [[ "$tag" == v* ]] || tag="v$tag"
        clean "$tag" ;;
    "")
        prepare
        wait_for_merge "$PREPARED_TAG"
        publish "$PREPARED_TAG" ;;
esac
