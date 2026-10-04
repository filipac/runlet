# Tinkerwell feature review for Runlet

Original research: 2026-10-02, before the MVP additions and 0.1.0. Reconciled under [#3](https://github.com/filipac/runlet/issues/3) using the changelog and source/test inspection. The original comparison and completed proposals are preserved in [done-next-release-ideas.md](done-next-release-ideas.md); its historical Tinkerwell status claims are not a current audit of that product.

Runlet now has the command palette/Open Anything, configurable shortcuts, project snippets, strict types, typography/wrap, external-editor links, keyboard-first library, CLI/file watching/export, SSH, production guards, SQL/mail/HTML inspection, and the integrated terminal. The old recommendation to build these is obsolete.

## Original MVP backlog: current disposition

| ID | Capability | Current disposition / remaining scope | Evidence or issue |
| --- | --- | --- | --- |
| B01 | Command registry and palette | Implemented | `Runlet/App/Commands.swift`, `Runlet/Features/Palette.swift` |
| B02 | Open Anything | Implemented, including SSH and History | `Runlet/Features/Palette.swift` |
| B03 | Custom shortcuts | Implemented | `Runlet/Features/ShortcutSettingsView.swift`, `RunletCore/Shortcuts.swift` |
| B04 | Tab handling | Reopen/close-right/number keys implemented; optional close confirmation and tab-cycle polish remain | [#50](https://github.com/filipac/runlet/issues/50), [#37](https://github.com/filipac/runlet/issues/37) |
| B05 | Project snippets | Implemented: metadata, read, save, and reloading when the folder changes ([#51](https://github.com/filipac/runlet/issues/51)) | [project-snippets.md](project-snippets.md#changes-on-disk) |
| B06 | Keyboard-first library | Implemented, including personal snippet descriptions | [Personal descriptions](personal-snippets.md), [#52](https://github.com/filipac/runlet/issues/52) |
| B07 | Strict types | Implemented | `RunletCore/Models.swift`, `Resources/Runner/src/Runner.php`, `StrictTypesTests.swift` |
| B08 | Layout commands | Manual show/hide, right/below and modes implemented; opt-in hide until a run and Escape to hide ([#60](https://github.com/filipac/runlet/issues/60)) | `Runlet/App/Commands.swift`, `Runlet/App/AppModel+OutputPane.swift` |
| B09 | Editor typography and wrapping | Implemented | `Runlet/Editor/EditorFonts.swift`, `CodeTextView.swift` |
| B10 | External-editor integration | Implemented via supported editors and custom commands | `Runlet/App/ExternalEditor.swift`, `RunletCore/EditorLinks.swift` |
| B11 | Terminal launcher | Implemented as the bundled Swift CLI | [cli.md](cli.md), `RunletCLI/RunletTool.swift` |
| B12 | Output export | Implemented | `RunletCore/OutputExport.swift`, `Runlet/App/AppModel+Inspector.swift` |
| B13 | External file changes | Implemented | `Runlet/App/FileSync.swift`, `RunletCore/FileWatcher.swift` |

Abbreviated RunletCore paths are under `Packages/RunletKit/Sources/`; test files are under its `Tests/` directory. Implementation status is not a claim that this audit executed those tests.

## Remaining work and decisions

- SQL inspector: add Explain: [#4](https://github.com/filipac/runlet/issues/4).
- Run recorder: HTTP calls, general jobs, and optional events: [#5](https://github.com/filipac/runlet/issues/5).
- Readable values: built-in summaries and driver casters: [#6](https://github.com/filipac/runlet/issues/6).
- Magic comments: [#10](https://github.com/filipac/runlet/issues/10).
- Xdebug "Debug Run": [#11](https://github.com/filipac/runlet/issues/11).
- Sandbox-only auto-run: implemented as an explicit per-tab opt-in ([#30](https://github.com/filipac/runlet/issues/30)); see [the guide](sandbox-auto-run.md).
- Global drivers, Testbench, and a driver gallery: [#18](https://github.com/filipac/runlet/issues/18).
- App info panels: implemented as App Info on the framework chip, with `panels()` for drivers ([#19](https://github.com/filipac/runlet/issues/19)); see [drivers.md](drivers.md#app-info).
- Log viewer: [#20](https://github.com/filipac/runlet/issues/20).
- PHPantom navigation: implemented as Go to Definition with a peek, Find References, code actions, inlay hints, and folding ([#22](https://github.com/filipac/runlet/issues/22)); see [the guide](navigation.md).
- Format snippet: [#36](https://github.com/filipac/runlet/issues/36).
- Editor polish: [#37](https://github.com/filipac/runlet/issues/37).
- Tinkerwell migration: [#23](https://github.com/filipac/runlet/issues/23).
- Share and send code: [#38](https://github.com/filipac/runlet/issues/38).
- Optional output auto-hide and Escape behavior: implemented as two opt-in Output settings ([#60](https://github.com/filipac/runlet/issues/60)); see [compatibility notes](compatibility.md#output-pane-hide-until-a-run-escape-hides-it-60).
- Validate remaining SQL and mail inspector integrations: [#53](https://github.com/filipac/runlet/issues/53).
- Refresh validation evidence and close documented acceptance gaps: [#54](https://github.com/filipac/runlet/issues/54).

The active [release ideas index](next-release-ideas.md) includes all other feature issues and preserved priorities. Vim, Graph view, a dedicated PhpStorm plugin, non-macOS apps, Vapor/Cloud and commercial licensing remain skipped/reference scope unless requested; they are not open TODOs. Original open questions already answered by code (palette keys/history prefix, supported editors, CLI installation locations, SSH defaults) no longer require a decision.
