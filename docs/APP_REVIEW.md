# SpareDisk app, code and design review

Reviewed September 12, 2026. Scope: the native SwiftUI app in this repository, its scanner and cleanup services, Xcode configuration, existing running UI, and the updated local build. This is a source and interface review, not certification of deletion safety or App Store approval.

## Assessment

The foundation is sensible: user-chosen folders, local metadata scanning, a separate cleanup service, review before Trash, and native navigation. The main gap is that several screens communicate a more complete product than the implementation provides. Trustworthy scope, accurate totals, and predictable selection matter more here than adding decorative dashboards.

The missing Large Files icon was reproducible: `doc.magnifyingglass` returned nil from `NSImage(systemSymbolName:)` on this Mac. The replacement `doc.text.magnifyingglass` exists. The project already had a complete AppIcon catalog containing a basic blue-ring icon; it lacked a cohesive identity inside the app. The initially running build also differed from current source, so source review and fresh-build verification were both necessary.

**Recommendation:** continue as a sandboxed folder analyzer, but treat the current cleanup implementation as pre-release. Resolve the safety and scan-lifecycle findings below before distributing it as a trusted cleaning utility.

## Changes completed in this pass

| Area | Before | Implemented |
|---|---|---|
| Identity | Basic ring asset; no in-app identity | New disk-and-spare-sector icon in all 10 macOS asset slots, sidebar identity and About sheet |
| Missing symbols | Invalid Large Files SF Symbol in two views | Validated replacement in sidebar and Overview |
| File icons | Every file used the same generic document symbol | Native macOS file-type artwork via `NSWorkspace.icon(for:)`, without opening file contents |
| Inspector | Third column remained allocated when hidden | Native SwiftUI inspector that collapses; hidden initially |
| Navigation | Inert Back/Forward and menu actions | History stack and functional Choose Location, Rescan, Inspector and About commands |
| Context | Clicking a location did not reliably change rescan target | Selected location updates active context; context-menu Rescan targets its row |
| Search | Home-specific prompt; Find ignored it | Contextual prompts and name filtering in Large/Older Files |
| Sidebar | Collapsed locations, unfinished History row, Review selection tag misplaced | Expanded locations, visible real destinations, correct Review row selection |
| Inspector data | Fabricated percentage, default unrelated item, blanket access claim | Actual selection, no default file, logical-size labeling and qualified access state; oldest candidates resolvable |
| Sample data | Real location awaiting scan could show sample contents | Real unscanned locations show no completed results; model prevents sample-only/unrecognized candidates entering review |
| Scan progress | Determinate indicator always at 100% | Indeterminate progress with count and elapsed time |
| Layout | Fixed table widths crowded the center | Flexible name columns and compact size/share columns; modification details remain in inspector |
| Settings | Appearance selection not applied or persisted | System/Light/Dark preference persisted and applied; placeholder density control removed |
| Explanations | Inert totals/scan-issues links; implementation prose | Functional explanatory popover and issues sheet; clearer status copy |
| Input handling | Large numeric thresholds could trap on integer conversion | Finite/range validation; month input bounded |
| Restore | Reappearing sidebar could append duplicate saved locations | Skip locations already restored |

The changes improve presentation and basic interaction. They do not replace the scan or cleanup architecture. File-type artwork reflects macOS defaults; it does not yet reproduce custom per-file Finder icons or each installed application's own bundle icon.

## Findings that remain

### P1 — Cleanup does not validate stable file identity

Evidence: `SpareDisk/Services/CleanupService.swift`, `revalidate`, and the `ScanNode` model. IDs are derived from paths. The checks compare path containment, type, size and date; they do not compare filesystem resource identity or volume identity. A replacement file with the same size and timestamp can pass. When the target becomes a symlink, the current code skips type/metadata checks. Lexically normalizing a path does not resolve symlinked ancestors.

Required work: capture stable identity and grant provenance during scanning; re-resolve scope and verify identity immediately before mutation. Reject unexpected symlinks and ancestor changes. Define a fail-closed policy for the remaining check-to-operation race. Test replacement files, parent symlink substitution, moved roots, changed volumes, permission loss and missing metadata using disposable fixtures. Do not claim that the current comments about “identity” establish this protection.

### P1 — Folder revalidation compares incompatible timestamps

Evidence: `ScanEngine.swift` aggregates a folder's `modified` value from the newest date encountered in its descendants. `CleanupService.swift` compares that value with the selected directory's own modification date. This can reject unchanged folders and does not establish that the reviewed descendant set is unchanged. Nested content edits need not change the selected ancestor's date.

Required work: keep directory metadata separate from descendant summaries. Stage a review manifest or generation and validate relevant contents before moving a folder. A folder containing a Photos library or other managed data needs an explicit policy: checking only the selected root's extension does not protect managed descendants. Until this is implemented, prefer a file-only cleanup release or keep folder cleanup unavailable in a distribution build.

