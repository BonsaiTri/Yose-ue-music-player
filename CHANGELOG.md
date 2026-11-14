# Changelog

## 0.3.0

### New features
- **Playlist downloads**: on the Downloads screen, paste an M3U/M3U8
  playlist URL and every track in it is queued as an individual download
  (titles/artists read from `#EXTINF` tags, relative URLs resolved, nested
  playlists skipped, 200-track cap).

### Renamed & rebranded
- The app is now **Yose-ue Music Player** (Android label, macOS/Windows/Linux
  window titles, in-app screens, README).
- New app logo on every platform: Android launcher icons, macOS app icon,
  Windows `.ico`, Linux icon, and in-app (Home header, Settings → About).

### Usability overhaul
- **Simpler navigation**: five primary tabs (Home, Library, Search, Downloads,
  Settings) on both the mobile bottom bar and the desktop sidebar. Albums,
  Artists, Genres, Playlists, Favorites, History and Storage live one tap away
  on the Home hub instead of crowding the navigation.
- **New Home screen**: shows your library at a glance (songs/albums/artists
  counts), one-tap **Play all** and **Shuffle**, your recently played tracks,
  and browse cards with live counts.
- **Onboarding**: a first-run home screen with the logo and a clear
  "Import music" call to action (plus a drag-and-drop hint on desktop).
- **Import chooser**: importing now asks *files* vs *folder* (folders are
  scanned recursively), available from Home and Library.
- **Friendly empty states** on Library, Favorites, Playlists, Albums, Artists,
  Genres and History — each explains what to do next.
- Search screen no longer shows the source picker when no external source
  is registered.
- Settings → About now shows the logo, app name and version.

## 0.2.0

### New features
- **Genres screen**: browse all genres; tap a genre to play its tracks. Shown
  on the Home grid and in navigation.
- **Desktop drag-and-drop import**: drop audio files or folders anywhere on the
  window (macOS / Windows / Linux); files are copied into the library and a
  summary (added / duplicates / errors) is shown.
- **Pluggable search sources (§6.5)**: `MusicSourceProvider` abstraction with a
  source picker on the Search screen — remote results with artwork,
  in-library duplicate flags, and queue-download for sources exposing a
  direct media URL. Registry is empty by default (fully offline-first).
- **Settings**: max concurrent downloads (queue limit) and a user-selectable
  data location (applied on next launch; move the library via Backup & Restore).
- **Android**: storage permission requested before file-system imports
  (no-op on desktop).

### Database
- Schema v2: added `tracks.file_availability` and `download_tasks.status`
  indexes (spec §17.1) for filtered queries and download-queue polling.

### Performance
- New 20,000-track benchmark test: batch insert plus the queries the UI issues
  (paginated first/deep pages, FTS search) with explicit latency budgets.

### Documentation
- README now states the ffprobe decision explicitly: system `ffprobe` with
  `just_audio` fallback in v1; `BinaryManager` is ready for bundled
  per-OS/arch binaries when they are added.

## 0.1.0

First end-to-end build of the offline-first music player.

### Player
- Full playback via `just_audio` behind `audio_service` (lock-screen / media
  notifications, media buttons, shuffle, repeat modes, queue).
- Playback state persisted (queue, position, shuffle/repeat) and restored
  paused on launch; state flushed immediately on app detach.
- Interruption policy: transient → pause, resume on platform signal;
  permanent → stay paused.

### Library
- Drift (SQLite + FTS5) schema with string UUID IDs, reference-counted
  file locks, and full-text search.
- Import pipeline with ffprobe metadata extraction (just_audio fallback),
  artwork extraction, SHA-256 duplicate detection, and batched inserts.
- Library, artist, album, playlist, favorites, and history screens
  with windowed (paginated) track loading and per-track removal
  (keep-file vs delete-file, with orphaned artist/album/genre cleanup).

### Downloads
- Download queue executor: concurrent transfers, live progress,
  pause/cancel/resume, retry, on-disk validation of audio, collision-safe
  naming — plus a URL entry form on the Downloads screen to enqueue media.

### Resilience
- Verified auto-backups at boot (staleness check, retention of 5,
  fire-and-forget).
- Startup recovery: corrupt database is quarantined (with stale WAL/SHM)
  and the newest backup is restored before re-bootstrap.

### Platform
- Windows, macOS, Linux desktop targets (1400×860 default window).
- Android target with INTERNET / foreground-service-media-playback
  permissions and notification setup.

### Quality
- 25-test suite covering smoke boot, download engine (real HTTP server),
  lifecycle, backup service, database recovery, and end-to-end import.
- `flutter analyze`: 0 errors, 0 warnings.
