// Release Notes (#291): docs/release-notes.md is generated at build time from CHANGELOG.md's
// version sections (`## 0.5.0 — 2026-10-05`, their summaries, and their entries; never
// `## Unreleased`).
//
// The page includes the changelog between two markers with VitePress's own
// `<!--@include: ../CHANGELOG.md-->`. That makes `docs:dev` reload the page when the changelog
// changes, and the search index and the build see the same text. The markdown-it rule below
// then replaces everything between the markers with the release notes, before the page is
// parsed, so headings, links, and the dead-link check work as on any other page.
import fs from 'node:fs'
import path from 'node:path'

/** The page that shows the release notes, relative to docs/. */
export const releaseNotesPage = 'release-notes.md'
export const startMarker = '<!-- release-notes:start -->'
export const endMarker = '<!-- release-notes:end -->'

const repositoryURL = 'https://github.com/filipac/runlet'

/** A released version's heading: `## 0.5.0 — 2026-10-05` (a pre-release such as `0.6.0-beta.1` too). */
const versionHeading = /^## (\d+\.\d+\.\d+(?:-[0-9A-Za-z.]+)?) — (\d{4}-\d{2}-\d{2})\s*$/

export interface Release {
  version: string
  /** ISO date, as the changelog writes it. */
  date: string
  /** The section's Markdown under its heading: the summary, then the entries. */
  body: string
}

