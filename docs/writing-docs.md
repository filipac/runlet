# Writing Docs

Runlet's documentation at [runletapp.dev/docs](https://runletapp.dev/docs/) is built from the Markdown pages in `docs/`, and nowhere else. When a [pull request](contributing.md) changes something users notice, it updates that feature's page in the same pull request, and a new page goes into the navigation. A pull request that only changes documentation (`docs/`, the docs site, or the readme) adds no [changelog entry](changelog.md#when-a-pull-request-needs-an-entry). This page is the style guide, modelled on [Laravel's documentation](https://laravel.com/docs).

## The Voice

Write for someone who has Runlet open and wants to get something done.

- **Start with a short introduction:** one to three sentences that say what the feature is and why you'd use it. Then get to the point.
- **Use sections a reader can scan.** A `##` section covers one task or topic; `###` sections hold its details. Headings use title case: "Running a Script", "Saved Connections".
- **Talk to the reader, in the present tense:** "Press <kbd>⌘</kbd><kbd>R</kbd> to run the tab." Not "The user can run…", and not "will run".
- **Keep sentences short and active.** One idea per sentence; lists and tables for anything with three or more parts.
- **Name the UI as it appears,** in bold: **File ▸ New SQL Tab**, **Settings ▸ General ▸ Tabs**, the **Run All** button. Menu paths use ▸.
- **Show, don't describe.** A three-line PHP snippet, SQL statement, or `runlet` command often says more than a paragraph.
- **Keep the user text free of internals:** no issue numbers, source paths, type names, test names, or implementation history. They go under [`## For developers`](#for-developers-sections).
- **Don't invent features.** Check what you write against the app, and say what doesn't work yet.

### Before and After

Before, written for maintainers:

> Pinned tabs ([#279](https://github.com/filipac/runlet/issues/279)): `TabPinOrder` keeps pinned tabs first; Close Tab on a pinned tab goes through `TabPinning.asksBeforeClosing(pinned:request:)`, which shows the *Close pinned tab?* sheet (`AppModel.closeTabForCommandW`).

After, written for users:

> Pinned tabs are hard to close by accident. Pressing <kbd>⌘</kbd><kbd>W</kbd> on a pinned tab asks first: **Close** (<kbd>Return</kbd>) closes it, and **Cancel** (<kbd>Esc</kbd>) keeps it.

The source paths and the issue number from "before" move to the page's `## For developers` section, so nothing is lost.

### Formatting

| What | How |
| --- | --- |
| Keyboard shortcuts | One `<kbd>` per key: `<kbd>⇧</kbd><kbd>⌘</kbd><kbd>R</kbd>`. Use the symbols ⌘ ⌥ ⌃ ⇧, and the names Return, Esc, Tab, and Space. |
| Code | Fenced blocks with a language: `php`, `sql`, `sh`, `json`. Keep examples small and realistic. |
| Placeholders | In code: `` `runlet -t <target>` ``. Outside code, GitHub hides `<host>`, so write it in backticks. |
| Notes and warnings | GitHub's callouts, which also render on GitHub: `> [!NOTE]`, `> [!TIP]`, `> [!WARNING]` (and `> [!IMPORTANT]`, `> [!CAUTION]`). Use them sparingly: a note for something easy to miss, a tip for a shortcut or a better way, and a warning for data loss, production, or security. |
| Options and reference | Tables, with the name in bold or code in the first column. |
| Links between pages | Relative links to the Markdown file: `[bound parameters](sql-tabs.md#bound-parameters)`. They work on GitHub, and the site turns them into its own links. |
| Links to repository files | Relative links too: `[CHANGELOG](../CHANGELOG.md)`, `` [`scripts/test.sh`](../scripts/test.sh) ``. On the site they become GitHub links. |
| Screenshots | A light and dark pair taken by the screenshot script, in `docs/screenshots/<page>/`. See [Screenshots](#screenshots). Where a screenshot would help but can't be taken yet, leave a marker: `<!-- screenshot: what it should show -->`. |

A callout looks like this:

```markdown
> [!WARNING]
> Explain Analyze runs the statement. On MySQL, a write it runs can't be undone.
```

## For Developers Sections

A page's `## For developers` section holds what a contributor needs and a user doesn't: source files and types, tests, debug steps, scripts, issue history, and design decisions. It is the last section of the page.

- **On GitHub,** the whole page shows, including this section.
- **On the site,** the section is left out, from its heading to the next `#` or `##` heading, in the page, its outline, and the search index.
- **Development pages** (this category) keep their `## For developers` sections on the site: everything on them is for developers.

When you rewrite a page, move developer detail here instead of deleting it.

## Adding a Page

1. **Prefer an existing page.** Add a section when the feature belongs to one; make a new page when it's a feature of its own that a reader would look for in the sidebar.
2. **Create `docs/<name>.md`** with a `# Title` and a short introduction. Use a lowercase, hyphenated file name, and keep it: other pages, the readme, the website, and the app link to file names.
3. **Add it to the navigation** in [`docs/.vitepress/navigation.ts`](.vitepress/navigation.ts): an entry `{ text: 'Sidebar Label', page: '<name>' }` in the right category, in reading order. A page that maintainers need but users shouldn't see goes into `internalPages` instead.

The build fails when a page in `docs/` is in neither list, when a link between pages is broken, or when a link points at a repository file that doesn't exist.

## Screenshots

A screenshot belongs on a page when it makes a feature quicker to understand: a panel, a sheet, a card, or a result that takes a paragraph to describe. It isn't decoration, and a page doesn't need one per section. A picture of a table of settings or of a code block you already show adds nothing.

### Light and Dark Pairs

Every screenshot is a pair, one for each appearance, and GitHub and the site both show the one that matches the reader's:

```markdown
![The Queries section after a run, with the statements, their times, and an N+1 hint](screenshots/run-inspector/queries-light.webp#gh-light-mode-only)
![The Queries section after a run, with the statements, their times, and an N+1 hint](screenshots/run-inspector/queries-dark.webp#gh-dark-mode-only)
```

- **Files.** The pair is `docs/screenshots/<page>/<name>-light.webp` and `<name>-dark.webp`, where `<page>` is the page the shot was taken for. Link it relative to the page, as above.
- **Both lines,** one after the other, with the same alt text.
- **Alt text** says what the picture shows, for a reader who can't see it: the part of the window and its state ("The History pane with All Projects selected…"), not "Screenshot of…".
- **One picture in two places,** such as the Queries section on [Quickstart](quickstart.md) and [Run Inspector](run-inspector.md), is one pair that both pages link.
- **Only from the script.** The script writes WebP files at most 1,600 pixels wide, around 20 to 110 KB each, from scratch data. Don't add screenshots taken by hand: they can't be taken again when the UI changes, and they may show your own names, paths, hosts, or containers.

`npm run docs:build` fails when a page links an image that doesn't exist.

### Zoom

On the site, a click on an image, a tap, or <kbd>Return</kbd> on a focused image opens it in a lightbox over the page; a click, <kbd>Esc</kbd>, or scrolling closes it. Of a pair, only the visible image can be focused or zoomed. <kbd>⌘</kbd>-click opens the file in a new tab, and so does a click when JavaScript is off: every image is a link to its file. An image that is already inside a link keeps that link and doesn't zoom.

### The Screenshot Script

`scripts/docs-screenshots.py` takes every screenshot again from a Debug build, so after a UI change you run it and commit the new files. Each shot runs in a hidden copy of Runlet with its own scratch data (a sandbox seeded with Alice, Bob, and Carol Example, and example.com addresses); it never reads your settings, Keychain, or `~/.ssh`, and connects to no server but the [test fixtures](#shots-that-need-fixtures).

```sh
scripts/docs-screenshots.py --list                      # every shot: id, what it needs, and whether its pair exists
scripts/docs-screenshots.py                             # all of them
scripts/docs-screenshots.py run-inspector/queries logs  # by id, by page, or by name
scripts/docs-screenshots.py --app build/DerivedData/Build/Products/Debug/Runlet.app --jobs 6 sql-explain
```

| Option | What it does |
| --- | --- |
| `--list` | Lists the shots and marks the ones whose pair is `missing`. |
| `--app <path>` | Uses a Runlet.app you built (Debug, with the `dev.runlet.Runlet.prshots` bundle id, as in [Checking the App](testing.md#checking-the-app)) instead of building one. |
| `--jobs <n>` | How many shots run at once, each in its own copy of Runlet. The default is half the CPUs, at most 6; `--jobs 1` takes them one at a time. A failed shot is retried once, alone. |
| `--keep` | Keeps the raw PNGs and the scratch data in `build/docs-shots/`. |

It needs Xcode, PHP, `cwebp` (`brew install webp`), and the sandbox (`scripts/build-sandbox.sh`); the Redis, MongoDB, PostgreSQL, Docker, and SSH shots need [fixtures](#shots-that-need-fixtures) too. Shots are drawn at 2x, so a Retina screen must be connected: the script moves each hidden window there before it takes the picture, and a shot fails, saying why, when its window isn't at its size on a Retina screen. Look at every image before you commit it.

### Shots That Need Fixtures

Shots of Redis, MongoDB, PostgreSQL, Docker targets, and SSH hosts use the `runlet-fixtures` containers that the tests use ([Setting Up the Fixtures](testing.md#setting-up-the-fixtures)), and nothing else. `--list` shows what each shot needs:

| Needs | Fixture | Start it with | Shots |
| --- | --- | --- | --- |
| `redis` | The Redis container | `scripts/setup-fixtures.sh databases` | `redis/…` |
| `mongo` | The MongoDB container | `scripts/setup-fixtures.sh databases` | `mongodb/…` |
| `postgres` | The PostgreSQL container | `scripts/setup-fixtures.sh databases` | `connections/postgres-editor`, `connections/connection-manager` |
| `ssh` | The SSH host on `127.0.0.1:2222` | `scripts/setup-fixtures.sh docker` | `connections/connection-manager`, `targets/targets` |
| `docker` | The `laravel` container | `scripts/setup-fixtures.sh docker` | `targets/targets` |
| `profiler` | The `profiler` container, a PHP with Excimer | `docker compose -p runlet-fixtures -f Tests/Fixtures/docker/compose.yml up -d profiler` | `benchmarks/profile-run` |

- **Checks.** Before it starts, the script finds each fixture's container, and its port on `127.0.0.1`, through the fixtures-only Docker CLI (`Tests/Fixtures/docker/fixtures-only-docker`). When one isn't running, it skips the shots that need it and says how to start it.
- **Data.** The script seeds Redis database 11 and the MongoDB database `docs_shop` with example customers and orders, and empties them when it ends. Steps save the connections with the fixtures' throwaway password, which stays in the hidden copy's memory.
- **SSH.** A throwaway key in `build/docs-shots/ssh` goes into the fixture's `authorized_keys2` for the run, and an ssh config sends `app.example.com` and `shop.example.com` to the fixture, so pictures show example.com names. The connections the shots open are closed afterwards.
- **Docker.** Docker profiles name a fixture's Compose service, and the hidden copy runs `docker` through the fixtures-only CLI, so it never lists your own containers.

A few shots need no fixture, and no real data either:

- **Import from TablePlus** reads a made-up export (`Tests/Fixtures/tableplus`, copied into the shot's data, through `RUNLET_TABLEPLUS_DIR`), and shows TablePlus's usual path for it (`RUNLET_DEBUG_TABLEPLUS_PATH`).
- **The AI client approval sheet** comes from a made-up client inside the app (the `mcp-ask` step), with no `runlet mcp` process, and is never answered.
- **"Notifications are off"** is what Debug builds report when a step tells them to (`notifications:denied`); macOS isn't asked, and its settings don't change.
- **A local project's folder** on a tab card reads `~/projects/shop`: `RUNLET_DEBUG_HOME` points `~` at the shot's data folder.

### Adding a Shot

1. **Add it to `SHOTS`** in `scripts/docs-screenshots.py`: the page, a name, the tabs it opens with, and the `RUNLET_DEBUG_STEPS` that lead to the picture ([Checking the App](testing.md#checking-the-app) lists where the steps are). Optional fields set the window size (`frame`), settings, history, snippets, targets, files (`seed`), another window to draw (`window`), and a crop. Use neutral data only.
2. **Take it:** `scripts/docs-screenshots.py <page>/<name>`.
3. **Look at both files,** then link the pair from the page.

A shot that needs more than the sandbox names its fixtures in `needs`, joined by `+` (`ssh+postgres`). Each fixture has a check in `NEEDS`, and seeding and cleaning up in `PREPARE` when it has data; steps reach its port as `{redis-port}`, `{mongo-port}`, or `{pg-port}`. Point profiles and connections only at the fixtures, with example.com names, as the existing shots do.

### Window Managers

The script's windows are invisible, but a tiling window manager still sees them. [AeroSpace](https://github.com/nikitabobko/AeroSpace) tiles and resizes them, and keeps them on its workspace's display, so shots fail. The script warns when AeroSpace tiles them; add this rule to `~/.aerospace.toml`, with a workspace on a Retina display, and run `aerospace reload-config`:

```toml
[[on-window-detected]]
if.app-id = "dev.runlet.Runlet.prshots"
run = ['layout floating', 'move-node-to-workspace 1']
```

## Previewing Locally

Node is needed only to preview the docs. From the repository root:

```sh
npm ci
npm run docs:dev
```

`docs:dev` serves the site at `http://localhost:5173/docs/` and reloads as you edit. Run `npm run docs:build` before you push: it runs every check, and `npm run docs:preview` serves the result. To see the docs next to the landing page, as they're published, assemble the site into a folder and serve it:

```sh
npm run docs:build
scripts/assemble-site.sh build/site
python3 -m http.server --directory build/site --bind 127.0.0.1 8000
```

Then open `http://127.0.0.1:8000/docs/`.

## Publishing

GitHub Actions builds the site; nothing built is ever committed.

- **On a pull request** that changes `docs/`, `website/`, or the docs' configuration, the **Docs** workflow builds the site with every check and uploads it as the `docs-site` artifact. To look at it, unpack it, run `python3 -m http.server` in that folder, and open `/docs/`. (Reloading a page there needs its `.html`; GitHub Pages adds that itself.)
- **On a merge to `main`** that changes them, the **Website** workflow builds the landing page (`website/`, at `/`) and the docs (at `/docs/`) into one GitHub Pages deployment.

## For developers

Screenshots, zoom, and the screenshot script were added in [#295](https://github.com/filipac/runlet/issues/295); the fixture-backed shots (Redis, MongoDB, PostgreSQL, the Connection Manager, Docker and SSH targets) are [#304](https://github.com/filipac/runlet/issues/304). The site was added in [#287](https://github.com/filipac/runlet/issues/287); the pages' rewrite in this voice is [#288](https://github.com/filipac/runlet/issues/288), [#289](https://github.com/filipac/runlet/issues/289), [#290](https://github.com/filipac/runlet/issues/290), [#291](https://github.com/filipac/runlet/issues/291), and [#293](https://github.com/filipac/runlet/issues/293) for this category.

| Piece | Where |
| --- | --- |
| VitePress (pinned), its scripts | `package.json` and `package-lock.json` at the repository root |
| The site's configuration: base `/docs/`, clean URLs, search, the top bar, `srcExclude` for internal pages | `docs/.vitepress/config.mts` |
| The navigation manifest, internal pages, and the Development category | `docs/.vitepress/navigation.ts` |
| Markdown rules: stripping `## For developers`, rewriting repository links (and reporting missing files), `#gh-*-mode-only` images, placeholders such as `<host>` shown as text, and heading anchors made the way GitHub makes them, so `page.md#anchor` links work in both places | `docs/.vitepress/markdown.ts` |
| Click-to-zoom: each image rendered as a link to its file (`zoomableImages`, and `zoomLinksToAssets` in `transformHtml` for the built file's name), and medium-zoom (pinned) in the theme | `docs/.vitepress/markdown.ts`, `docs/.vitepress/config.mts`, `docs/.vitepress/theme/index.ts`, `brand.css` |
| The screenshot script, its manifest (`SHOTS`), and the fixtures a shot can need (`NEEDS`) | `scripts/docs-screenshots.py` ([#295](https://github.com/filipac/runlet/issues/295)) |
| The unclassified-page check (fails `docs:build`, warns in `docs:dev`), and the landing page's logo and favicons served at `/docs/brand/` | `docs/.vitepress/checks.ts` |
| Theme: system fonts, the landing page's colours, `<kbd>` | `docs/.vitepress/theme/` |
| Pull request build and artifact | `.github/workflows/docs.yml` |
| The published layout: `website/` at `/`, the docs at `/docs/`, the docs' 404 page at the root | `scripts/assemble-site.sh` |
| Deployment of the landing page and the docs | `.github/workflows/pages.yml` |

- The Changelog workflow's own commit to `main` doesn't start other workflows, so a page generated from `CHANGELOG.md` would update with the next deployment, not with that commit.
- `npm audit` reports advisories for the Vite and esbuild development servers in VitePress 1.6.4. They concern `docs:dev` only, which listens on localhost; the published site is static files.
