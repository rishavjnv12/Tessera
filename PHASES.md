# Torrent — Build Phases

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
xcodegen generate                # regenerate Torrent.xcodeproj after editing project.yml
open Torrent.xcodeproj           # schemes: Torrent-macOS, Torrent-iOS
```

Layout: `Apps/macOS`, `Apps/iOS` (app entry points), `Shared/` (code and assets used by both apps), `TorrentKit/` (Objective-C++ engine framework), `Packages/TorrentUI` (shared SwiftUI views), `Vendor/` (generated native libraries, not committed).

---

## Key decisions

| Topic | Decision | Why |
|---|---|---|
| Engine | **libtorrent-rasterbar 2.x** (C++), built as an XCFramework | Mature. Has per-piece priority, per-file priority, sequential mode, piece deadlines and full piece bitfields. That covers priorities 1–3 directly. |
| Bridge | Thin Objective-C++ facade (`TorrentKit`) that exposes plain Swift-friendly types | Keeps Boost and libtorrent headers away from Swift. Swift C++ interop is an option later. |
| Targets | `Torrent-macOS`, `Torrent-iOS`, `Torrent-watchOS`, `TorrentWidgets` (iOS + watch), shared `TorrentKit` framework and `TorrentUI` Swift package | Separate targets per platform, shared code for engine, models and piece map view. |
| Mac role | Primary engine. Runs 24/7, can be controlled remotely. | macOS has no background limits. |
| iPhone role | Runs its own engine while in foreground **and** can act as a remote for the Mac. | iOS suspends apps in the background, so long downloads belong on the Mac. |
| Watch role | Viewer and remote only. No engine. | watchOS cannot run a torrent session. |
| Distribution | Mac: direct / notarized. iPhone and Watch: personal signing via Xcode or TestFlight-style internal use. | App Store review generally rejects torrent clients. |

---

## Phase 0 — Project setup and engine build ✅ Done (2026-09-27)

- Split the current single multiplatform target into `Torrent-macOS` and `Torrent-iOS`. Drop visionOS from supported platforms.
- Script (`Scripts/build-libtorrent.sh`) that builds libtorrent + Boost + OpenSSL for macOS (arm64, x86_64), iOS device and iOS simulator, and packages `libtorrent.xcframework`.
- Add `TorrentKit` framework target that links the XCFramework.
- Shared `TorrentUI` local Swift package for views used on both Mac and iPhone.

**Done when:** both app targets build and launch and print the libtorrent version.

**Result:** libtorrent 2.1.2, Boost 1.92, OpenSSL 3.5.8. WebTorrent is off for now. Mac app is universal (arm64 + x86_64). iPhone device and simulator builds work. Both apps pass a self-test that hashes with libtorrent and starts and stops a session.

## Phase 1 — Engine core (TorrentKit)

- Session lifecycle: start, stop, settings (download folder, ports, rate limits, DHT, LSD, PEX, UPnP).
- Add torrent from `.torrent` file and from magnet link. Remove with or without data.
- Pause, resume, recheck.
- Alert loop turned into a Swift `AsyncStream` of snapshots (status, speeds, peers, ETA) at ~1 Hz.
- Resume data saved on changes and on quit, restored on launch.
- File list with sizes, progress and file-to-piece ranges.

**Done when:** a Mac command-line test harness downloads a public test torrent (e.g. a Linux ISO) and resumes after restart.

## Phase 2 — Piece map (Priority 1)

- Per-piece model: `missing`, `downloading` (with block fraction), `have`, `priority`, `availability` (peer count).
- Renderer using SwiftUI `Canvas`, with Metal fallback for torrents with tens of thousands of pieces. Pieces bucket together automatically when there are more pieces than pixels.
- Overlays: file boundaries, priority tint, rarest pieces.
- Interaction: hover (Mac) or tap (iPhone) shows piece index, file, state, peers. Pinch or scroll to zoom.
- Only changed pieces are sent from the engine each tick, so updates stay cheap.

**Done when:** a 20,000+ piece torrent animates smoothly at 60 fps on Mac and iPhone.

## Phase 3 — Priorities (Priority 2)

- File priority: Skip, Low, Normal, High. Applied from the file list, multi-select supported.
- Piece-range priority: select a range directly on the piece map (drag on Mac, drag handles on iPhone), then choose Highest / Normal / Lowest / Skip.
- Priority state persisted in resume data.
- Piece map tint updates as soon as priorities change.

**Done when:** setting a range to Highest makes those pieces fill first, visibly, on the piece map.

## Phase 4 — Download from start (Priority 3)

- Per-torrent **Sequential** toggle.
- Per-file **Download from Start**: raises the file's pieces to top priority, sets piece deadlines on the first chunk, and fetches first and last pieces early (needed by most media containers).
- "Ready up to" indicator showing how much of the file is contiguous from the start.
- Optional "Open while downloading" once enough of the start is ready.

**Done when:** a video file inside a multi-file torrent becomes playable from the start well before it finishes.

## Phase 5 — Mac app (Priority 4)

- `NavigationSplitView`: sidebar with All, Downloading, Seeding, Completed, Paused.
- `Table` with sortable columns: name, progress, size, speed, ETA, ratio.
- `.inspector` pane: piece map on top, then Files, Peers, Trackers, Info tabs.
- Toolbar with SF Symbols, search, drag and drop of `.torrent` files, magnet link URL handler, "Open with" registration.
- Dock icon progress, user notifications on completion, Settings window, standard menus and shortcuts.
- Optional menu bar extra with overall speeds.

**Done when:** the app feels like a stock Apple app next to Finder and Mail.

## Phase 6 — iPhone app (Priority 4)

- List of torrents with compact progress, swipe actions (pause, delete), pull to add.
- Detail screen: piece map card, files with priority menus, Download from Start action.
- Import from Files, Share Sheet, and magnet links.
- Downloads stored in the app's Documents folder, visible in the Files app.
- Live Activity and Dynamic Island for active downloads.
- Clear handling of background suspension: pause cleanly, resume on return.

**Done when:** the full add, prioritise, download flow works on a device.

## Phase 7 — Remote control (iPhone controls Mac)

- Mac publishes a local network service via Bonjour, with a paired device key.
- Small JSON over WebSocket API that mirrors TorrentKit's commands and snapshot stream.
- iPhone engine picker: "This iPhone" or "<Mac name>". Same UI either way.
- Optional later: remote access outside the home network via Tailscale or a relay.

**Done when:** the iPhone shows the Mac's piece map live and can change priorities on it.

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
- Unit tests for TorrentKit wrappers and priority logic. UI tests for main flows.
- Crash safety: resume data always flushed, no data loss on force quit.

---

## Suggested order

Phases 0–4 are built and tested on the Mac first, since it has no background limits and is fastest to debug. The iPhone app follows in Phase 6, reusing the piece map and priority views. Remote control and the watch come last because they depend on everything before them.
