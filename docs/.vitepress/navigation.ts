// The documentation's navigation manifest (#287). Every Markdown page in docs/ is either in a
// category below, in the order the sidebar shows it, or in `internalPages`. The build fails when
// a page is in neither (see checks.ts), so a new page has to be classified. How to add one:
// docs/writing-docs.md.

export interface Page {
  /** The sidebar's label: short, in title case ("Installation", "SQL Tabs"). */
  text: string
  /** The file in docs/ without `.md`. `index` is the docs home, /docs/. */
  page: string
}

export interface Category {
  text: string
  items: Page[]
}

export const categories: Category[] = [
  {
    text: 'Getting Started',
    items: [
      { text: 'Introduction', page: 'index' },
      { text: 'Installation', page: 'installation' },
      { text: 'Quickstart', page: 'quickstart' },
      { text: 'Everything in Runlet', page: 'features' },
    ],
  },
  {
    text: 'The Basics',
    items: [
      { text: 'Running Code', page: 'running-code' },
      { text: 'Tabs', page: 'tabs' },
      { text: 'Personal Snippets', page: 'personal-snippets' },
      { text: 'Project Snippets', page: 'project-snippets' },
      { text: 'Snippet Inputs', page: 'snippet-inputs' },
      { text: 'Promote a Snippet', page: 'promote-snippets' },
      { text: 'Settings', page: 'settings' },
      { text: 'Keyboard Shortcuts', page: 'keyboard-shortcuts' },
    ],
  },
  {
    text: 'Writing Code',
    items: [
      { text: 'Snippet API', page: 'snippet-api' },
      { text: 'Magic Comments', page: 'magic-comments' },
      { text: 'Code Navigation', page: 'navigation' },
      { text: 'Format Code', page: 'format-code' },
      { text: 'String Viewers', page: 'string-viewers' },
    ],
  },
  {
    text: 'Targets',
    items: [
      { text: 'SSH Targets', page: 'ssh' },
      { text: 'Sandbox Auto-Run', page: 'sandbox-auto-run' },
      { text: 'Dry Run', page: 'dry-run' },
    ],
  },
  {
    text: 'Frameworks & Drivers',
    items: [{ text: 'Framework Drivers', page: 'drivers' }],
  },
  {
    text: 'Databases',
    items: [
      { text: 'SQL Tabs', page: 'sql-tabs' },
      { text: 'Explain a Captured Query', page: 'sql-explain' },
      { text: 'Connections', page: 'connections' },
      { text: 'Redis', page: 'redis' },
      { text: 'MongoDB', page: 'mongodb' },
    ],
  },
  {
    text: 'Inspecting Runs',
    items: [
      { text: 'Log Viewer', page: 'logs' },
      { text: 'Run Timings', page: 'run-timings' },
      { text: 'Notifications for Long Runs', page: 'run-notifications' },
    ],
  },
  {
    text: 'Integrations',
    items: [
      { text: 'Command-Line Tool', page: 'cli' },
      { text: 'AI Clients (MCP)', page: 'mcp' },
    ],
  },
  {
    text: 'Help',
    items: [{ text: 'Reading a Crash Log', page: 'crash-logs' }],
  },
  {
    // For people who build Runlet and contribute to it (#293). These pages keep their
    // `## For developers` sections on the site: everything on them is for developers.
    text: 'Development',
    items: [
      { text: 'Building Runlet', page: 'building' },
      { text: 'Contributing', page: 'contributing' },
      { text: 'Testing', page: 'testing' },
      { text: 'Architecture', page: 'architecture' },
      { text: 'Writing Docs', page: 'writing-docs' },
      { text: 'Changelog Entries', page: 'changelog' },
      { text: 'Releasing', page: 'releasing' },
    ],
  },
]

/** The category whose pages keep `## For developers` on the site. */
export const developmentCategory = 'Development'

/**
 * Pages that stay in docs/ for maintainers but aren't published. Links to them from published
 * pages go to the file on GitHub.
 */
export const internalPages: string[] = [
  'validation', // requirement-to-evidence tables
  'compatibility', // compatibility and prototype-gate evidence
  'next-release-ideas',
  'done-next-release-ideas',
  'tinkerwell-feature-review',
  'whats-new', // authoring What's New entries and tours
]

export const publishedPages: string[] = categories.flatMap((category) => category.items.map((item) => item.page))

export const developmentPages: string[] =
  categories.find((category) => category.text === developmentCategory)?.items.map((item) => item.page) ?? []

/** A page's address on the site, relative to the docs' base. */
export function pageLink(page: string): string {
  return page === 'index' ? '/' : `/${page}`
}

/** The sidebar VitePress shows on every page. */
export function sidebar() {
  return categories.map((category) => ({
    text: category.text,
    collapsed: false,
    items: category.items.map((item) => ({ text: item.text, link: pageLink(item.page) })),
  }))
}
