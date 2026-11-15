# Changelog

## 0.3.21 (2026-11-15)

### Added
- **"Suggest an available version" for dead downloads.** When a YouTube
  download fails because the source video is gone (removed, private, or
  Premium-only), the History list now offers a one-tap action that searches
  YouTube for other available uploads of the same song. Tap one of the
  suggested versions to queue it for download.

## 0.3.20 (2026-11-15)

### Improved
- **Failed downloads that can never succeed are now recognized.**
  "Retry all failed" previously re-ran dead videos (removed/privated) and
  Premium-only videos over and over. Those failures are now classified as
  permanent: bulk retry skips them and reports the skip count ("Retried 3
  failed downloads — skipped 41 dead videos"), and the History list marks
  them with "dead source, will not be retried".

### Notes
- The usual batch of failing downloads is on YouTube's side: most are
  removed/privated videos ("Video unavailable") and occasional
  YouTube Music Premium exclusives. Nothing the app can do about those.

## 0.3.19 (2026-11-15)

### Added
- **Duplicate cleanup in the Library.** The Library screen now has a
  "Find duplicates" button (the fact-check icon in the top bar). It scans
  the whole library and groups tracks that are the same song — same
  normalized title + artist, or identical file contents (same hash),
  including copies like "Song (Official Video)" vs "Song". For each group
  you can pick which copy to keep (the most-played one is preselected, or
  any copy) and delete the extra copies along with their audio files —
  per group or all at once. The library list refreshes when you go back.

## 0.3.18 (2026-11-15)

### Fixed
- **Duplicate downloads were still slipping through.** The old check
  compared exact URL strings, so the same video in a different format
  (`youtu.be/…`, extra parameters) or a *different upload* of a song you
  already own was downloaded again. Duplicate detection now:
  - compares YouTube URLs in canonical form (video id / playlist id), and
  - checks the library by song title + artist (titles normalized, so
    "Song (Official Video)" matches "Song").

  Already-owned songs are now refused with a clear message, and playlist
  downloads skip them.

## 0.3.17 (2026-11-15)

### Fixed
- **Downloads died when the app went to the background.** Android's
  low-memory killer was reaping the yt-dlp worker processes while the app
  was backgrounded. The app now runs a `dataSync` foreground service
  (with a small “Downloading tracks…” notification) while downloads are
  active, keeping the whole process group alive. The notification
  disappears when the queue finishes.

## 0.3.16 (2026-11-15)

### Fixed
- **Home page could crash with “Infinity or NaN toInt”.** The browse grid
  inside the home page's scroll view had an unbounded main axis; it is now
  shrink-wrapped so its scroll offset can never go out of range.

### Added
- **Interrupted downloads recover automatically.** Tasks that were
  mid-download when the app was closed or crashed are re-queued on next
  start (and their leftover temp files are cleaned up) instead of being
  stuck “in progress” forever.

## 0.3.15 (2026-11-15)

### Added
- **Download progress bars.** In-progress tasks show a determinate bar with
  percentage, downloaded size and speed; waiting queue tasks show an
  indeterminate bar.

### Fixed
- **YouTube downloads failing with “No address associated with hostname”.**
  The Python runtime bundled in the AAR can lose system DNS resolution
  inside the app sandbox even when the device itself resolves fine. The
  pinned yt-dlp script now falls back to DNS-over-HTTPS (Google/Cloudflare)
  whenever the built-in resolver fails for a hostname, so YouTube
  downloads and searches keep working in that state.

## 0.3.14 (2026-11-15)

### Added
- **Retry all failed downloads.** The History section in the Downloads
  screen now has a one-tap "retry all" button (shown whenever at least one
  task has failed) that re-queues every failed task at once; individual
  retry buttons are unchanged.

## 0.3.13 (2026-11-15)

### Added
- **Album art on the lock screen.** The media notification now shows the
  current track's artwork as its large icon (resolved from the library's
  stored artwork files; falls back to the app icon when a track has none).

## 0.3.12 (2026-11-15)

### Added
- **Previous-track button in the mini player.** The mini player bar now has
  previous / play-pause / next, matching the full Now Playing screen.

## 0.3.11 (2026-11-15)

### Fixed
- **Lock screen controls still missing (second root cause).** AGP 9's release
  resource shrinking was stripping the `audio_service` control icons from
  the APK because they are only referenced at runtime (invisible to the
  shrinker). The icon lookup returned 0 and Android threw
  "You must specify an icon resource id", silently killing the media
  notification. The icons are now declared as public resources so they
  survive the build.

## 0.3.10 (2026-11-15)

### Fixed
- **Lock screen / media controls missing on Android.** The media notification
  (play/pause/next on the lock screen and status bar) was silently dropped
  because Android 13+ requires the `POST_NOTIFICATIONS` permission, which
  the app never requested. The app now asks for it the first time you press
  play — grant it and controls appear immediately. (No-op on older
  Android, which grants it automatically.)

## 0.3.9 (2026-11-15)

