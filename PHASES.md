# Tessera — Build Phases

Native torrent client for macOS, iPhone and Apple Watch, written in SwiftUI.

**Top priorities** (these drive the order of the work):
1. Piece map for every torrent.
2. Highest / lowest priority for chosen parts (files and piece ranges).
3. Force a file to download from its start (streaming order).
4. Minimal Apple-style UI that looks like a built-in Apple app.

---

## Building from a fresh checkout

```sh
brew install xcodegen cmake
Scripts/build-libtorrent.sh      # ~15 min first time; creates Vendor/ (cached afterwards)
xcodegen generate                # regenerate Tessera.xcodeproj after editing project.yml
open Tessera.xcodeproj           # schemes: Tessera-macOS, Tessera-iOS
```

Layout: `Apps/macOS`, `Apps/iOS` (app entry points), `Shared/` (code and assets used by both apps), `TesseraKit/` (Objective-C++ engine framework with a Swift streams layer), `TesseraKitTests/` (offline engine tests), `Tools/tesseractl` (command-line harness), `Packages/TesseraUI` (shared SwiftUI views and the piece map, with its own tests: `swift test`), `Vendor/` (generated native libraries, not committed).

---

## Key decisions

| Topic | Decision | Why |
|---|---|---|
| Engine | **libtorrent-rasterbar 2.x** (C++), built as an XCFramework | Mature. Has per-piece priority, per-file priority, sequential mode, piece deadlines and full piece bitfields. That covers priorities 1–3 directly. |
| Bridge | Thin Objective-C++ facade (`TesseraKit`) that exposes plain Swift-friendly types | Keeps Boost and libtorrent headers away from Swift. Swift C++ interop is an option later. |
| Targets | `Tessera-macOS`, `Tessera-iOS`, `Tessera-watchOS`, `TesseraWidgets` (iOS + watch), shared `TesseraKit` framework and `TesseraUI` Swift package | Separate targets per platform, shared code for engine, models and piece map view. |
| Mac role | Primary engine. Runs 24/7, can be controlled remotely. | macOS has no background limits. |
| iPhone role | Runs its own engine while in foreground **and** can act as a remote for the Mac. | iOS suspends apps in the background, so long downloads belong on the Mac. |
| Watch role | Viewer and remote only. No engine. | watchOS cannot run a torrent session. |
| Distribution | Mac: direct / notarized. iPhone and Watch: personal signing via Xcode or TestFlight-style internal use. | App Store review generally rejects torrent clients. |

---

## Phase 0 — Project setup and engine build ✅ Done (2026-09-27)

- Split the current single multiplatform target into `Tessera-macOS` and `Tessera-iOS`. Drop visionOS from supported platforms.
- Script (`Scripts/build-libtorrent.sh`) that builds libtorrent + Boost + OpenSSL for macOS (arm64, x86_64), iOS device and iOS simulator, and packages `libtorrent.xcframework`.
- Add `TesseraKit` framework target that links the XCFramework.
- Shared `TesseraUI` local Swift package for views used on both Mac and iPhone.

**Done when:** both app targets build and launch and print the libtorrent version.

**Result:** libtorrent 2.1.2, Boost 1.92, OpenSSL 3.5.8. WebTorrent is off for now. Mac app is universal (arm64 + x86_64). iPhone device and simulator builds work. Both apps pass a self-test that hashes with libtorrent and starts and stops a session.

## Phase 1 — Engine core (TesseraKit) ✅ Done (2026-09-27)

- Session lifecycle: start, stop, settings (download folder, ports, rate limits, DHT, LSD, PEX, UPnP).
- Add torrent from `.torrent` file and from magnet link. Remove with or without data.
- Pause, resume, recheck.
- Alert loop turned into a Swift `AsyncStream` of snapshots (status, speeds, peers, ETA) at ~1 Hz.
- Resume data saved on changes and on quit, restored on launch.
- File list with sizes, progress and file-to-piece ranges.

**Done when:** a Mac command-line test harness downloads a public test torrent (e.g. a Linux ISO) and resumes after restart.

