---
outline: 2
search: false
---

# Release Notes

What changed in each Runlet release, newest first. Runlet tells you about a new version itself and shows its notes before you install it: see [Updating Runlet](installation.md#updating-runlet).

These notes come from the [changelog](../CHANGELOG.md), which also lists the changes that are merged but not released yet, under **Unreleased**.

<!-- release-notes:start -->
<!--@include: ../CHANGELOG.md-->
<!-- release-notes:end -->

## For developers

This page is generated when the site is built ([#291](https://github.com/filipac/runlet/issues/291)). On GitHub it shows only this text; the notes are in [CHANGELOG.md](../CHANGELOG.md).

- **What's included:** every `## <version> — <date>` section of `CHANGELOG.md` (`## 0.5.0 — 2026-10-05`, a pre-release such as `0.6.0-beta.1` too), with its summary and its `###` entries, in the changelog's order. `## Unreleased` and the file's introduction are left out. Each version gets the anchor `#v0-5-0`, its date, and a link to its GitHub release (`v0.5.0`).
- **How:** the page includes the changelog between the `release-notes:start` and `release-notes:end` markers, with VitePress's `@include` comment for `../CHANGELOG.md`. A markdown-it rule (`releaseNotes()` in [`docs/.vitepress/releaseNotes.ts`](.vitepress/releaseNotes.ts), registered in `config.mts`) replaces that text with the release notes before the page is parsed, so the build, `docs:dev` (which reloads the page when the changelog changes), and the search index all use it.
- **Links:** the changelog's links are relative to the repository's root. Links to published pages become page links (`docs/tabs.md` → `tabs.md`), other files become GitHub links, and a link to a file that no longer exists keeps only its text, because the changelog is history and isn't rewritten. Code spans and fenced code are left alone.
- **Search and outline:** the page is left out of the search index (`search: false`), so searching finds the feature's own page first, and its outline lists only the versions (`outline: 2`).
- **The top bar's Changelog** entry opens this page.
- **When it's published:** the Website workflow (`pages.yml`) deploys the site on a merge to `main` that changes `CHANGELOG.md`, so a release's pull request republishes it. The Docs workflow (`docs.yml`) builds it on pull requests that change `CHANGELOG.md` too.
- **The Changelog workflow's own commit doesn't deploy:** it moves `changelog.d/` fragments into Unreleased and pushes with `GITHUB_TOKEN`, and GitHub doesn't start other workflows from pushes made with that token. That doesn't matter here, since Unreleased isn't on this page: the next release's merge republishes it.
