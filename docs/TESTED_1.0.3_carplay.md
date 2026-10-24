# Musify 1.0.3 test report: CarPlay (CarPlay Simulator + iPhone 12 mini)

Status: **done** (2026-10-23)

## 1. How it was tested

- Commit: `60b016d` (main, after `e604116`), `pubspec.yaml` `1.0.3+4`
- Flutter 3.47.2 stable
- Server: musify.fatmachines.com (key not recorded)
- Test library: ffmpeg-generated, Michael Jackson / Queen names (details below)
- Target: **CarPlay Simulator.app** (Xcode additional tools) on macOS 26.3, wired to a real **iPhone 12 mini, iOS 27.0.1** running a release build of Musify (`flutter build ios --release`). Phone driven with a throwaway XCUITest step runner kept outside the repo; car driven by mouse in the simulator window.

## 2. Summary

| # | Severity | Area | Title |
|---|---|---|---|
| C0 | Major | Recently Played | A playlist started on the phone is not recorded; the one before it is (one behind) |
| C1 | Minor | Covers | Folder with only `cover.jpg` shows a grey folder glyph (cover.jpg never read; same as macOS M3) |
| C2 | Polish | Add to playlist | Row still says "0 songs" right after ticking it |
| C3 | Polish | Download | Confirmation is the full raw YouTube title, the folder name is cut off ("to B…"), and it's a modal that stays until OK |
| C4 | Polish | Tag | "YouTube songs can be tagged once downl…" is cut off |
| C5 | Polish | Long lists | Rows first draw without an image slot, then jump when the placeholder arrives |
| C6 | Info | Long lists | Native side silently caps rows at `CPListTemplate.maximumItemCount` |

## 3. Bug details

### C0. Recently Played is one playlist behind

- **Steps:** fresh install, add folder. On the phone open **Thriller**, tap Billie Jean. Open Musify in CarPlay → Recently Played. Then on the phone open **Queen**, tap Bohemian Rhapsody; car: Home → Recently Played.
- **Expected:** after Thriller: "Thriller". After Queen: "Queen, Thriller".
- **Actual:** after Thriller: "Nothing here yet" (Home's cover row falls back to library folders). After Queen: only "Thriller". The playlist being played is never listed until you start another one.
- **Cause:** `lib/services/car_play.dart:67-72` calls `_notePlayed()` from `handler.mediaItem.listen`, and `_notePlayed` reads `PlayerService.instance.current`. In `player_service.dart` `play…` awaits `player.setAudioSources(...)` (which already emits the new media item) and only afterwards sets `_loaded = Playlist(...)` (`player_service.dart:387`). So `_notePlayed` sees the previous playlist (or null on first play). Fix: note the playlist where `_loaded` is set, or listen to a "playlist changed" signal instead of the media item.
- **Note:** a playlist started **from the car** (Big Archive) did show up first right away, so the miss is on the phone-start path (or depends on how many media-item updates follow).
- **Device:** iPhone 12 mini iOS 27.0.1 + CarPlay Simulator.

### C1. `cover.jpg`-only folder has no cover in the car

- **Steps:** Your Library / Download to / Home: look at `Queen Greatest Hits` (MP3s without embedded art + `cover.jpg`).
- **Expected:** the folder's `cover.jpg`.
- **Actual:** generic grey folder glyph. Same root cause as macOS **M3** (`grep -rn "cover\.jpg" lib` is empty).

### C2. "0 songs" after adding from the car

- **Steps:** play a song, Now Playing → **+** → tap `Gym` (empty playlist).
- **Expected:** tick and "1 song".
- **Actual:** tick appears, subtitle still "0 songs". Your Library shows "1 song" after going back, and the phone shows the song in Gym, so only that row is stale. Cause: `AppDelegate.swift` `tick(_:_:)` only changes the accessory, not the detail text.

### C3. Download confirmation too long

- **Steps:** play a YouTube chart song, Now Playing → download → pick `Bad`.
- **Expected:** a short confirmation ("Downloading to Bad").
- **Actual:** a full-screen alert "Downloading <entire YouTube title with | ARJN | KDS | …> to B…", folder name cut off; it stays until **OK** is pressed. The download itself worked (song landed in `Bad`, last in order).

### C4. Tag message cut off

- **Steps:** YouTube song playing → Now Playing → tag button.
- **Actual:** "YouTube songs can be tagged once downl…" (one-line list header truncates). Use a shorter text ("Download it to tag it") or put the rest in the detail line.

### C5. Long list rows jump

- **Steps:** Your Library → Big Archive (1,100 songs, no embedded art).
- **Actual:** opens in under a second (good), first rows show title only, ~2 s later every row gains a placeholder image and the text shifts right.

### C6. Silent cap on list length (risk, not confirmed)

- `ios/Runner/AppDelegate.swift:549` `entries.prefix(CPListTemplate.maximumItemCount)`. The cap is set by the car; on head units with a small limit, big folders lose songs with no "more" row. I scrolled to row 57 of 1,100 with the chevrons (drag doesn't scroll in the simulator) and did not reach the end, so the actual cap here is unknown.

## 4. What passed

- **Opens without crashing** with Musify running on the phone (the 1.0.3 headline fix).
- Tabs Home, Recently Played, Your Library, Spotify-style. CarPlay's Now Playing button (top right) appears while playing and shows the current cover.
- Home: "Good evening >" over a row of covers, then Pinned, Your playlists (Liked Songs heart on its gradient), Your folders. Tapping the greeting opens Recently Played; tapping a cover opens that playlist.
- **Not running:** killed Musify on the phone, opened it in the car: "Open Musify on your iPhone / Your music shows here once it's running". Opening the app on the phone filled the car in by itself within ~4 s. No crash.
- **Recently Played** survives an app restart (killed and reopened, list kept).
- **Your Library:** Playlists (Liked Songs + own), Folders, Tags. A tag with 0 songs is hidden; after tagging a song it appears ("To replace • 1 song") in its colour.
- **Covers:** folder covers from embedded art, own playlist uses its songs' cover, tag tile in tag colour, song covers in song lists.
- **Playlist page:** Shuffle row, then songs; tapping a song plays it with the rest after it and opens Now Playing (cover, title/artist/album, controls, progress).
- **Queue:** "Next from: Thriller" listing the rest; tapping Human Nature jumped to it.
- **+ (add to playlist):** with no playlists: "Make a playlist in Musify on your iPhone first". With Gym: tick on tap; phone's Gym shows the song.
- **Tag:** lists existing tags, tap ticks; YouTube song: message (cut off, C4).
- **Download:** own file: "This song is already on your iPhone". YouTube song: folders listed with paths, tapping one downloads (file appeared in the folder within ~25 s, last in order).
- **Live updates:** creating Gym, pinning Queen and renaming Gym → "Gym Mix" on the phone all showed in the car within about a second.
- **Long list:** Big Archive (1,100) opens in under a second and scrolls; a song from row 54 plays.

## 5. Not tested and why

- **Real head unit / wireless CarPlay:** only the CarPlay Simulator (wired).
- **Siri in the car**, steering-wheel buttons: simulator hardware buttons not exercised.
- **Download with no server set:** server stayed connected for the session.
- **Car with the big-folder hang (iOS I0):** the car stopped responding at the same time as the phone; not investigated separately.
- **Repeat/shuffle from car Now Playing:** system template here showed no shuffle/repeat buttons; not checked further.
- Screenshots are kept out of the report because the YouTube chart song in Now Playing isn't Michael Jackson/Queen material.

## 6. Left behind on device

See `TESTED_1.0.3_ios.md` §6 (same phone).
