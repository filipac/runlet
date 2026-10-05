// VitePress's default theme without its web font: the docs use the system fonts, like the
// landing page (website/styles.css), with Runlet's colours in brand.css.
import type { Theme } from 'vitepress'
import { useData, useRoute } from 'vitepress'
import DefaultTheme from 'vitepress/theme-without-fonts'
import mediumZoom, { type Zoom } from 'medium-zoom'
import { nextTick, onMounted, watch } from 'vue'
import './brand.css'

// Click-to-zoom on every image in a page (#295). The Markdown renders each image inside a
// `a.runlet-zoom` link to the full-size file (zoomableImages in markdown.ts), so without
// JavaScript a click opens the image in a new tab. With it, a click, a tap, or Return on the
// focused link opens the image in a lightbox instead; a click, Esc, or scrolling closes it.
// Light and dark pairs hide the other appearance's link, so only the visible image zooms.
const images = '.vp-doc a.runlet-zoom > img'

export default {
  extends: DefaultTheme,
  setup() {
    const route = useRoute()
    const { isDark } = useData()
    let zoom: Zoom | undefined

    const attach = () => {
      if (!zoom) return
      zoom.detach()
      zoom.attach(images)
    }

    onMounted(() => {
      zoom = mediumZoom({ background: 'var(--vp-c-bg)', margin: 24 })
      attach()
      // Before medium-zoom's own click handler: keep the link from opening a tab, and open the
      // lightbox for a click on the link itself (Return on a focused link).
      document.addEventListener('click', (event) => {
        const link = event.target instanceof Element ? event.target.closest<HTMLAnchorElement>('.vp-doc a.runlet-zoom') : null
        const image = link?.querySelector('img')
        if (!zoom || !link || !image) return
        if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) {
          // ⌘-click and the like open the file in a tab or window, as for any link.
          event.stopPropagation()
          return
        }
        event.preventDefault()
        if (!zoom.getImages().includes(image)) zoom.attach(image)
        if (event.target === link) zoom.open({ target: image })
      }, true)
    })

    // A new page's images, once its content is in the DOM.
    watch(() => route.path, () => nextTick(attach))
    // The zoomed copy is of the old appearance's image.
    watch(isDark, () => zoom?.close())
  },
} satisfies Theme
