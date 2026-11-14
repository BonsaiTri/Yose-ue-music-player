# Yose-ue Music Player

Offline-first, cross-platform music player built with Flutter/Dart.
Targets Windows, macOS, Linux, and Android. No cloud dependency — the entire
library, metadata, and playback live on local disk.

## Architecture

- **Persistence**: Drift (SQLite + FTS5 full-text search). String UUIDs for all
  entity IDs.
- **Playback**: `just_audio` + `audio_service` (media notifications / lock
  screen controls) + `audio_session` (interruption handling).
- **State**: Riverpod.
- **Metadata**: system `ffprobe` with a `just_audio` fallback (bundled
  platform binaries are supported by `BinaryManager` but intentionally not
  shipped in v1 — see *Design notes*); SHA-256 content hashing for duplicate
  detection.
- **Search sources**: pluggable `MusicSourceProvider` abstraction (§6.5) with a
  source picker, remote artwork, duplicate flags, and queue-download; empty
  by default (fully offline-first).
- **Desktop drag-and-drop** import of files/folders; **Android** storage
  permission flow for file imports.
- **Downloads**: pluggable source protocol with a queue executor
  (`features/downloader/domain/download_engine.dart`) — resumable queue,
  concurrent transfers, pause/cancel, on-disk validation of imported audio,
  **M3U/M3U8 playlist download** (paste a playlist URL and every track is
  queued automatically) and **YouTube video/playlist download** via a bundled
  **yt-dlp** backend (bundled Python runtime on Android; pinned, SHA-256
  verified binary on desktop — YouTube's PO-token requirement makes plain
  HTTP stream resolution impossible; see
  `features/downloader/domain/yt_dlp.dart`).
- **Resilience**: verified auto-backups (retention 5) at boot, a recovery
  screen that quarantines a corrupt database and restores the newest backup.

```
lib/
├── app/                    # App widget, theme bootstrap, DI container, recovery
├── core/                   # Constants, errors, logging, platform, services
├── database/               # Drift schema, migrations, repositories
└── features/               # Feature modules (player, library, import, …)
```

Key services in `lib/core/services/`:

| Service | Responsibility |
| --- | --- |
| `FileService` | Atomic file ops, directory layout under app data |
| `FileLockManager` | Reference-counted file locks |
| `MetadataService` | ffprobe / just_audio probing, art parsing, hashing |
| `ArtworkService` | Artwork cache keyed by content hash |
| `BackupService` | Verified backup/restore + `autoBackupIfStale` at boot |
| `DiagnosticsService` | Health checks (db, binaries, storage) |
| `BinaryManager` | Validates `ffprobe` availability per OS/arch at startup |

Playback (`lib/features/player/domain/playback_controller.dart`) wraps
`just_audio.AudioPlayer` behind an `audio_service` `BaseAudioHandler`.
Playback state (queue, position, shuffle/repeat) is persisted to a JSON file
on a 5 s throttle (flushed immediately on app detach) and restored paused on
launch.

## Running

```sh
flutter pub get
flutter run            # picks a connected device / emulator
flutter test           # full test suite (26 tests)
```

## Building

| Target | Host | Command |
| --- | --- | --- |
| Android APK | macOS / Linux / Windows | `flutter build apk --release` |
| macOS app | macOS + Xcode | `flutter build macos --release` |
| Windows exe | Windows + VS | `flutter build windows --release` |
| Linux bin | Linux + GTK3/ninja | `flutter build linux --release` |

Each desktop host builds only its own target. Android can be cross-built
from macOS (verified: `flutter build apk --release` produces
`build/app/outputs/flutter-apk/app-release.apk`).

Required Android SDK packages (via `sdkmanager`):
`platform-tools`, `platforms;android-36`, `build-tools;36.0.0`.

## Testing

`flutter test` runs:

- **smoke** — boots the real dependency graph against a real Drift database,
  pumps the app shell, verifies migrations, repository queries, FTS search.
- **download_engine** — the download queue against a real local `HttpServer`
  (progress, completion, concurrency, pause, cancel, resume, retry).
- **lifecycle** — `flushState` safety, playback-state JSON round-trip,
  corrupted-state tolerance, full `MusicPlayerApp` lifecycle sweep.
- **backup_service** — auto-backup staleness, retention pruning,
  broken-store resilience (never throws).
- **recovery** — `recoverDatabaseAt`: quarantine of corrupt DB + stale WAL,
  fresh-start fallback, restore from newest backup.
- **import** — end-to-end import of a real (synthesized) WAV: duration
  extraction, library placement, FTS hit, duplicate detection, non-audio skip.
- **benchmark** — inserts 20,000 synthetic tracks and times the queries the UI
  issues (first page, deep page, FTS search) against explicit latency budgets.

> `testWidgets` runs in a FakeAsync zone; real I/O in tests is wrapped in
> `tester.runAsync(...)` (see comments in the test files).

## Design notes

### ffprobe: system binary, not bundled (v1 decision)

`MetadataService` prefers the system `ffprobe` on `PATH` and falls back to
`just_audio` probing (duration, basic tags) when it is absent, so the app
always works. `BinaryManager` checks availability per OS/arch at startup and
exposes the result in Diagnostics. Bundling platform-specific `ffprobe`
binaries (per-OS licensing, signing, and ~25 MB × 3 architectures of binary
weight) is deliberately deferred; the `assets/binaries/<os>/<arch>/` layout
and `BinaryManager` resolution path are already in place so bundling can be
added later without architectural changes. `ffprobe` (ffmpeg) is available
on virtually every target via a package manager or Homebrew.

### Pluggable search sources (§6.5)

External metadata/download sources implement `MusicSourceProvider`
(`lib/features/search/domain/search_provider.dart`) and are registered in
`AppDependencies.sources` at bootstrap. The Search screen shows a source
picker (Library by default + registered providers), renders remote results
with artwork, flags duplicates already in the local library, and offers
"queue download" for results that expose a direct media URL. The default
registry is empty, keeping the app fully local/offline-first.

- **Interruption policy** (spec 17.3): transient interruptions pause playback
  and resume on the platform's resume signal; permanent interruptions stay
  paused.
- **Background policy**: on app `paused`/background the media app keeps
  playing; on `detached` the player state is flushed to disk immediately.
- **Duplicate detection**: SHA-256 of the file bytes; imports report
  duplicates without re-adding.
- **Atomic writes**: metadata/state files are written to a temp file then
  renamed into place.
- **Auto-backup**: at boot, `BackupService.autoBackupIfStale()` creates a
  verified backup when the newest is older than 24 h and prunes to the 5
  newest. Fire-and-forget; failures are logged, never fatal.
- **Recovery UI**: if bootstrap fails (e.g. corrupt database), the startup
  screen offers "Recover database and retry", which quarantines the corrupt
  file (plus stale WAL/SHM) and restores the newest backup, then re-boots.