**Result:** `TorrentSession` (Objective-C++ `TKSession`) with async `snapshots()` and `events()` streams. Progress is saved to `<id>.fastresume` files in the state folder every 30 seconds, on pause, metadata and completion, and on shutdown. 9 offline tests (`TesseraKit` scheme) cover seeding, file-to-piece mapping, errors, magnets, pause, restart, removal and a local seed-to-leech download that stops and resumes. The `tesseractl` harness downloaded Sintel (129 MB) over the internet, stopped at 25 s, and finished from 80.8% on the next run.

```sh
tesseractl --state ~/.tesseractl/state --save ~/Downloads/tesseractl --files sintel.torrent   # Ctrl-C to stop
tesseractl --state ~/.tesseractl/state --save ~/Downloads/tesseractl --until-done             # continues
```

## Phase 2 — Piece map (Priority 1) ✅ Done (2026-09-27)

- Per-piece model: `missing`, `downloading` (with block fraction), `have`, `priority`, `availability` (peer count).
- Renderer using SwiftUI `Canvas`, with Metal fallback for torrents with tens of thousands of pieces. Pieces bucket together automatically when there are more pieces than pixels.
- Overlays: file boundaries, priority tint, rarest pieces.
- Interaction: hover (Mac) or tap (iPhone) shows piece index, file, state, peers. Pinch or scroll to zoom.
- Only changed pieces are sent from the engine each tick, so updates stay cheap.

**Done when:** a 20,000+ piece torrent animates smoothly at 60 fps on Mac and iPhone.

**Result:** `PieceMapCard` and `PieceMapView` in `Packages/TesseraUI` offer Progress, Availability and Priority views, zoom buttons, pinch to zoom, hover or tap details, and outlines for the selected file. The engine call `TorrentSession.pieces(of:)` supplies the data. The app's `PieceMapFeed` polls it off the main thread once per second and passes only the changed pieces. The cell count is capped by the view's area, and each redraw is a few batched fills, so Metal was not needed. Measured in optimized builds with CPU rasterization: about 0.5 ms per full redraw at 25,000 and 100,000 pieces, and about 3 ms when zoomed to 25,000 individual cells. Only downloading cells animate, in a small overlay. Frame rate has not been measured on a physical iPhone yet. Both apps have a minimal torrent list and detail screen to host the map, which Phases 5 and 6 will replace. Debug builds add a "Piece Map Demo" with 25,000 simulated pieces, plus the launch options `-openDemo YES` and `-addTorrent <magnet or path>`.

## Phase 3 — Priorities (Priority 2) ✅ Done (2026-09-27)

- File priority: Skip, Low, Normal, High. Applied from the file list, multi-select supported.
- Piece-range priority: select a range directly on the piece map (drag on Mac, drag handles on iPhone), then choose Highest / Normal / Lowest / Skip.
- Priority state persisted in resume data.
- Piece map tint updates as soon as priorities change.

**Done when:** setting a range to Highest makes those pieces fill first, visibly, on the piece map.

**Result:** Four levels everywhere: Highest (7), Normal (4), Lowest (1) and Don't Download (0). Files take multi-select plus a Priority menu or context menu, and rows show priority badges. On the piece map, drag on Mac or touch and hold then drag on iPhone to select a run of pieces. Handles adjust the ends, and a bar under the map offers Priority and Clear. Changes show immediately and are confirmed from the engine a moment later. The engine API is `setPriority(_:files:torrent:)` and `setPriority(_:pieces:torrent:)`. libtorrent resets every hand-set piece whenever a file priority changes, so TesseraKit re-applies hand-set pieces outside the changed files once libtorrent confirms the change. Priorities persist across restarts. Complete (seeding) torrents reject changes, because libtorrent ignores them. 4 new engine tests (14 total). In the ordering test, other pieces were 2–19% done when the Highest range reached 50%. On the real Sintel torrent in the iPhone simulator, the Highest range filled first. **Known limit:** HTTP web seeds download long sequential runs and can fill normal pieces alongside a Highest range. BitTorrent peers follow priorities. Debug launch option: `-highestPieces <first>-<last>` together with `-addTorrent`. On Mac the Priority menus and the file right-click menu are native AppKit menus, because SwiftUI-built menu items collapsed to a narrow strip on hover.

## Phase 4 — Download from start (Priority 3) ✅ Done (2026-09-27)

