// Markdown rules for the documentation site (#287). They apply to `docs:dev`, `docs:build`, and
// the search index alike, because VitePress renders every page with this markdown-it instance.
import fs from 'node:fs'
import path from 'node:path'

/** Where links to repository files outside the published docs go. */
export const repositoryURL = 'https://github.com/filipac/runlet'

// markdown-it's types aren't a dependency of the docs; these rules need only a few fields.
type Token = {
  type: string
  tag: string
  content: string
  children: Token[] | null
  attrGet(name: string): string | null
  attrSet(name: string, value: string): void
  attrJoin(name: string, value: string): void
}
type State = { tokens: Token[]; env: { relativePath?: string }; Token: new (type: string, tag: string, nesting: number) => Token }
type Rule = (state: State) => void
type MarkdownIt = { core: { ruler: { after(name: string, rule: string, fn: Rule): void; push(rule: string, fn: Rule): void } } }

/**
 * Leaves `## For developers` sections out of the site: from that heading to the next `#` or `##`
 * heading. Source paths, test names, and issue history live there, for readers on GitHub. Pages
 * for which `keep` answers true (the Development category's) keep them.
 */
export function stripDeveloperSections(md: MarkdownIt, keep: (relativePath: string) => boolean) {
  md.core.ruler.after('block', 'runlet-strip-for-developers', (state) => {
    const relativePath = state.env?.relativePath
    if (relativePath && keep(relativePath)) return
    let skipping = false
    const kept: Token[] = []
    state.tokens.forEach((token, index) => {
      if (token.type === 'heading_open' && (token.tag === 'h1' || token.tag === 'h2')) {
        const title = state.tokens[index + 1]?.content.trim() ?? ''
        skipping = token.tag === 'h2' && /^for developers$/i.test(title)
      }
      if (!skipping) kept.push(token)
    })
    state.tokens = kept
  })
}

export interface RepositoryLinkOptions {
  /** The repository's root on disk. */
  repoRoot: string
  /** The docs folder, relative to the root (`docs`). */
  docsDir: string
  /** Published pages, as file names without `.md` (`sql-tabs`, `index`). */
  published: Set<string>
  /** Called for a link to a file that doesn't exist in the repository. */
  onMissing: (page: string, href: string) => void
}

/**
 * Rewrites relative links to files that aren't published pages (source files, `CHANGELOG.md`,
 * the readme, scripts, internal pages, screenshots) to their GitHub URL. Links between published
 * pages stay relative, so VitePress turns them into site links and checks them for dead links.
 * A link to a file that doesn't exist is reported through `onMissing`.
 */
export function repositoryLinks(md: MarkdownIt, options: RepositoryLinkOptions) {
  md.core.ruler.push('runlet-repository-links', (state) => {
    const relativePath = state.env?.relativePath
    if (!relativePath) return
    for (const block of state.tokens) {
      for (const token of block.children ?? []) {
        if (token.type !== 'link_open') continue
        const href = token.attrGet('href')
        const rewritten = href ? repositoryHref(href, relativePath, options) : null
        if (rewritten) token.attrSet('href', rewritten)
      }
    }
  })
}

function repositoryHref(href: string, relativePath: string, options: RepositoryLinkOptions): string | null {
  // External (`https:`, `mailto:`), absolute (`/`), and in-page (`#…`) links stay as they are.
  if (/^[a-z][a-z0-9+.-]*:/i.test(href) || href.startsWith('/') || href.startsWith('#')) return null
  const [, target = '', suffix = ''] = /^([^?#]*)(.*)$/.exec(href) ?? []
  if (!target) return null
  const repoPath = path.posix.normalize(path.posix.join(options.docsDir, path.posix.dirname(relativePath), decodeURI(target)))
  if (repoPath.startsWith('../')) return null
  if (repoPath === '.' || repoPath === './') return `${repositoryURL}${suffix}`
  const docsPrefix = `${options.docsDir}/`
  if (repoPath.startsWith(docsPrefix) && options.published.has(repoPath.slice(docsPrefix.length).replace(/\.(md|html)$/, ''))) {
    return null
  }
  const onDisk = path.join(options.repoRoot, repoPath)
  if (!fs.existsSync(onDisk)) {
    options.onMissing(relativePath, href)
    return null
  }
  const kind = fs.statSync(onDisk).isDirectory() ? 'tree' : 'blob'
  return `${repositoryURL}/${kind}/main/${encodeURI(repoPath.replace(/\/$/, ''))}${suffix}`
}

/**
 * Images for one appearance, written the way GitHub reads them: `![…](shot-light.png#gh-light-mode-only)`
 * and `![…](shot-dark.png#gh-dark-mode-only)`. On the site the fragment becomes a class, and
 * brand.css shows the image that matches the site's appearance.
 */
export function appearanceImages(md: MarkdownIt) {
  md.core.ruler.push('runlet-appearance-images', (state) => {
    for (const block of state.tokens) {
      for (const token of block.children ?? []) {
        if (token.type !== 'image') continue
        const src = token.attrGet('src') ?? ''
        const appearance = /#gh-(light|dark)-mode-only$/.exec(src)?.[1]
        if (!appearance) continue
        token.attrSet('src', src.replace(/#gh-(light|dark)-mode-only$/, ''))
        token.attrJoin('class', `${appearance}-only`)
      }
    }
  })
}

// HTML elements a page may use on purpose. Anything else that looks like a tag is a placeholder
// such as <host> or <name>, which Vue would reject as an unclosed element.
const htmlElements = new Set(
  ('a abbr b blockquote br caption cite code col colgroup dd del details dfn div dl dt em figcaption figure ' +
    'h1 h2 h3 h4 h5 h6 hr i img input ins kbd li mark ol p picture pre q s samp small source span strong sub ' +
    'summary sup table tbody td tfoot th thead time tr u ul var video wbr').split(' '),
)

function isPlaceholderTag(html: string): boolean {
  const name = /^<\/?([A-Za-z][\w.-]*)/.exec(html.trim())?.[1]
  return name !== undefined && !htmlElements.has(name.toLowerCase())
}

/** Shows placeholders written like tags (`<host>`, `<name>`) as text instead of HTML. */
export function placeholdersAsText(md: MarkdownIt) {
  md.core.ruler.push('runlet-placeholders-as-text', (state) => {
    const tokens: Token[] = []
    for (const token of state.tokens) {
      if (token.type === 'html_block' && isPlaceholderTag(token.content)) {
        const text = new state.Token('text', '', 0)
        text.content = token.content.trim()
        const inline = new state.Token('inline', '', 0)
        inline.content = text.content
        inline.children = [text]
        tokens.push(new state.Token('paragraph_open', 'p', 1), inline, new state.Token('paragraph_close', 'p', -1))
        continue
      }
      for (const child of token.children ?? []) {
        if (child.type === 'html_inline' && isPlaceholderTag(child.content)) child.type = 'text'
      }
      tokens.push(token)
    }
    state.tokens = tokens
  })
}

/**
 * Heading anchors as GitHub makes them (lowercase, punctuation removed, spaces to hyphens), so a
 * link such as `drivers.md#the-applications-environment` works on GitHub and on the site alike.
 */
export function githubSlug(text: string): string {
  return text
    .trim()
    .toLowerCase()
    .replace(/[^\p{L}\p{M}\p{N}\p{Pc}\- ]/gu, '')
    .replace(/ /g, '-')
}