/** The released versions in CHANGELOG.md, newest first, as the changelog orders them. */
export function parseReleases(changelog: string): Release[] {
  const releases: Release[] = []
  let current: Release | null = null
  let lines: string[] = []
  let fence: string | null = null
  const close = () => {
    if (current) releases.push({ ...current, body: lines.join('\n').trim() })
    current = null
    lines = []
  }
  for (const line of changelog.replace(/\r\n?/g, '\n').split('\n')) {
    const fenceMatch = /^\s*(`{3,}|~{3,})/.exec(line)
    if (fenceMatch) {
      if (fence === null) fence = fenceMatch[1][0]
      else if (fenceMatch[1][0] === fence) fence = null
    }
    if (fence === null && /^#{1,2} /.test(line)) {
      close()
      const match = versionHeading.exec(line)
      if (match) current = { version: match[1], date: match[2], body: '' }
      continue
    }
    if (current) lines.push(line)
  }
  close()
  return releases
}

export interface LinkContext {
  /** The repository's root on disk. */
  repoRoot: string
  /** Published pages, as file names without `.md` (`sql-tabs`). */
  published: Set<string>
}

/**
 * The changelog's links are relative to the repository's root (`docs/tabs.md`,
 * `scripts/release.sh`); the page is in docs/. Links to published pages become page links
 * (`tabs.md#pinned-tabs`), other files `../<path>`, which the site turns into GitHub links. A
 * link to a file that is gone keeps its text: the changelog is history and isn't rewritten.
 * Code spans and fenced code are left alone.
 */
export function rebaseLinks(markdown: string, context: LinkContext): string {
  // Paragraphs between fenced code blocks; a link's label may span lines.
  const pieces: { code: boolean; lines: string[] }[] = []
  let fence: string | null = null
  for (const line of markdown.split('\n')) {
    const fenceMatch = /^\s*(`{3,}|~{3,})/.exec(line)
    const opens = fenceMatch !== null && fence === null
    if (opens) fence = fenceMatch[1][0]
    const code = fence !== null
    if (fenceMatch && !opens && fenceMatch[1][0] === fence) fence = null
    const last = pieces[pieces.length - 1]
    if (last && last.code === code && !opens) last.lines.push(line)
    else pieces.push({ code, lines: [line] })
  }
  return pieces.map((piece) => (piece.code ? piece.lines.join('\n') : rebaseLinksInText(piece.lines.join('\n'), context))).join('\n')
}

function rebaseLinksInText(text: string, context: LinkContext): string {
  // Code spans (never across a blank line) stand aside while links are rewritten.
  const spans: string[] = []
  const masked = text.replace(/(`+)(?:(?!\n[ \t]*\n)[\s\S])*?\1/g, (span) => `\u0000${spans.push(span) - 1}\u0000`)
  const rebased = masked.replace(/(!?)\[((?:[^\[\]]|\[[^\[\]]*\])*)\]\(([^()\s]+)\)/g, (whole, bang: string, label: string, href: string) => {
    if (/^[a-z][a-z0-9+.-]*:/i.test(href) || href.startsWith('#') || href.startsWith('/')) return whole
    const [, target = '', suffix = ''] = /^([^?#]*)(.*)$/.exec(href) ?? []
    const repoPath = path.posix.normalize(decodeURI(target))
    if (!target || repoPath.startsWith('../')) return whole
    const page = /^docs\/([^/]+)\.md$/.exec(repoPath)?.[1]
    if (page && context.published.has(page) && !bang) return `[${label}](${page}.md${suffix})`
    if (!fs.existsSync(path.join(context.repoRoot, repoPath))) return bang ? '' : label
    return `${bang}[${label}](../${encodeURI(repoPath)}${suffix})`
  })
  return rebased.replace(/\u0000(\d+)\u0000/g, (_, index: string) => spans[Number(index)])
}

/** `2026-10-05` as `October 5, 2026`. */
export function formatDate(iso: string): string {
  const date = new Date(`${iso}T00:00:00Z`)
  if (Number.isNaN(date.getTime())) return iso
  return date.toLocaleDateString('en-US', { year: 'numeric', month: 'long', day: 'numeric', timeZone: 'UTC' })
}

/** The release notes as Markdown: one `##` section per version, newest first. */
export function releaseNotesMarkdown(changelog: string, context: LinkContext): string {
  const releases = parseReleases(changelog)
  if (releases.length === 0) {
    throw new Error('Release Notes: CHANGELOG.md has no version sections ("## 0.5.0 — 2026-10-05").')
  }
  return releases
    .map((release) => {
      const id = `v${release.version.replace(/[^0-9A-Za-z]+/g, '-')}`
      const tag = `${repositoryURL}/releases/tag/v${release.version}`
      return [
        `## ${release.version} {#${id}}`,
        '',
        `Released ${formatDate(release.date)} · [Download](${tag})`,
        '',
        rebaseLinks(release.body, context),
      ].join('\n')
    })
    .join('\n\n')
}

// markdown-it's types aren't a dependency of the docs; this rule needs only a few fields.
type State = { src: string; env: { relativePath?: string } }
type MarkdownIt = { core: { ruler: { before(name: string, rule: string, fn: (state: State) => void): void } } }

/**
 * Replaces the changelog the release notes page includes between its markers with the release
 * notes. It runs before markdown-it reads the page, for the build, `docs:dev`, and the search
 * index alike.
 */
export function releaseNotes(md: MarkdownIt, context: LinkContext) {
  md.core.ruler.before('normalize', 'runlet-release-notes', (state) => {
    if (state.env?.relativePath !== releaseNotesPage) return
    const start = state.src.indexOf(startMarker)
    const end = state.src.indexOf(endMarker, start + startMarker.length)
    if (start === -1 || end === -1) {
      throw new Error(`docs/${releaseNotesPage} needs the ${startMarker} and ${endMarker} markers around its include of CHANGELOG.md.`)
    }
    const included = state.src.slice(start + startMarker.length, end)
    if (/<!--\s*@include:/.test(included)) {
      throw new Error(`docs/${releaseNotesPage}: the include of CHANGELOG.md between its markers wasn't resolved.`)
    }
    // `v-pre`: the changelog's text is never read as Vue template syntax (`{{ … }}`).
    const notes = `::: v-pre\n\n${releaseNotesMarkdown(included, context)}\n\n:::\n\n`
    state.src = state.src.slice(0, start) + notes + state.src.slice(end + endMarker.length)
  })
}