- Per-torrent **Sequential** toggle.
- Per-file **Download from Start**: raises the file's pieces to top priority, sets piece deadlines on the first chunk, and fetches first and last pieces early (needed by most media containers).
- "Ready up to" indicator showing how much of the file is contiguous from the start.
- Optional "Open while downloading" once enough of the start is ready.

**Done when:** a video file inside a multi-file torrent becomes playable from the start well before it finishes.

**Result:** "Download from Start" means this file first, in order. Other files pause, with their priorities saved. The torrent switches to sequential order. Deadlines keep about 1 MB after the first missing piece and the file's last megabyte urgent, so a slow peer cannot hold up the front. Once the rest of the file is urgent, everything returns to how it was. This survives a restart. The torrent also has a "Download in Order" toggle. Files report bytes readable from the start (`contiguousBytes`) and whether their end is present (`hasEnd`). The app shows a banner with Stop and Open, a readiness bar on the file, and Open (Quick Look on iPhone, default app on Mac) once 8 MB from the start and the end are present. Measured on the real Sintel torrent (129 MB, `tesseractl --from-start 5`): AVFoundation loaded the partial MP4 and decoded a frame at 14–29% downloaded across the final runs. What was tried and why it lost is recorded in TKSession.mm: deadlines on a large window, priority 7 on the file (libtorrent picks priority-7 pieces rarest-first), and priorities 5–6 (not strict). Engine settings changed for this: web-seed requests are capped at 2 MiB (was 16 MiB), and a check re-raises pieces libtorrent left at priority 0 after a file-priority restore. 2 new engine tests (16 total). Test lesson: throttle the sending peer, not the receiver, because a receive limit over loopback lets socket buffers fill and deliver out of order. Debug launch option: `-downloadFromStart <file index>`.

## Phase 5 — Mac app (Priority 4) 🔄 Built, waiting for visual review (2026-09-27)

- `NavigationSplitView`: sidebar with All, Downloading, Seeding, Completed, Paused.
- `Table` with sortable columns: name, progress, size, speed, ETA, ratio.
- `.inspector` pane: piece map on top, then Files, Peers, Trackers, Info tabs.
- Toolbar with SF Symbols, search, drag and drop of `.torrent` files, magnet link URL handler, "Open with" registration.
- Dock icon progress, user notifications on completion, Settings window, standard menus and shortcuts.
- Optional menu bar extra with overall speeds.

**Done when:** the app feels like a stock Apple app next to Finder and Mail.

**Status:** Built: the sidebar filters with counts, a sortable table with native right-click menus (double-click shows the files in Finder), and search. The inspector shows the piece map, then Files, Peers, Trackers (add and remove) and Info (hashes, dates, location, magnet link). Adding works through the open panel, drag and drop, Finder ("Open With", double-click) and magnet links. An add sheet lets you choose the folder and files. The menus are File (⌘O, ⇧⌘O) and Torrent (pause ⌘. , resume ⌘/, all ⌥, remove ⌘⌫, Show in Finder ⇧⌘R, Download in Order). The Settings window has General, Transfers and Network tabs, saved and applied live. The app also has Dock progress with a count badge, finish notifications, and a menu bar item that can be turned off. The default download folder is **~/Tessera** (user choice, via a home-relative sandbox exception). Other folders use security-scoped bookmarks. New engine APIs: peers, trackers, details, preview and file priorities at add time. 3 new engine tests (19 total), 16 TesseraUI tests. Verified: the sandboxed app downloaded Sintel into ~/Tessera. Not yet verified by eye: the layout, menus, add sheet, Settings, Dock, notifications and menu bar.

## Phase 6 — iPhone app (Priority 4) ✅ Done (2026-09-27, confirmed by the user)

- List of torrents with compact progress, swipe actions (pause, delete), pull to add.
- Detail screen: piece map card, files with priority menus, Download from Start action.
- Import from Files, Share Sheet, and magnet links.
- Downloads stored in the app's Documents folder, visible in the Files app.
- Live Activity and Dynamic Island for active downloads.
- Clear handling of background suspension: pause cleanly, resume on return.

**Done when:** the full add, prioritise, download flow works on a device.

