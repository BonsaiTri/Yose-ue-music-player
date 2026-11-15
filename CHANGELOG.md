# Changelog

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
