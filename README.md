# Audiobookshelf Plugin for Lyrion Music Server

Not finish at all - created by claude.

Browse and play audiobooks from your [Audiobookshelf](https://www.audiobookshelf.org/) server directly in [Lyrion Music Server](https://lyrion.org/) (formerly Logitech Media Server / Squeezebox).

## Features

- Browse your ABS libraries and books, of any library size (lists are paged from ABS as you scroll)
- Book lists sorted by title or by author, and an A–Z authors list
- Search across all book libraries: books, authors and series
- Play MP3 and M4B audiobooks
- Resume from saved position (pulls progress from ABS on resume)
- Bidirectional position sync (pushes playback position to ABS every 30 seconds)
- Works with multi-file audiobooks (chapters as separate files)

## Requirements

- Lyrion Music Server 8.0 or later
- **ffmpeg** installed on the LMS server (required for M4B/MP4 playback)
  - Debian/Ubuntu: `sudo apt install ffmpeg`
  - Fedora: `sudo dnf install ffmpeg`
- An Audiobookshelf server with API access

## Installation

1. In LMS, go to **Settings → Plugins**
2. Scroll to **Add a third-party repository** and enter:
   ```
   https://raw.githubusercontent.com/el-bernau/lms-audiobookshelf/main/extensions.xml
   ```
3. Click **Add** — "Audiobookshelf" will appear in the plugin list
4. Click **Install** and restart LMS when prompted

## Configuration

After installation, go to **Settings → Audiobookshelf**:

| Setting | Description |
|---------|-------------|
| Server URL | Your ABS server, e.g. `https://abs.example.com` |
| API Token | From ABS → Settings → Users → your user → API Token |
| Sync interval | How often (seconds) to push position to ABS (default: 30) |
| Auto-resume | Show a "Resume at X:XX" option when a book has saved progress |

## Usage

On any player, open **My Apps → Audiobookshelf**:

- **In Progress** — books you've started, sorted by most recent
- **Search** — searches every book library. Matching books come first, then matching authors and series (each opens their books). ABS matches books by title, subtitle, ISBN and ASIN, so search for an author's name to find their books.
- **Browse Libraries** — pick a library, then:
  - **All Books (by Title)**
  - **All Books (by Author)** — sorted by author last name, shown as "Author — Title"
  - **Authors** — A–Z by last name with book counts; open one to see their books

For each book you can choose **Resume (at X:XX)** or **Play from Start**. Individual chapter/file entries are also shown.

## Notes

- M4B files are transcoded to MP3 via ffmpeg (required because M4B containers typically have their index at the end of the file, which prevents direct streaming).
- MP3 files stream directly with byte-range seeking — no transcoding needed.
- Position is synced to ABS on pause, stop, and every N seconds while playing.

## License

MIT