**Status:** Built, and checked in the iPhone 17 and iPad Pro simulators:
- A list with a filter menu, search, swipe actions and context menus. On iPad the list sits beside the detail.
- A detail screen with the piece map and Files, Peers, Trackers and Info sections.
- An add sheet for choosing files, and a Settings screen with Keep Screen Awake (off by default), limits, queue and peer discovery.
- .torrent files and magnet links open the app, via `onOpenURL` and document and URL types.
- A **Share extension** (`TesseraShare`) writes to the App Group inbox (`group.io.github.rishavjnv12.Tessera`), and the app adds those torrents when it becomes active. Tested by dropping a magnet link into the inbox.
- A **Live Activity** with Dynamic Island (`TesseraWidgets`): started while downloading, marked paused when the app leaves the screen, ended when done. The log confirms it is created and updated. Its look is not checked, because simulator screenshots leave out the island.
- Leaving the screen saves progress inside a background task. Downloads land in the app's Documents folder (Files: On My iPhone › Tessera).

Engine fix: iOS can move an app's data container after a reinstall or update. Saved torrent paths inside the old container are now moved to the new one and re-checked. Before this, a reinstall made Sintel download again. Still to check on a real iPhone: the Share Sheet, the Live Activity and Dynamic Island, the Files app, and suspension behavior.

## Phase 7 — Remote control (iPhone controls Mac) 🔄 Built, waiting for on-device check (2026-09-27)

- Mac publishes a local network service via Bonjour, with a paired device key.
- Small JSON API over TCP that mirrors TesseraKit's commands and snapshot stream. The plan said WebSocket, but Network.framework's WebSocket client failed its handshake with host and Bonjour endpoints, so messages are length-prefixed.
- iPhone engine picker: "This iPhone" or "<Mac name>". Same UI either way.
- Optional later: remote access outside the home network via Tailscale or a relay.

**Done when:** the iPhone shows the Mac's piece map live and can change priorities on it.

**Status:** Built.
- **Engine interface:** screens use `TorrentBackend`, which is either the local `TorrentSession` or `RemoteBackend`, a proxy that answers from the Mac's latest data and refreshes in the background.
- **Mac server:** `RemoteServer` advertises `_tesseraremote._tcp` over Bonjour. Remote control is on by default, can be turned off in Settings › Remote, and each device has to be paired and approved.
- **Pairing:** X25519 key agreement. Both screens show a 6-digit code and the user clicks Allow on the Mac, so a device in the middle cannot pair. Long-term keys are kept in the Keychain.
- **Sessions:** per-connection keys, one per direction, with ChaCha20-Poly1305 and increasing sequence numbers. Snapshots are sent once per second, plus piece-map changes for the open torrent.
- **iPhone:** a device menu (This iPhone or a paired Mac), a pairing sheet showing the code, connection status, and automatic reconnection to the last Mac. Open and Show in Files are hidden for files that live on the Mac.
- **Engine and tests:** JSON coding for the engine's value objects. 6 remote tests cover pairing, the live list and piece map, a priority change in both directions, pause, errors, reconnection, unknown devices, wrong keys, declined pairing, tampering and replay. The simulator phone paired with the real Mac app and showed its Sintel piece map live.

Still to check on real devices: the local network permission prompts, and pairing over Wi-Fi.

## Phase 8 — Apple Watch

- Watch app: list of active torrents with progress rings, speeds, pause and resume.
- Detail: compact piece strip and ETA.
- Data from the iPhone through WatchConnectivity, so it works whether the phone runs the engine or controls the Mac.
- Complication and Smart Stack widget with overall progress. Live Activities from the iPhone also appear on the watch automatically.

**Done when:** a download started on the Mac can be followed and paused from the watch.

## Phase 9 — Polish and hardening

- Accessibility: VoiceOver labels for the piece map, Dynamic Type, reduced motion.
- Light and dark mode, Liquid Glass materials where Apple uses them.
- Performance testing with large torrents and many torrents at once.
- Unit tests for TesseraKit wrappers and priority logic. UI tests for main flows.
- Crash safety: resume data always flushed, no data loss on force quit.

---

## Suggested order

Phases 0–4 are built and tested on the Mac first, since it has no background limits and is fastest to debug. The iPhone app follows in Phase 6, reusing the piece map and priority views. Remote control and the watch come last because they depend on everything before them.