### P1 — Scan ownership and cancellation are not isolated

Evidence: `AppScanActions.swift` starts a detached worker within an `AsyncStream`, applies results after finishing the stream, and clears shared scan state in the consumer. There is no per-run generation check. An older scan can finish after a newer one, apply stale results, or clear the newer scan's progress. The security scope can be released as the consumer exits while the worker is still unwinding.

The target sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. A detached caller alone does not prove that `ScanEngine.scan` runs outside the main actor. The build also emits a warning that `DirectoryEnumerator.makeIterator` is unavailable from asynchronous contexts and becomes an error in Swift 6 mode. Cleanup's filesystem work needs the same execution-context review.

Required work: isolate filesystem work explicitly, own each run with a generation/token, await worker termination before releasing grants, and accept progress/results only from the current run. Use Instruments to verify UI responsiveness. Test cancel→rescan, switching locations, forgetting a location mid-scan, closing windows, and rapid consecutive scans.

### P1 — Persistent permission lifecycle and preview access need validation

Evidence: `LocationAccessService.resolve` returns a stale flag without rebuilding the stored bookmark. UI notices currently imply reauthorization occurred even though it did not. Inspector and Browse reachability/preview actions use newly constructed path URLs after scan scope is released. Their results therefore do not establish access under the saved grant. Scope-start failures need explicit treatment rather than assuming a successful resolve is sufficient.

Required work: centralize a scoped operation API, refresh stale bookmark data while access is held, and hold scope through the entire Quick Look session where required. Distinguish missing, offline, denied and expired-grant failures. Test a signed app after termination/relaunch and moved-folder scenarios.

The inspected ad-hoc Debug signature has `app-sandbox = true`, `files.user-selected.read-write = true` and `get-task-allow = true`. This is a local development signature, not a distribution archive. Do not diagnose the absence of `files.bookmarks.app-scope` alone as a modern macOS blocker: Apple's archived entitlement guide and more recent developer guidance differ on whether that key is necessary. The actual bookmark lifecycle must be proven on supported systems. See [current sandbox access documentation](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox), [archived entitlement guidance](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html), and [recent Apple forum clarification](https://developer.apple.com/forums/thread/798402?answerId=855880022).

### P2 — Review totals and overlap handling disagree

Evidence: `CleanupService.normalize` deduplicates node IDs and excludes descendants, but Review/status totals sum the raw queue. Different scan roots or representations can produce different IDs for the same path. When a parent is moved, queued descendants can remain because only returned moved IDs are removed.

Required work: a single normalized review plan drives the header, confirmation, execution and results. Preserve provenance separately from identity; reconcile descendants after a successful parent move. Show logical bytes selected without claiming these equal disk space immediately reclaimed. Trash may remain on the same volume.

### P2 — The Map is a prototype, not a complete storage explorer

Evidence: `TreemapView.swift` uses one-dimensional slice-and-dice strips. A minimum width of 40 can cause areas to overflow or produce negative remaining widths. The screen claims two levels although the rendered layout has one. “Other” cannot be opened. Tap gestures lack equivalent focusable button behavior inside the map.

Required work: implement a bounded squarified layout, clamp nonnegative geometry, use the visible subtree's total, and retain a labeled table alternative. Render only labels that fit both dimensions. Provide click/Return selection, breadcrumb drill-down, parent navigation, keyboard focus, and meaningful activation of Other. Do not resize cells with arbitrary minimum widths that break area proportions. No map algorithm changes were made in this identity pass.

### P2 — Real browse hierarchy and search coverage are incomplete

Evidence: real scans retain top-level aggregates and two 200-candidate lists; the richer recursive tree is only present in mock data. Large/Older search filters these retained candidates, not every file on disk. A folder row cannot yet explore arbitrary real descendants. Overlapping granted roots can repeat candidates.

Required work: an indexed scan snapshot with parent IDs and paged children; real drill-down; deterministic sorting with ties; search coverage explicitly shown. Until then, label the views as retained rankings and do not promise exhaustive search. This pass adds a 200-result disclosure but does not build the index.

### P2 — Cloud and physical storage accounting are incomplete

Evidence: the scanner treats `isUbiquitousItem` as cloud-placeholder status, although iCloud membership does not by itself establish download state. It requests allocated-size metadata but totals logical file sizes, does not deduplicate hard links, and does not reconcile APFS clones/snapshots. Volume statistics are collected when the location is described rather than consistently refreshed at scan completion.

Required work: distinguish residency using appropriate resource keys; avoid hydration; label unknown states. Track logical and allocated measurements independently with explicit confidence. Refresh volume availability at the relevant time and show its timestamp. Never equate summed file sizes with exact reclaimable storage.

