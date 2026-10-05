// VitePress's default theme without its web font: the docs use the system fonts, like the
// landing page (website/styles.css), with Runlet's colours in brand.css.
import type { Theme } from 'vitepress'
import { useData, useRoute } from 'vitepress'
import DefaultTheme from 'vitepress/theme-without-fonts'
import mediumZoom, { type Zoom } from 'medium-zoom'
import { nextTick, onMounted, watch } from 'vue'
import './brand.css'

// Click-to-zoom on every image in a page (#295). The Markdown renders each image inside an
// `a.runlet-zoom` link to the full-size file (zoomableImages in markdown.ts), so without
// JavaScript a click opens the image in a new tab. With it, a click, a tap, or Return on the
// focused link opens the image in a lightbox instead; a click, Esc, or scrolling closes it.
// Light and dark pairs hide the other appearance's link (brand.css), so only the visible image
// can be focused or zoomed.
const links = '.vp-doc a.runlet-zoom'

export default {
  extends: DefaultTheme,
  setup() {
    const route = useRoute()
    const { isDark } = useData()
    let zoom: Zoom | undefined

    // The page's images, once its content is in the DOM. Each link points at the file its image
    // shows: the built page has that already (zoomLinksToAssets), a page reached in the app has
    // the Markdown's path, which isn't a published file.
    const attach = () => {
      if (!zoom) return
      zoom.detach()
      for (const link of document.querySelectorAll<HTMLAnchorElement>(links)) {
        const image = link.querySelector('img')
        if (!image) continue
        if (image.src) link.href = image.src
        zoom.attach(image)
      }
    }

    onMounted(() => {
      zoom = mediumZoom({ background: 'var(--vp-c-bg)', margin: 24 })
      attach()
      // Before medium-zoom's own click handler: keep the link from opening a tab, and open the
      // lightbox for a click on the link itself (Return on a focused link).
      document.addEventListener('click', (event) => {
        const link = event.target instanceof Element ? event.target.closest<HTMLAnchorElement>(links) : null
        const image = link?.querySelector('img')
        if (!zoom || !link || !image) return
        // ⌘-click and the like open the file in a tab or window, as for any link, without zooming.
        if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) {
          event.stopPropagation()
          return
        }
        event.preventDefault()
        if (!zoom.getImages().includes(image)) zoom.attach(image)
        if (event.target === link) zoom.open({ target: image })
      }, true)
    })

    watch(() => route.path, () => nextTick(attach))
    // The zoomed copy shows the other appearance's image.
    watch(isDark, () => zoom?.close())
  },
} satisfies Theme
