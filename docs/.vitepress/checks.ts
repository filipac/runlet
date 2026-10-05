// The docs build's own checks and brand images (#287), as a Vite plugin.
import fs from 'node:fs'
import path from 'node:path'
import type { Plugin } from 'vite'

/** Every Markdown page in `docsDir` and its folders, as a path without `.md` (`sql-tabs`). */
export function markdownPages(docsDir: string): string[] {
  const pages: string[] = []
  const walk = (dir: string) => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      if (entry.name.startsWith('.') || entry.name === 'node_modules' || entry.name === 'public') continue
      const full = path.join(dir, entry.name)
      if (entry.isDirectory()) walk(full)
      else if (entry.name.endsWith('.md')) pages.push(path.relative(docsDir, full).split(path.sep).join('/').replace(/\.md$/, ''))
    }
  }
  walk(docsDir)
  return pages.sort()
}

/**
 * What is wrong with the navigation manifest: pages in neither the navigation nor the internal
 * list, pages listed twice or in both, and listed pages that don't exist.
 */
export function classificationProblems(docsDir: string, published: string[], internal: string[]): string[] {
  const problems: string[] = []
  const onDisk = new Set(markdownPages(docsDir))
  const listed = [...published, ...internal]
  for (const page of onDisk) {
    if (!listed.includes(page)) {
      problems.push(`docs/${page}.md is in neither the navigation nor the internal pages. Add it to docs/.vitepress/navigation.ts (see docs/writing-docs.md).`)
    }
  }
  for (const page of new Set(listed)) {
    if (!onDisk.has(page)) problems.push(`docs/.vitepress/navigation.ts lists ${page}, but docs/${page}.md doesn't exist.`)
    if (listed.filter((other) => other === page).length > 1) problems.push(`docs/.vitepress/navigation.ts lists ${page} more than once.`)
  }
  return problems
}

export interface DocsPluginOptions {
  docsDir: string
  published: string[]
  internal: string[]
  /** The landing page's images served at `<base>brand/<name>`: logo and favicons. */
  brandDir: string
  brandFiles: string[]
}

/**
 * - Fails `docs:build` when a page isn't classified, and warns in `docs:dev`.
 * - Serves the landing page's logo and favicons at `<base>brand/` in `docs:dev` and writes them
 *   into the build, so the docs share them with website/ without a second copy in Git.
 */
export function runletDocs(options: DocsPluginOptions): Plugin {
  let command: 'build' | 'serve' = 'serve'
  let base = '/'
  let ssr = false
  return {
    name: 'runlet-docs',
    configResolved(config) {
      command = config.command
      base = config.base
      ssr = Boolean(config.build.ssr)
    },
    buildStart() {
      const problems = classificationProblems(options.docsDir, options.published, options.internal)
      if (problems.length === 0) return
      const message = `Unclassified documentation pages:\n  ${problems.join('\n  ')}`
      if (command === 'build') this.error(message)
      else this.warn(message)
    },
    configureServer(server) {
      server.middlewares.use((request, response, next) => {
        const prefix = `${base}brand/`
        const name = request.url?.startsWith(prefix) ? decodeURIComponent(request.url.slice(prefix.length).split('?')[0]) : null
        if (!name || !options.brandFiles.includes(name)) return next()
        response.setHeader('Content-Type', name.endsWith('.svg') ? 'image/svg+xml' : 'image/png')
        response.end(fs.readFileSync(path.join(options.brandDir, name)))
      })
    },
    generateBundle() {
      if (ssr) return
      for (const name of options.brandFiles) {
        this.emitFile({ type: 'asset', fileName: `brand/${name}`, source: fs.readFileSync(path.join(options.brandDir, name)) })
      }
    },
  }
}
