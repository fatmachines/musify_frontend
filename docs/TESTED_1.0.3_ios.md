# Musify 1.0.3 test report: iOS (iPhone 12 mini, iOS 27.0.1)

Status: **done** (2026-10-23, round 2: full plan except the items the builder asked to skip)

## 1. How it was tested

- Commit: `60b016d` (main, after `e604116`), `pubspec.yaml` `1.0.3+4`
- Flutter 3.47.2 stable
- Server: musify.fatmachines.com (key not recorded)
- Test library: ffmpeg-generated, Michael Jackson / Queen names: Thriller (7 MP3, red cover), Bad (6 M4A, blue), Queen (4 FLAC + WAV + OGG + MP3 with lyrics), Mixed/Deep/Deeper (emoji title, 120-char accented title, untagged MP3, `notes.txt`, `photo.jpg`), Mixed/L1…/L6 (6 deep), Queen Greatest Hits (3 MP3 + `cover.jpg` only), Big Archive (1,100 × 4 s MP3, no art). Named songs 3 min each.
- Device: **iPhone 12 mini, iOS 27.0.1**, release build (`flutter build ios --release`, `com.fatmachines.musify`), installed fresh (Musify wasn't on the phone before).
- Music put on the phone through a throwaway helper app ("Test Music", file sharing on) and picked in Musify via Files → On My iPhone → Test Music → MusifyTest.
- Phone driven by a throwaway XCUITest step runner (outside the repo, screenshots per step). CarPlay results are in `TESTED_1.0.3_carplay.md`.

## 2. Summary

| # | Severity | Area | Title |
|---|---|---|---|
| I0 | Blocker | Playback | Playing the 1,100-song folder hangs the app: main thread blocked for minutes, process at iOS's 512 dispatch-thread limit |
| I1 | Major | CarPlay | Recently Played one behind (see `TESTED_1.0.3_carplay.md` C0) |
| I2 | Minor | Library | `cover.jpg`-only folder has no art (same as macOS M3) |
| I3 | Minor | Settings | No app version anywhere in Settings (the test plan's bug template relies on it) |
| I4 | Minor | Sync | The Mac shows up as an ISP reverse-DNS hostname instead of its name (see macOS M5) |
| I5 | Minor | Search | Artist card is listed above your own matching songs (plan: own songs first) |
| I7 | Info | Lyrics | Lyrics written by ffmpeg's `-metadata lyrics=` (a TXXX frame) aren't shown; only real USLT frames are |
| I8 | Info | Artist page | Own copies of an artist's songs had no green mark on the artist page (9.16) |
| I6 | Info | Siri | "Play Thriller on Musify" via XCUITest's Siri service did nothing visible; not conclusive |

## 3. Bug details

### I0. Big folder playback hangs the app (thread explosion in AVPlayer)

- **Steps:** add the library; play a song in **Big Archive** (1,100 songs, 4 s each) from the car or the phone with repeat all on; let it auto-advance (a couple of hundred songs in ~15 min); then tap anything.
- **Expected:** keeps playing, UI responsive.
- **Actual:** UI stops responding: XCUITest "Timed out while evaluating UI query", later taps never return (app never idles). The spindump taken by XCTest shows:
  ```
  Dispatch Thread Hard Limit Reached:  512  (too many dispatch threads blocked in synchronous operations)
  Num threads: 520   Footprint: 474.36 MB
  Thread … "com.apple.main-thread" … last ran 209.079s ago
    -[AudioPlayer concatenatingInsertAll:index:sources:shuffleOrder:]
      -[AudioPlayer enqueueFrom:]
        -[AVQueuePlayer insertItem:afterItem:]
          … -[AVPlayerItem _updateItemIdentifierForCoordinatedPlayback]
            _dispatch_sync_f_slow … (blocked by queue thread to be allocated)
  ~475 worker threads: -[AVPlayerItem _duration] ← _informObserversAboutAvailabilityOfDuration → itemasync_GetDuration → _dispatch_sync_f_slow
  ```
- **Cause (likely, not proven):** the whole folder goes to just_audio as one 1,100-item sequence (`lib/services/player_service.dart:273` `_sourcesAround` maps every track into a source; `setAudioSources` at `:379`). In the iOS plugin each source gets its own `AVPlayerItem` (`packages/just_audio/darwin/.../AudioPlayer.m`), and ~475 threads were parked in those items' duration observers. When the app then called `concatenatingInsertAll` → `enqueueFrom` on the main thread, `AVQueuePlayer insertItem:` needed one more GCD thread and there were none left, so the main thread waited for minutes. Fix ideas: hand just_audio a window of the folder (current ± a few dozen) and extend it as playback moves, or create player items lazily.
- **Does not recover:** a second spindump 15 minutes later still shows `Num threads: 520`, `Dispatch Thread Hard Limit Reached: 512`, footprint 477 MB; every UI query times out. Only killing the app helps. CarPlay stops responding at the same time.
- **Happens:** once in this session, after ~200 short songs. Not yet retried with 3-minute songs (it would take hours); the thread growth is per queued item, so a big library with normal songs is at risk too.
- **Device:** iPhone 12 mini, iOS 27.0.1, release build. Spindump kept locally (not attached; it contains the device's process list).

### I3. No version in Settings

- **Steps:** Settings, scroll to the bottom.
- **Expected:** "Musify 1.0.3 (4)" at the bottom (TESTING.md §1 and §15 ask testers to copy it from there).
- **Actual:** last row is "Copy debug log"; no version anywhere. `grep -n -i version lib/tabs/settings_tab.dart` is empty and `package_info_plus` isn't a dependency. Same on macOS.

### I5. Search order differs from the plan

- **Steps:** Search → type `Billie`.
- **Expected (TESTING.md 9.1):** your own matching songs first, then the artist, then YouTube songs.
- **Actual:** "Billie Eilish • Artist" card first, then own "Billie Jean • Song • Michael Jackson" (green mark), then the YouTube section. Either the plan or the order needs updating.

### I8. Own songs not marked on the artist page

- **Steps:** Search "Michael Jackson" → artist. Beat It, Human Nature, Thriller are in the library as files (tagged artist "Michael Jackson").
- **Expected (9.16):** those rows have the green mark and play from the file.
- **Actual:** no mark on any row. Likely because the test files are 3:00 sine waves and the match also looks at length; with real rips this may pass. Search for "Billie" did show the own "Billie Jean" first with its mark. Re-check with real files.

### I7. Lyrics only from USLT

- My first test file had lyrics in a TXXX "lyrics" frame (what `ffmpeg -metadata lyrics=` writes); `audio_metadata_reader` returns `lyrics=null`, so no lyrics card. After rewriting the file with a real USLT frame, the full player shows "Lyrics preview" (5.9 passes). Taggers like Mp3tag and Picard write USLT, so impact is small; worth knowing if users report missing lyrics.

## 4. What passed

- **Folder operations on the phone (3.8–3.15):** renamed `Queen/Classic` → `Live Aid` while one of its songs played: playback continued, the page renamed in place, the rename reached the Mac's disk. A name with `/` → "Folder names can't have / \ or : in them". Thriller → "Bad" → "There already is a "Bad" there". L6 ••• → Delete → dialog with Delete from device / Hide from Musify / Cancel; Hide removed it, Settings → Manage folders → Hidden playlists → Show brought it back; Delete from device removed it and its song (and the deletion reached the Mac). Song ••• → Delete from device asks "Delete "Radio Ga Ga (Live)"? … can't be undone", then the file is gone on both devices.
- **Downloads (10.1, 10.6):** two different YouTube songs named "Believer" into MacMix → `Believer.m4a` and `Believer (2).m4a`.
- **Player (5.3, 5.4, 5.9):** seek bar dragged and released at 1:54 kept playing from there with no jump back; swiping the big cover goes to the next song; lyrics preview card shows for a song with USLT lyrics.

- **Install / first launch (2.3):** fresh install opens to Home (pin hint + "Connect" card), no crash.
- **Rotation (2.5):** landscape adapts, nothing cut off (content area gets short under mini player + tab bar).
- **Add folder (3.1–3.3):** picker via Files; 7 folder playlists (Bad, Big Archive, Deeper, L6, Queen, Queen Greatest Hits, Thriller), folders with no songs of their own hidden; subtitles "Folder • Michael Jackson/Bad" or "Folder • 7 songs"; 1,100-song folder scanned in ~5 s.
- **Server (8.2):** right address + key → Charts appear.
- **Playback (5.1, 5.14):** tapping a song plays it; mini player appears. Killing and reopening restores the same song paused with its queue.
- **Full player icons:** shuffle, previous, play/pause, next, sleep timer; repeat (green with dot when on), share, queue: crisp and evenly sized in dark theme.
- **Playlists (4.1):** Create playlist "Gym" from the + sheet (name preselected, typing replaces it). Rename to "Gym Mix" from the long-press sheet.
- **Pins (4.8):** long-press Queen → Pin to Home → shows on Home.
- **Swipe left (4.5):** tag sheet opens; picking "To replace" puts an orange dot on the song; sheet stays open for more tags.
- **Swipe right (6.3):** "Added to queue" toast; queue sheet shows "Next in queue: Billie Jean" then "Next from: Big Archive".
- **Tags in Your Library (new):** "To replace • Tag • N songs" at the end, in its colour; tag page shows "Michael Jackson • Thriller, Gym Mix" (folder, then playlists).
- **Folder order (new):** a YouTube song downloaded into `Bad` from the car landed last (7 songs, new one at the end).
- **YouTube (9.2):** chart song starts within ~8 s.
- **Sync conflicts (12.20–12.26)**, phone offline via Control Center Wi-Fi toggle, Mac online, phone reconnects second:
  - 12.20 rename P to "Summer" (phone) vs "Drive" (Mac): phone asks "Playlist renamed on two devices" with both names and device; **Decide later** → killed and relaunched app → question shown again; Settings → Sync shows "1 to settle"; Sync screen card "“Summer” here, “Drive” on …" with **Choose**; picked Summer → both devices show Summer.
  - 12.21 rename "My playlist #5" → "Five" (phone) + Mac added a song: no question, both have "Five • 1 song".
  - 12.22 phone removed a song from Feel Good, Mac added another: no question, both 183 songs.
  - 12.23 phone deleted "My playlist #8", Mac added a song to it: playlist survived on both with the song.
  - 12.24 file renamed to `01 Bites Y.mp3` (phone, Files app) vs `01 Bites X.mp3` (Mac, Finder): "Song renamed on two devices" with both paths; picked Y → within ~1.5 min both devices have the song **once**, as `01 Bites Y.mp3`, no duplicate.
  - 12.25 folder `Queen/Live Aid 1985` → "Old" (phone, in app) vs "Classic" (Mac, Finder): **one** "Folder renamed on two devices" question for the folder ("3 songs" each), not one per song; picked Classic → both devices end with `Queen/Classic`, no `Old` left behind. The folder question came first, then the song question.
- **12.18 (folder disappears):** moved the 1,100-song `Big Archive` out of the Mac's synced folder (15:18). The phone **kept all 1,100** files (checked every 15 s for 5 min). The Mac's guard (`sync_service.dart:1568-1574`, "N synced songs are missing from … not deleting them") stops the delete. See M16 in the macOS report for what happened next.
- **File sync (12.13–12.17):** picked `MusifyTest` on both. Initial sync brought the two trees to identical (35 non-archive files each) and only sent what differed. 5 new songs added on the Mac in a new subfolder appeared on the phone in ~40 s; a Finder move + folder rename on the Mac reached the phone (after ~2.5 min, once "Sync now" was pressed on the Mac); a Finder delete reached the phone in ~1.5 min. Progress shows in a bar ("Downloading 1/1: Choo Lo.m4a 28%").
- **Sync (12.1–12.3, 12.5, 12.9–12.11)** with the Mac: code shown, Mac joins, "wants to sync" request on the phone, Approve → both list both devices; playlists flowed both ways (Gym Mix to the Mac, the Mac's playlists to the phone); "Playing on <Mac>" bar on the phone while the Mac played; pause on the phone paused the Mac within ~3 s; "Play here" continued on the phone from the same second.

## 5. Not tested and why

- **Skipped as asked by the builder:** AirPods/headphones (5.11), lock screen and Control Center playback (5.10, 5.13, 9.6), airplane mode during playback/download (8.3, 9.10, 10.5), Siri (5.16, I6).
- **Phone calls (5.12, 9.7):** no way to place a call to the test phone from here.
- **Spotify playlist under 100 songs (11.4):** only one Spotify link was given (207 items, tested as 11.5).
- **Download an imported playlist (11.8):** imports are 183/191 songs; would take an hour. Download playlist itself was tested on MacMix (10.3/10.4, macOS report).
- **Deny a join (12.3 Deny half), third device, devices offline for days:** only two devices.
- **12.12 (bar goes away after 10 min idle):** failed instead, see M10.
- **12.19 (200+ files at once):** not set up on purpose; but the phone's 1,100-file re-upload during 12.18 showed progress "Uploading 182/1100" and kept going without errors.
- **3.7 Manage folders → Remove:** not done on the phone so the synced folder stays intact; Hide/Show was done.
- **Stress (13.x):** only the accidental big-folder hang (I0). No 2-hour soak, no Network Link Conditioner.
- **Android:** later round, as asked. Frame timings are Android-only.
## 6. Left behind on device

- iPhone 12 mini: **Musify 1.0.3 release build** (`com.fatmachines.musify`) with the test library added, server address and key saved, sync still on (group of one: the Mac was removed at the end, 12.4), file sync on `MusifyTest`, imported playlists Feel Good + Travel, playlists Summer/Five/My playlist #8, pins, tags, downloads in `Bad` and `MacMix`. Shuffle on, repeat on.
- The phone may still be uploading Archive songs to the server from 12.18 (stops now that the Mac is out of the group, or delete the sync group on the server).
- **"Test Music"** helper app (`com.fatmachines.musifydriver`, holds `Documents/MusifyTest`, ~119 MB) and its XCUITest runner. Delete the app to remove the files.
- CarPlay Simulator still connected over USB. Phone Wi-Fi is back on.