### P2 — Accessibility and compact layouts need a measured audit

Improved: native file artwork, functional inspector, flexible columns, primary/secondary text, and fewer irrelevant controls. Remaining: small tertiary text elsewhere, chart text over translucent category fills, cramped Overview cards with the inspector open, map keyboard navigation, and missing space-bar Quick Look behavior. The original shortcut tooltip was removed because no handler existed.

Acceptance criteria: test 900-point minimum width and normal 1180-point width, both inspector states, long localized paths, Light/Dark, Increase Contrast, Reduce Transparency, Reduce Motion, and VoiceOver. Measure normal text to at least 4.5:1 and meaningful non-text boundaries to 3:1 where applicable; do not treat system colors as automatic certification over custom chart fills. Follow [Apple accessibility guidance](https://developer.apple.com/design/human-interface-guidelines/accessibility).

### P2 — Distribution configuration needs an explicit product decision

The project currently targets macOS 26.5 and arm64, with x86_64 excluded. This is narrower than the earlier research plan's possible macOS 14 baseline. Do not lower the deployment target without availability auditing and actual test machines. Confirm target audience before promising older-system or Intel support.

## Design direction and next implementation plan

1. **Stabilize trust and data first.** Resolve P1 findings, add disposable filesystem fixtures and a signed sandbox smoke test. Keep cleanup out of a public release until its contract is verified.
2. **Complete storage exploration.** Build real hierarchy, table sorting, breadcrumb navigation, proper map geometry, complete coverage labels, and volume-versus-folder accounting. Put “what am I looking at?” above the chart.
3. **Refine the main window.** Keep the native sidebar and toolbar, one accent for interaction, and a quiet opaque content surface. Use 8/12/16/24 spacing increments, 13–14-point body text, 12–13-point supporting text, and monospaced digits for byte columns. Avoid dashboard cards where a ranked list conveys more.
4. **Make the inspector a decision aid.** Name and native icon, selectable path, logical size, measured allocation if available, date semantics, access, preview/reveal, then Add to Review. State unknowns plainly. No generic “safe to delete” badge.
5. **Finish cleanup outcomes.** A review sheet shows normalized counts and bytes, folders versus files, changed candidates, and per-item results. Escape cancels before starting; cancellation during a batch stops between items and retains completed outcomes. Do not imply an atomic rollback or guaranteed space recovery.
6. **Release polish.** Validate contrast with measurements, keyboard-only journeys and VoiceOver, icon small-size legibility, and release signing. Finalize App Store screenshots and honest metadata only after sandbox capability tests pass.

## Brand implementation

The mark is a pale disk with a detached teal sector on a midnight-blue tile: a simple visual connection to disk space and making room. The silhouette, rather than tiny details or lettering, carries recognition at Dock and sidebar sizes. It is an original generated concept, not copied from DiskBuddy.

Files: [1024px master](brand/SpareDisk-Icon.png), [original icon backup](brand/Original-AppIcon.png), and [generation provenance](brand/README.md). The AppIcon catalog contains 16, 32, 128, 256 and 512-point slots at 1× and 2×. A separate named image asset supplies the sidebar and About sheet. The project already points its app-icon build setting at `AppIcon`.

Use the symbol at roughly 32–40 points in the sidebar and 96 points in About; do not repeat it in every panel. Preserve transparent outer corners. A future Icon Composer version can provide separate layers; this pass uses a conventional flattened asset catalog. See [Apple app icon guidance](https://developer.apple.com/design/human-interface-guidelines/app-icons) and [Xcode icon configuration](https://developer.apple.com/documentation/xcode/configuring-your-app-icon).

## Verification performed

- Original source baseline built successfully before the changes.
- Updated app built successfully with local ad-hoc signing using Xcode.
- Four Swift Testing regressions passed: navigation/history, sample cleanup rejection, inspector selection, and the repaired SF Symbol.
- Opened the updated build and visually confirmed the sidebar logo, repaired Large Files icon, expanded locations and collapsed inspector. A running scan displayed indeterminate progress and item counts.
- Confirmed the master is 1024×1024 with alpha; packaged every configured icon slot and the in-app logo asset.
- Inspected built Debug entitlements. This does not establish TestFlight/Mac App Store behavior.
- No cleanup operation or deletion of user files was executed for testing. No exhaustive accessibility/contrast audit or cross-version distribution test is claimed.

Build command: `xcodebuild -project SpareDisk.xcodeproj -scheme SpareDisk -configuration Debug -derivedDataPath /private/tmp/sparedisk-derived-review CODE_SIGN_IDENTITY=- build`

Test command: same configuration with `-only-testing:SpareDiskTests test`.

The existing async directory-enumerator warning remains; an App Intents metadata warning is also emitted because the target has no AppIntents dependency. These are recorded rather than obscured by the successful build.
