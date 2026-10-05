# String Viewers

A string in your output is often more than text: an API's JSON, a long log message, a base64 image, or a fragment of HTML. Runlet recognises these and offers a view that fits, next to the usual **Tree**:

```php
App\Models\Order::find(1042)->toJson();
```

The result is a JSON string, so its card gets a **JSON** tab with an expandable tree.

String viewers work in result and dump cards, and in the run inspector's values. **Plain** and **Raw** output show strings as text, as before.

![A Result card holding a JSON string, with the JSON view selected and its tree expanded](screenshots/string-viewers/json-light.webp#gh-light-mode-only)
![A Result card holding a JSON string, with the JSON view selected and its tree expanded](screenshots/string-viewers/json-dark.webp#gh-dark-mode-only)

## The Viewers

| View | For | What you get |
| --- | --- | --- |
| **JSON** | A string that holds a JSON document | An expandable tree and **Copy Pretty**. Numbers keep their exact digits, including large integers and precise decimals, and members keep their order. |
| **Text** | Long strings, of 1,000 bytes or 10 lines or more (they open here by default) | Selectable, scrollable text that wraps, with search: match counts and previous and next. Any string can switch to Text. |
| **Image** | PNG, JPEG, and SVG images, as base64, as `data:` URLs, or as binary strings, and raw SVG | The image, at most 1,024 pixels for raster images. |
| **Preview** | A string that starts with common HTML tags | The rendered HTML, with its **Source** and **Copy HTML**. |

Choose a view with the picker at the top of the card. Switching views never runs PHP, connects to the target, or changes anything about the next run.

![A base64 SVG returned by a snippet, shown in the Image view](screenshots/string-viewers/image-light.webp#gh-light-mode-only)
![A base64 SVG returned by a snippet, shown in the Image view](screenshots/string-viewers/image-dark.webp#gh-dark-mode-only)

## Safe by Default

- **Previews are locked down.** HTML and SVG have scripts turned off and remote content blocked. Remote images in an HTML preview load only when you choose **Load Remote Images** for that preview.
- **Nothing is fetched.** Runlet only looks at the string it already has: no files or URLs are opened.
- **Large values stay text.** A JSON document deeper than 32 levels or with more than about 2,048 values stays in Tree and Text, and a JSON tree shows at most 200 children per object or array, marking the rest. Images larger than 4,096 pixels on a side, or that aren't valid, aren't shown.
- **Cut strings.** A string the runner had to shorten, or one larger than 64 KiB, offers Text only: no JSON, image, or detected HTML. Text shows how much was cut.

## For developers

String viewers were added under [#7](https://github.com/filipac/runlet/issues/7).

- They're offered for bounded strings in structured result and dump cards and in inspector values rendered by `ValueContentView`; nested tree leaves stay ordinary value rows. Runner-rendered previews (mailables, views, HTML responses) keep their own default view.
- Recognition uses only the string already delivered to Swift. Input is limited to 64 KiB (decoded bytes for runner-encoded binary strings). Truncated or budget-limited strings keep Text but don't offer JSON, image, or detected HTML previews.
- Raster previews decode a thumbnail of at most 1,024 pixels and refuse invalid images or dimensions above 4,096 on either side. SVG loads as an image in the existing restricted web view, with scripts and remote resources blocked. Search is literal and case-insensitive.

**Validation.** On 2026-10-03, 15 focused package tests and 3 native UI tests passed. Native snapshots use the actual Laravel sandbox (PHP 8.4.25, Laravel 13.34.0).

- `StringViewersTests` covers JSON types and exact number literals, pretty formatting, the UTF-8 BOM, malformed, deep, and wide documents, child limits, byte bounds, truncated values, PNG/JPEG/SVG encodings, HTML recognition, and literal Unicode search. The existing value table, output export, and production guard suites also run unchanged.
- The native tests paste whole snippets (restoring the clipboard) rather than typing large fixtures character by character. `testSpecializedJSONAndTextViewers` exercises actual sandbox JSON output, Tree/JSON switching, clipboard pretty copy, long-string defaults, search counts, navigation, no match, and Wrap. `testSpecializedImageAndHTMLViewers` exercises actual base64 and binary PNG, JPEG data URLs, malformed and oversized raster fallback, SVG, and HTML Preview/Source with remote images initially off. The existing restore-without-running test verifies the execution boundary.
- No Docker or live SSH target was exercised for this Swift-side change. The preview restriction code is reused; this issue's tests don't independently audit WebKit's network blocking.

The DEBUG capture script uses scratch session state, an explicit sandbox Run, and native app snapshots:

```sh
python3 scripts/string-viewer-screenshots.py /path/to/Runlet.app /path/to/output
```

The page's screenshots are taken by `scripts/docs-screenshots.py` ([#295](https://github.com/filipac/runlet/issues/295)).
