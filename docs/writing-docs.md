# Writing Docs

Runlet's documentation at [runletapp.dev/docs](https://runletapp.dev/docs/) is built from the Markdown pages in `docs/`, and nowhere else. When a pull request changes something users notice, it updates that feature's page in the same pull request, and a new page goes into the navigation. This page is the style guide, modelled on [Laravel's documentation](https://laravel.com/docs).

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
| Screenshots | In `docs/screenshots/`, taken with scratch data so they hold no names, paths, hosts, or containers. For a light and a dark version, add `#gh-light-mode-only` and `#gh-dark-mode-only` to the image links; GitHub and the site both show the one that matches the reader's appearance. |

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

## Previewing Locally

Node is needed only to preview the docs. From the repository root:

```sh
npm ci
npm run docs:dev
```

`docs:dev` serves the site at `http://localhost:5173/docs/` and reloads as you edit. Run `npm run docs:build` before you push: it runs every check, and `npm run docs:preview` serves the result.

## Publishing

GitHub Actions builds the site; nothing built is ever committed.

- **On a pull request** that changes `docs/`, `website/`, or the docs' configuration, the **Docs** workflow builds the site with every check and uploads it as the `docs-site` artifact. To look at it, unpack it, run `python3 -m http.server` in that folder, and open `/docs/`. (Reloading a page there needs its `.html`; GitHub Pages adds that itself.)
- **On a merge to `main`** that changes them, the **Website** workflow builds the landing page (`website/`, at `/`) and the docs (at `/docs/`) into one GitHub Pages deployment.

## For developers

The site was added in [#287](https://github.com/filipac/runlet/issues/287); the pages' rewrite in this voice is [#288](https://github.com/filipac/runlet/issues/288), [#289](https://github.com/filipac/runlet/issues/289), [#290](https://github.com/filipac/runlet/issues/290), [#291](https://github.com/filipac/runlet/issues/291), and [#293](https://github.com/filipac/runlet/issues/293) for this category.

| Piece | Where |
| --- | --- |
| VitePress (pinned), its scripts | `package.json` and `package-lock.json` at the repository root |
| The site's configuration: base `/docs/`, clean URLs, search, the top bar, `srcExclude` for internal pages | `docs/.vitepress/config.mts` |
| The navigation manifest, internal pages, and the Development category | `docs/.vitepress/navigation.ts` |
| Markdown rules: stripping `## For developers`, rewriting repository links (and reporting missing files), `#gh-*-mode-only` images, placeholders such as `<host>` shown as text, and heading anchors made the way GitHub makes them, so `page.md#anchor` links work in both places | `docs/.vitepress/markdown.ts` |
| The unclassified-page check (fails `docs:build`, warns in `docs:dev`), and the landing page's logo and favicons served at `/docs/brand/` | `docs/.vitepress/checks.ts` |
| Theme: system fonts, the landing page's colours, `<kbd>` | `docs/.vitepress/theme/` |
| Pull request build and artifact | `.github/workflows/docs.yml` |
| The published layout: `website/` at `/`, the docs at `/docs/`, the docs' 404 page at the root | `scripts/assemble-site.sh` |
| Deployment of the landing page and the docs | `.github/workflows/pages.yml` |

- The Changelog workflow's own commit to `main` doesn't start other workflows, so a page generated from `CHANGELOG.md` would update with the next deployment, not with that commit.
- `npm audit` reports advisories for the Vite and esbuild development servers in VitePress 1.6.4. They concern `docs:dev` only, which listens on localhost; the published site is static files.