### Added
- **Downloads build playlists.** Downloading a playlist (YouTube playlist
  or M3U/M3U8 link) now creates a **playlist in the app named after the
  source** — and every track that finishes downloading is added to it
  automatically. Re-downloading the same source reuses the existing
  playlist instead of creating a duplicate. Single-video downloads are
  unaffected.
- **Shuffle play for playlists.**
  - **Playlists tab:** long-press a playlist → **Shuffle play**.
  - **Playlist detail:** a shuffle button next to Play all.
- **New playlist from Home.** The Home screen has a **New playlist** button
  next to Play all / Shuffle, so you can create a playlist without leaving
  the hub.

## 0.3.8 (2026-11-15)

### Changed
- **Simpler navigation.** The bottom bar / sidebar now has five tabs:
  **Home, Library, Playlists, Downloads, Settings**.
  - **Library and Search are merged** — the Library screen has a Library
    / Search tab switcher, so searching your music is one tap away from
    browsing it.
  - **Playlists is a primary tab** — all your playlists are visible without
    going through Home first.

## 0.3.7 (2026-11-15)

### Added
- **Downloads screen revamp.**
  - **Link and YouTube are now tabs** — switch between pasting a direct
    link/M3U/YouTube URL and searching YouTube from one screen.
  - **After you queue a download, the screen returns to the queue/history**
    so you can immediately see your task's progress.
- **Search diagnostics** — the YouTube search flow now logs each step
  (query, raw output size, parsed entry count, failures) to make issues
  easier to diagnose.

## 0.3.6 (2026-11-15)

### Added
- **Full playlist experience.**
  - **Create, rename, and delete playlists** — long-press a playlist for the
    play / rename / delete menu; the track count shows on each row.
  - **Playlist detail page** — open a playlist to browse its tracks:
    - **Sort** by title, artist, album, date added, or play count (the
      manual order is untouched — switching back restores it).
    - **Custom order**: drag tracks to rearrange them; the new order is
      saved.
    - **Add tracks** from a picker with search; tracks already in the
      playlist are hidden.
    - **Remove** a track from the playlist (the music stays in the library).
    - **Play all** or tap any track to start from it.
  - **Add to playlist from the Library** — every track row has a
    "playlist +" button that opens the playlist picker (also lets you
    create a new playlist on the spot).
- **New repository tests** for playlist add/remove/reorder/reindex
  behavior (5 tests).

### Fixed
- **Playlist reorder was a no-op.** The old implementation matched rows by
  index instead of by track id, so requesting a new order changed nothing.
  Positions are now written per track id and gaps are re-indexed.

## 0.3.5 (2026-11-14)

### Added
- **YouTube search on the Downloads screen.** Type a query, browse results
  with thumbnails, tap one to queue it.
- **Clear download history.** One-tap action removes all finished
  (completed/failed/cancelled) download records — queued and active
  downloads, and your music, are untouched.
- **Duplicate download prevention.** Re-queuing a URL that is already in
  your library is refused with a clear message. For playlists, tracks that
  are already downloaded are skipped and reported ("N already downloaded")
  instead of re-downloading hundreds of songs.

### Fixed
- **Missing album art / "Unknown Artist" on long playlists.** The engine no
  longer runs a second yt-dlp listing per track (YouTube rate-limited large
  queues). Title/artist now come from the listing taken when the queue was
  created, and the cover is fetched directly from YouTube's thumbnail
  endpoint — no extra process per track.
- **Mini player artwork now updates when you skip tracks.**
- **YouTube playlist listing for line-delimited JSON.** yt-dlp's modern
  playlist API emits one JSON object per line; the parser now handles
  NDJSON, top-level arrays, single objects, and `{"entries": [...]}`.
- **Messy link pastes.** Pasting a URL with extra text (newlines, JSON
  metadata, trailing words) no longer crashes with a raw
  `FormatException`; the first URL is extracted and validated.
- **Data location no longer orphans the library.** Changing the data
  location now migrates the database snapshot and all media to the new
  root, verifies sizes, and rolls back on failure. A custom location is
  only honored when it actually contains a database file.

## 0.3.4

### Added
- **Album art for YouTube downloads** — the thumbnail from the listing is
  stored as the track's artwork.

### Changed
- **YouTube downloads now use yt-dlp** instead of the built-in Innertube
  client, which YouTube's PO-token requirement had broken. On Android a
  bundled Python runtime provides yt-dlp; desktop downloads a pinned,
  SHA-256-verified standalone binary on first use.

## 0.3.3

### Added
- Download diagnostics (test button) in Settings.

### Fixed
- YouTube resolution client-version rotation.

## 0.3.2

### Added
- YouTube video and playlist downloads.
- Playlist (M3U/M3U8) download support.

## 0.3.1

### Changed
- UX overhaul: 5 primary tabs + Home hub.
- Renamed to "Yose-ue Music Player"; new logo.

## 0.3.0

### Added
- Initial release: offline-first library, import, playback, downloads,
  lifecycle handling, backups, diagnostics.
