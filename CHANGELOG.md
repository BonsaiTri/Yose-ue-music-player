# Changelog

## 0.3.4

### Changed
- **YouTube downloads now use yt-dlp** instead of the raw Innertube API.
  YouTube requires PO (proof-of-origin) tokens on its stream URLs since
  2024, which plain HTTP clients cannot produce; yt-dlp performs the
  attestation internally. This is a wholesale replacement of the download
  mechanism, not a fallback: the old resolver is no longer used.
  - **Android**: bundled yt-dlp runtime (private Python + yt-dlp script via
    the `youtubedl-android` AAR; arm64-v8a). APK size grows by ~100 MB.
  - **Desktop (Windows/macOS/Linux)**: pinned yt-dlp binary
    (`2026.10.26`) downloaded once into the app data dir on first use,
    SHA-256 verified. Linux needs a system `python3 >= 3.11`.
  - Downloads prefer `bestaudio[ext=m4a]` with a best-audio fallback;
    the real stream format is preserved and imported as-is.
  - Playlist listing uses `--dump-json --flat-playlist` so track order,
    titles and channel names come straight from YouTube.
  - Cancellation kills the underlying yt-dlp process (Android) or process
    group (desktop); temp directories are cleaned up on failure.
  - The Settings → Diagnostics "Test YouTube connection" now exercises the
    real download path (it lists a public video through yt-dlp).

## 0.3.3

### Fixes
- **YouTube 400 errors**: the resolver now rotates through known-good
  Android client versions with backoff when YouTube rejects a request
  (HTTP 400 is how YouTube's edge servers signal a stale client version),
  remembers whichever version works for the session, and surfaces
  YouTube's own error message (e.g. "HTTP 400: Precondition check
  failed.") instead of a bare status code.

## 0.3.2

### New features
- **YouTube downloads**: paste a YouTube video or playlist link on the
  Downloads screen and the app resolves the highest-quality directly
  downloadable audio stream (m4a preferred) and queues it for download.
  Playlist URLs queue every track (up to 200); each track's stream URL is
  resolved fresh at download time so expiring stream links never rot.
- Downloads are now **content-validated**: files whose bytes aren't a
  recognized audio format (e.g. a saved web page) are rejected instead of
  registered as unplayable music.

### Notes
- YouTube access uses YouTube's public innertube endpoints (Android client)
  without an API key. It only works for videos/playlists that are playable
  without sign-in, and stream links are subject to YouTube's terms of
  service — downloaded files remain your responsibility.

## 0.3.1

### New features
- **M3U/M3U8 playlist downloads**: paste a playlist URL on the Downloads
  screen and every track is queued as an individual download (titles and
  artists read from `#EXTINF` tags, relative URLs resolved against the
  playlist location, nested playlists skipped, 200-track cap).

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
