# Musify 1.0.3 test report: macOS (this Mac, macOS 26.3)

Status: **done** (2026-10-23, round 2)

## 1. How it was tested

- Commit: `60b016d` (main, after `e604116`), `pubspec.yaml` `1.0.3+4`
- Flutter 3.47.2 stable
- Server: musify.fatmachines.com (key not recorded)
- Test library: ffmpeg-generated, Michael Jackson / Queen names, in `~/Music/MusifyTest` (same set as iPhone: Thriller/Bad/Queen with covers, Deeper with emoji + long accented title + untagged + `notes.txt`/`photo.jpg`, 6-deep folder, `cover.jpg`-only folder, 1,100-song Big Archive). First pass used 30 s songs, then regenerated at 3 min.
- Target: this Mac (macOS 26.3), `flutter run -d macos` debug build (`com.fatmachines.musify.dev`); the installed `/Applications/Musify.app` was left alone.
- The `.dev` container already had data from earlier runs (playlists MacMix, My playlist #1/#5/#8, Top 100 Songs Global, All Out 80s, tag "To replace"), so "first launch" was not a clean first launch.
- Driven with `cliclick` + window screenshots by window id.

## 2. Summary

| # | Severity | Area | Title |
|---|---|---|---|
| M0 | Major (debug) | Server dialog | Escape in Musify server dialog with text typed: red error screen, app unusable |
| M1 | Minor | Server dialog | Wrong server address shows raw `ClientException with SocketException…` text |
| M3 | Minor | Library | Folder with only a `cover.jpg` shows no art (cover.jpg is never read) |
| M4 | Minor | Library | Changed song files keep old tags, length and cover until the app restarts, even after Rescan |
| M5 | Minor | Sync | Mac's device name is `Platform.localHostname`, which here is an ISP reverse-DNS name, not the computer name |
| M6 | Minor | Settings | No app version shown in Settings (same as iOS I3) |
| M7 | Polish | Light theme | "Playing on iPhone" green text on the mustard mini player is hard to read |
| M8 | Polish | Move to folder | The song's current folder is offered as a target |
| M9 | Major | Sync / Downloads | Downloading an own playlist on one device turns it into a folder there and deletes the playlist on the other devices |
| M10 | Minor | Sync | "Playing on <other device>" shows on both devices while neither is playing (stale presence) |
| M11 | Minor | Import | A link to a playlist that doesn't exist says "Couldn't read it: the server answered 502" |
| M12 | Minor | Import | Spotify playlist of 207 items gave 191 songs; message lists only 4 as not found (12 unaccounted) |
| M13 | Minor | YouTube | First play of a new YouTube song jumped ~15 s ahead at the stand-in → stream switch (1 of 3 songs) |
| M14 | Polish | Desktop | YouTube song menu says "Save to a folder on this phone" on a Mac; no right-click menu on rows |
| M15 | Polish | Downloads | `Darasal (From "Raabta").m4a` saved as `Darasal (From Raabta ).m4a` (quotes stripped, stray space) |
| M16 | Minor | Sync files | Folder disappearing on the Mac: nothing deleted (good), but no visible message, and the iPhone starts re-uploading all 1,100 songs to the server |
| M2 | Minor | Tests | 23 of 75 `flutter test` cases fail when run on a Mac |

## 3. Bug details

### M0. Escape in server dialog: "TextEditingController was used after being disposed"

- **Steps:** Home → Charts → **Connect** → click the Key field → type `abc` → press **Escape**.
- **Expected:** dialog closes, nothing else happens.
- **Actual:** red error screen filling the window; app unusable until restart. Also hit once with Enter-to-save flow while typing.
- **Happens:** every time with Escape (3/3). Cancel button and clicking outside: no error.
- **Log:**
  ```
  A TextEditingController was used after being disposed.
  TextField:file:///…/lib/widgets/server_key_dialog.dart:96:11
  Another exception was thrown: 'package:flutter/src/widgets/framework.dart': Failed assertion: line 6281 pos 12: '_dependents.isEmpty': is not true.
  ```
- **Cause:** `lib/widgets/server_key_dialog.dart:19-20` disposes `url` and `key` controllers as soon as `showDialog` returns, but the dialog's closing animation still builds both `TextField`s. Fix: own the controllers inside `_ServerDialogState` (create in `initState`, dispose in `dispose`).
- **Device:** macOS 26.3, debug `.dev` build. Release builds skip these asserts, so impact there is likely smaller, but the controller is still used after dispose.

### M1. Wrong address: raw exception text

- **Steps:** Connect → address `https://musify.fatmacnhines.com` (typo) → any key → Save.
- **Expected:** "Couldn't connect" with a plain reason ("Can't find that server").
- **Actual:** `Couldn't connect: ClientException with SocketException: Failed host lookup: '…' (OS Error: nodename nor servname provided, or not known, errno = 8), uri=…/health`
- **Cause:** `server_key_dialog.dart:65` shows `$e` as is.
- Wrong **key** with right address is fine: "Couldn't connect: the Musify server key is wrong".

### M3. `cover.jpg` folder art is ignored

- **Steps:** folder `Queen Greatest Hits/` with 3 MP3s that have no embedded art plus `cover.jpg` (600×600). Add the parent folder.
- **Expected:** the folder tile, header and songs use `cover.jpg` (common for ripped albums; the handoff asks for a `cover.jpg`-only folder).
- **Actual:** grey placeholder note icon everywhere (library row, folder header, song rows).
- **Cause:** nothing in `lib/` looks for `cover.jpg` / `folder.jpg` (`grep -rn "cover\.jpg" lib` is empty). Covers come only from embedded tags (`metadata_service.dart` `_readCover`).
- Same on iPhone and CarPlay (shared code).

### M4. Stale tags, length and cover after a file changes

- **Steps:** add folder, let it scan. Outside the app, replace `Thriller/01 Billie Jean.mp3` etc. with new files of the same name (here: 30 s files replaced by 3 min ones). Settings → **Rescan**.
- **Expected:** new length (and new tags/cover if changed).
- **Actual:** Thriller still says "8 songs • 6m" (should be ~24m). The song playing shows `0:30` total while the file is 3:00.
- **Cause:** `lib/services/metadata_service.dart:34-35` `_info` and `_covers` are keyed by `track.path` for the app's lifetime; `loadInfo` skips any path already in `_info`, and rescan never clears it. Re-tagging a song in another app and pressing Rescan shows old tags too. Fix: key on path + mtime/size, or drop entries for changed files on rescan.

### M5. Sync shows the Mac as an ISP hostname

- **Steps:** iPhone: Settings → Sync → Turn on sync. Mac: Sync → Join with the code.
- **Expected:** "<computer name> wants to sync" (the name in System Settings → General → Sharing).
- **Actual:** the request, the device list on both sides and the "Playing on …" bar show a reverse-DNS name of the Mac's public address (an ISP hostname, redacted here). Long, meaningless to the user, and it leaks the network address to other group members.
- **Cause:** `lib/services/sync_service.dart:184-185` `deviceName` uses `Platform.localHostname`, which on macOS returns the DHCP/reverse-DNS host name when one is set. Use the computer name (`scutil --get ComputerName` / `Host.current().localizedName` via the existing method channel) on macOS.

### M7. Low contrast "Playing on iPhone" in light theme

- **Steps:** Light theme, play on the iPhone, narrow the Mac window (phone layout).
- **Actual:** the mini player background takes the cover's mustard colour and the subtitle is green on it; hard to read. The green bar under it is fine.

### M8. Move to folder lists the current folder

- **Steps:** song in `Deeper` → ••• → Move to folder.
- **Actual:** `Deeper` is in the list (and highlighted). Picking it would be a no-op; leave it out or disable it.

### M9. Download playlist removes the playlist on other devices

- **Steps:** sync Mac + iPhone (library only). Mac: own playlist `MacMix` with 2 YouTube songs, pinned → ••• → Download playlist → MusifyTest.
- **Expected (10.4):** on the Mac it becomes a folder and stays pinned (it did). Other devices keep the playlist (and get the folder if file sync is on).
- **Actual:** the iPhone's `MacMix` playlist disappeared at the next sync, while file sync was off, so the phone had neither the playlist nor the folder: its 2 songs were gone from the phone's library. After file sync was turned on later, the folder arrived. Users who sync only the library lose the playlist on their other devices.

### M10. Stale "Playing on …" on both devices

- **Steps:** play on the Mac, "Play here" on the iPhone, pause the iPhone, wait a few minutes (phone went offline for a while in between).
- **Actual:** the Mac shows "Playing on iPhone" and the iPhone shows "Playing on <Mac>" at the same time, both paused, for 10+ minutes. Expected: no bar when nothing plays (12.12).

### M11. Unknown playlist → "server answered 502"

- **Steps:** Import → `https://www.youtube.com/playlist?list=PLzzzz…` (made up).
- **Expected (11.6):** "No songs in it" / "isn't a playlist".
- **Actual:** `Couldn't read it: the server answered 502`. Plain text gives the right "That isn't a playlist link".

### M12. Spotify import count

- **Steps:** Import the given Spotify playlist (Spotify page says "207 items").
- **Actual:** "Imported 191 songs. Not on YouTube: <3 titles> and 1 more". 207 − 191 − 4 = 12 not mentioned (maybe duplicates or local/unavailable tracks in the source; the message should say so). The first 12 songs match Spotify's order and artists exactly (11.7 pass). The YouTube Music playlist imported as "Feel Good", 183 songs.

### M13. Jump at stand-in → stream switch

- **Steps:** play a never-played YouTube song (Travel → "Choo Lo").
- **Actual:** 0:01, 0:03, then the bar reset to 0:00 / "0:00" length for a moment, then 0:20, 0:23 three seconds later: about 15 s of the song were skipped. Next two new songs switched cleanly. Expected (9.2): a small blip only.

### M16. 12.18: guard works, but silently, and triggers a full re-upload

- **Steps:** file sync on (Mac + iPhone, `MusifyTest`). On the Mac, move `Big Archive` (1,100 of ~1,135 songs) out of the folder (stand-in for an unplugged disk).
- **Good:** the iPhone kept all 1,100 files (checked every 15 s for 5 min). Cause: `sync_service.dart:1568-1574` throws `SyncFailed("N synced songs are missing from … not deleting them on your other devices")`.
- **Not good:**
  1. The guard's text only surfaces as a sync failure on the Mac's Sync screen; the plan expects "with a message". I could not see a dialog or toast (Mac window was behind the tester's video; not re-checked).
  2. The iPhone immediately began **"Uploading 1/1100… Archive Track …"** to the server and was at 182/1100 after 4 minutes, because the server now sees the Mac lacking them. The Mac never downloaded them back (still 0 after 11 min, as its own sync keeps failing at the guard), so this is server space and phone bandwidth spent for nothing, and if the disk is gone for good the Mac would refill the folder on the internal disk once the guard is cleared.
- Folder moved back afterwards.

### M2. `flutter test` on a Mac: 23 failures

- `flutter analyze`: no issues. `flutter test`: `+52 ~1 -23`.
- Failing files: `library_test.dart` (16), `voice_play_test.dart` (4), `playlist_download_test.dart`, `swipe_tag_test.dart`, `swipe_test.dart`, `find_shortcut_test.dart`.
- **Log:** `[Musify] restoreAll: native call failed: MissingPluginException(No implementation found for method restoreAll on channel musify/folder_access)` then `Expected: ['musify_lib_…', 'Pop', 'Rock'] Actual: []`.
- **Cause:** `lib/services/folder_access.dart:32` picks the native path with `Platform.isIOS || Platform.isMacOS`. Under `flutter test` on a Mac host, `Platform.isMacOS` is true, so tests go to a method channel that has no handler. On Linux they take the plain-path branch. Fix: mock the channel in tests, or gate on a test override.

## 4. What passed

- **Import (11.1–11.3, 11.5–11.7):** copied link is prefilled; YouTube Music playlist → "Feel Good", 183 songs; Spotify (207 items) → "Travel", 191 songs, all > 100, "Finding its songs on YouTube Music…" shown; first 12 songs match Spotify order and artists; plain text → "That isn't a playlist link".
- **YouTube on Mac (9.2–9.5, 9.8, 9.9):** new song starts in ~2 s; 5 fast skips settle on a playing song; seek to the middle plays from there; song end → next with no gap (2:57 → 0:00 of the next).
- **Likes (4.4), playlists (4.2):** like from the menu → Liked Songs 1; adding a song already in a playlist shows it ticked (no duplicate); one add per sheet open with a toast.
- **Downloads (10.1–10.4):** MacMix (pinned, 2 YouTube songs) → Download playlist → MusifyTest: progress bar "1/2 downloading… Choo Lo 72%", files written with title/artist/album and cover, green marks, and MacMix became a folder that stayed pinned on Home.
- **Equalizer (5.15):** toggle on, Bass Booster curve, dragging the 4K band gives "Custom", toggle off. (Sound change not judged by ear.)
- **Sleep timer (5.8):** list 5 min … End of track; End of track stopped at the end of the song (next song loaded paused), timer icon green while set.
- **Sync conflicts and files with the iPhone (12.13–12.26):** see `TESTED_1.0.3_ios.md` §4. Finder changes on the Mac (add 5 songs, move, rename folder, delete, rename file) all reached the phone.

- `flutter analyze`: no issues.
- **Server (8.1, 8.2):** wrong key → "Couldn't connect: the Musify server key is wrong", old settings kept; right key → Charts.
- **Add folder (3.1–3.3):** NSOpenPanel, 7 playlists, empty parents hidden, 1,100-song folder scanned in < 4 s; untagged song shows its file name and "Unknown artist"; `.txt`/`.jpg` skipped; emoji and long accented titles render.
- **Rescan (3.5):** new `00 Heal the World.mp3` copied in after 2 min appears **last** in Thriller although its name sorts first (folder order, new in 1.0.3).
- **Move to folder (3.13):** moved the playing song from Deeper to Bad: file moved on disk, playback kept going, song is **last** in Bad (new in 1.0.3).
- **Playback (5.1, 5.2, 5.7):** play, next, repeat all wraps a folder.
- **Queue (6.1, 6.2, 6.4):** Play next X, Play next Y, Add to queue Z → "Next in queue: Y, X, Z"; queued songs play once and leave; queue sheet updates live.
- **Mac only:** Space toggles play/pause (7.2); ⌘F opens "Find on this page" (7.3); volume button mutes/unmutes (7.4, media keys not tried); wide layout = sidebar + top search + player bar, narrow = phone tabs, no broken state in between (7.1); quit with ⌘Q and reopen keeps folders readable, settings and pins (7.5).
- **Appearance (5.18):** Light switches instantly everywhere; desktop player bar icons (shuffle, previous, play, next, repeat green when on) look crisp in both themes.
- **Sync with iPhone (12.1–12.3, 12.5, 12.9–12.11):** see `TESTED_1.0.3_ios.md`; Mac side: joined, saw the phone's "Gym Mix", showed "Playing on iPhone" with Play here, paused when the phone pressed pause.

## 5. Not tested and why

- **Clean first launch / .dmg install (2.1, 2.3):** used `flutter run` on the existing `.dev` container (moving it aside was not allowed in this session), and no `.dmg` was built.
- **Folder rename/hide/delete in the Mac app (3.7–3.12, 3.14, 3.15):** done on the iPhone instead (same Dart code; results in the iOS report) because the Mac was in use by the tester for part of the session.
- **Disabled icons with nothing loaded:** the dev container always restored a song.
- **Media keys (7.4):** volume slider tested (and left at ~1% for the tester); hardware media keys not pressed.
- **USB drive, Finder rename while app open, 1,000+ scroll smoothness:** not reached (12.18 used a folder move instead of a USB drive).
## 6. Left behind on device

- `~/Music/MusifyTest` (test library, ~125 MB) changed by the tests: MacMix folder (3 YouTube downloads + 2 Believers), `Queen/Live Aid` (2 songs), `Queen Greatest Hits/01 Bites Y.mp3` (renamed), L6 deleted, `Queen/07 Don't Stop Me Now.mp3` re-tagged with USLT lyrics (lost its cover).
- `.dev` app container: folder MusifyTest added, server address + key saved, Light theme, equalizer off, volume ~1%, imported Feel Good + Travel, removed from the sync group by the iPhone (12.4).
- The `.dev` Musify is still running (launched with `open`).
- `build/macos` and `build/ios` from the builds (not committed). No changes to the repo's source.
- CarPlay Simulator app left open.
