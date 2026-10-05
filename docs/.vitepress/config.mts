// The documentation website at https://runletapp.dev/docs/ (#287), built from the Markdown in
// docs/. GitHub Actions builds and deploys it (.github/workflows/pages.yml); build output is never
// committed. Preview locally with `npm ci && npm run docs:dev`. How to write and add pages:
// docs/writing-docs.md.
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { defineConfig } from 'vitepress'
import { runletDocs } from './checks'
import { appearanceImages, githubSlug, placeholdersAsText, repositoryLinks, repositoryURL, stripDeveloperSections } from './markdown'
import { developmentPages, internalPages, pageLink, publishedPages, sidebar } from './navigation'
import { releaseNotes, releaseNotesPage } from './releaseNotes'

const docsDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const repoRoot = path.resolve(docsDir, '..')
const base = '/docs/'
const brandFiles = ['logo-56.png', 'favicon-16.png', 'favicon-32.png', 'favicon-48.png', 'apple-touch-icon.png']

// Links to repository files that don't exist, found while rendering; `buildEnd` fails on them.
const missingLinks = new Set<string>()

// The top bar's Docs, Development, and Changelog entries, highlighted by the page you're on.
const releaseNotesLink = pageLink(releaseNotesPage.replace(/\.md$/, ''))
const developmentMatch = `^/(${developmentPages.join('|')})$`
const releaseNotesMatch = `^${releaseNotesLink}$`
const docsMatch = `^/(?!(${[...developmentPages, releaseNotesLink.slice(1)].join('|')})$)`

export default defineConfig({
  title: 'Runlet',
  titleTemplate: ':title · Runlet Docs',
  description: 'Documentation for Runlet, the free, open-source PHP scratchpad for macOS: run code inside your Laravel, Symfony, or WordPress project, locally, in Docker, or over SSH.',
  lang: 'en-US',
  base,
  cleanUrls: true,
  // Internal pages stay in docs/ for maintainers; links to them go to GitHub.
  srcExclude: internalPages.map((page) => `${page}.md`),
  ignoreDeadLinks: false,

  head: [
    ['link', { rel: 'icon', type: 'image/png', sizes: '32x32', href: `${base}brand/favicon-32.png` }],
    ['link', { rel: 'icon', type: 'image/png', sizes: '16x16', href: `${base}brand/favicon-16.png` }],
    ['link', { rel: 'icon', type: 'image/png', sizes: '48x48', href: `${base}brand/favicon-48.png` }],
    ['link', { rel: 'apple-touch-icon', href: `${base}brand/apple-touch-icon.png` }],
    ['meta', { name: 'theme-color', content: '#5856d6' }],
    ['meta', { property: 'og:type', content: 'website' }],
    ['meta', { property: 'og:site_name', content: 'Runlet' }],
    ['meta', { property: 'og:image', content: 'https://runletapp.dev/assets/og.jpg' }],
  ],

  markdown: {
    anchor: { slugify: githubSlug },
    config(md) {
      stripDeveloperSections(md, (relativePath) => developmentPages.includes(relativePath.replace(/\.md$/, '')))
      // Before the other rules: the release notes page is generated from CHANGELOG.md (#291).
      releaseNotes(md, { repoRoot, published: new Set(publishedPages) })
      placeholdersAsText(md)
      appearanceImages(md)
      repositoryLinks(md, {
        repoRoot,
        docsDir: 'docs',
        published: new Set(publishedPages),
        onMissing: (page, href) => {
          const entry = `docs/${page}: ${href}`
          if (!missingLinks.has(entry)) console.warn(`(!) Link to a file that isn't in the repository: ${entry}`)
          missingLinks.add(entry)
        },
      })
    },
  },

  vite: {
    plugins: [
      runletDocs({
        docsDir,
        published: publishedPages,
        internal: internalPages,
        brandDir: path.join(repoRoot, 'website', 'assets'),
        brandFiles,
      }),
    ],
    build: { chunkSizeWarningLimit: 1500 },
  },

  buildEnd() {
    if (missingLinks.size > 0) {
      throw new Error(`Links to files that aren't in the repository:\n  ${[...missingLinks].join('\n  ')}`)
    }
  },

  themeConfig: {
    logo: { src: '/brand/logo-56.png', width: 28, height: 28, alt: '' },
    siteTitle: 'Runlet',
    nav: [
      { text: 'Docs', link: '/', activeMatch: docsMatch },
      { text: 'Development', link: pageLink(developmentPages[0]), activeMatch: developmentMatch },
      // Release Notes, generated from CHANGELOG.md's version sections (#291).
      { text: 'Changelog', link: releaseNotesLink, activeMatch: releaseNotesMatch },
      { text: 'Website', link: 'https://runletapp.dev/', target: '_self' },
      { text: 'Download', link: `${repositoryURL}/releases/latest` },
    ],
    sidebar: sidebar(),
    outline: { level: [2, 3], label: 'On this page' },
    search: { provider: 'local', options: { detailedView: 'auto' } },
    socialLinks: [{ icon: 'github', link: repositoryURL, ariaLabel: 'Runlet on GitHub' }],
    editLink: { pattern: `${repositoryURL}/edit/main/docs/:path`, text: 'Edit this page on GitHub' },
    docFooter: { prev: 'Previous', next: 'Next' },
    footer: {
      message: 'Free and open source under the MIT License.',
      copyright: 'Laravel, Symfony, WordPress, Docker, and other names are trademarks of their owners.',
    },
    externalLinkIcon: true,
  },
})
