# Musify 1.0.3 test report: Android (Nothing Phone (3a) Lite, Android 16)

Status: **done except sync** (2026-10-24; see §5)

## 1. How it was tested

- Commit: `60b016d` (main, after `e604116`), `pubspec.yaml` `1.0.3+4`, Flutter 3.47.2
- Device: Nothing Phone (3a) Lite (model A001T), Android 16, 1080×2392, over wireless adb
- Build: `flutter build apk --profile` (debug-signed with this Mac's debug key, the same key the phone's existing 1.0.2 was signed with), installed with `adb install -r` **over the phone's 1.0.2**, so the update path with existing data is tested. A release-key APK was refused as an update (`INSTALL_FAILED_UPDATE_INCOMPATIBLE`) because that 1.0.2 was a debug build; `dist/Musify-1.0.2.apk`, `dist/Musify-1.0.3.apk` and a fresh release build all share the release certificate (`13ad498e…`), so real users of the release APK can update.
- Server: musify.fatmachines.com (key not recorded)
- Test library: same ffmpeg-generated Michael Jackson / Queen set as the iOS/macOS rounds, pushed to `/sdcard/Music/MusifyMJQ` (the phone already had an older test library in `MusifyTest` and `MusifyBig` from the 1.0.2 round)
- Driven over adb (`input tap/swipe/text`, `screencap`, `uiautomator dump`)

## 2. Summary

| # | Severity | Area | Title |
|---|---|---|---|
| A0 | Blocker | Playback | Playing the 1,100-song folder for a few minutes makes the app stop responding ("Musify isn't responding", ANR) |
| A4 | Blocker | Downloads | Every YouTube download fails on Android 11+: the `.m4a.part` temp file isn't allowed in `Music/` ("Operation not permitted") |
| A5 | Major | Files | Rename folder / Move / Delete from device fail on music the app didn't create (USB/adb copies): "Couldn't rename it: Rename failed", "Couldn't delete …" |
| A1 | Minor | Performance | Scrolling a 1,100-song folder runs at ~45 fps on a 90 Hz screen (Home: steady 90 fps) |
| A2 | Minor | Media session | Notification / media session shows the previous playlist as the album |
| A3 | Minor | Library | Two added folders with the same subfolder path give identical rows ("Deeper • Mixed/Deep/Deeper" twice) |
| A6 | Polish | Queue | After a restart the queue sheet shows file names / "Unknown artist" until reopened |
| A7 | Info | Android Auto | Not testable here: the SDK's Desktop Head Unit (2.0, 2022) stays on "Waiting for phone…" with Android Auto 17.9 |

## 3. Bug details

### A0. ANR after a few minutes in a big folder

- **Steps:** add the library; Your Library → Big Archive (1,100 songs, 4 s each) → Play; skip a lot and/or let it auto-advance ~10 minutes; press Back.
- **Expected:** keeps playing, Back works.
- **Actual:** "Musify isn't responding — Close app / Wait". Wait → it comes back; the process sat at 115 % CPU. Close app + reopen works and restores the song paused.
- **ANR record (`dumpsys dropbox data_app_anr`):**
  ```
  Subject: Input dispatching timed out (… MainActivity is not responding. Waited 5000ms for KeyEvent).
  "main" prio=5 tid=1 Native  state=R  utm=7060 stm=533
    native: #02 … pthread_cond_wait
    native: #03-#29 … base.apk (libflutter / libapp, unsymbolized)
  ```
  There is no separate `1.ui` thread: Dart runs on the Android main thread, so a busy Dart isolate blocks input. 70 s of main-thread CPU in about 8 minutes of playback.
- **Measured:** main-thread CPU for 20 skips: **282 ticks (2.8 s) in the 1,100-song folder vs 86 ticks in a 1-song folder** (about 50 of those 86 are just idle playback over the same time). So each song change costs about 8× more in a big folder.
- **Likely cause:** `lib/services/audio_handler.dart:42-45` `sequenceStateStream.map(sequence).distinct().listen(_publishQueue)`: `distinct()` compares the list by identity, and `_publishQueue` (`:145-150`) rebuilds 1,100 `MediaItem`s and pushes them through audio_service to the Android media session on every emission (each index change). Together with the full-folder `setAudioSources` (iOS I0), big folders get expensive per song. Fix ideas: publish the queue only when its contents change (compare lengths/ids), or publish a window around the current song.
- **150 fast skips alone are fine:** 150 × media-next 0.25 s apart landed exactly on Archive Track 151, threads 107 → 123, PSS 356 → 364 MB. It's sustained playback plus input that trips it.

### A4. Downloads always fail on Android (`.part` file)

- **Steps:** Search "Believer" → a YouTube result ••• → Download → pick a folder (here `MusifyTest/Artist A/Album 1`).
- **Expected:** song saved in the folder with tags and cover.
- **Actual:** "1/1 downloading… Believer 0% → 65%", then the bar disappears and a toast says:
  ```
  Cannot open file, path = '/storage/emulated/0/Music/MusifyTest/Artist A/Album 1/Believer.m4a.part' (OS Error: Operation not permitted, errno = 1)
  ```
  No file anywhere on the phone (`find /sdcard -iname '*Believer*'` is empty). The folder sheet said "Last used", and no `.m4a` from an earlier download exists on the phone, so this already failed in the 1.0.2 round.
- **Cause:** `lib/services/musify_server.dart:399` writes to `'${file.path}.part'`. Under Android 11+ scoped storage, an app without all-files access may only create files with media extensions in `Music/`, so `Believer.m4a.part` is refused. Fix: use a temp name that keeps the audio extension (e.g. `Believer.part.m4a` or `.Believer.m4a`) or download into the app cache and copy, or go through MediaStore.
- **Same pattern in file sync:** `lib/services/sync_service.dart:1804` (`'${target.path}.part'`), so songs coming from other devices can't be written either (see §5 for why this wasn't run end-to-end).

### A5. Rename / move / delete on existing music fail

- **Steps:** a folder of songs copied onto the phone (here with adb; same as copying over USB or from another app). Folder ••• → Rename folder → "Thriller 82" → Save. Song ••• → Delete from device → Delete.
- **Actual:** toasts "Couldn't rename it: Rename failed" and "Couldn't delete Thriller"; nothing changes on disk. Before the toast was caught, Save looked like it did nothing.
- **Cause:** the manifest only has `READ_MEDIA_AUDIO` (and `READ_EXTERNAL_STORAGE` ≤ SDK 32); on Android 11+ an app can only rename/delete files it created itself unless it has all-files access or asks per file through MediaStore (`createDeleteRequest` / `createWriteRequest`). `appops`: `MANAGE_EXTERNAL_STORAGE: default; rejectTime=…`. Downloads (A4) would be the app's own files, but they fail first.
- Affects 3.9–3.15 and file sync deletes/renames from other devices.

### A1. Big folder scroll frame rate

- Measured with `dumpsys SurfaceFlinger --latency` on the Flutter SurfaceView (gfxinfo sees 0 frames for Flutter). Panel vsync 11.1 ms (90 Hz). See §6.

### A2. Album in the media notification is the previous playlist

- **Steps:** play Big Archive, then open L7 and play its only song "Seven Deep" (no album tag).
- **Actual:** `dumpsys media_session`: `description=Seven Deep, Deep Artist, Big Archive`.
- **Cause:** `audio_handler.dart` `_item` falls back to `_service.current?.name`, which is still the previous playlist when the new media item is published: the same ordering problem as CarPlay C0 (`player_service.dart:387` sets `_loaded` after `setAudioSources`).

### A6. Queue sheet shows file names after restart

- **Steps:** queue 2 songs, force-stop the app, reopen, full player → Queue.
- **Actual:** queue kept (good) but rows read "02 Beat It • Unknown artist", "05 Human Nature • Unknown artist"; closing and reopening the sheet 10 s later shows the right titles. The sheet doesn't rebuild when `MetadataService.loadInfo` finishes.

### A7. Android Auto

- Installed `extras;google;auto` (Desktop Head Unit 2.0-mac-arm64, build 2022-03-30), turned on Android Auto developer mode, started the head unit server, `adb forward tcp:5277`. DHU logs `Connecting over ADB to localhost:5277... connected.` but its window stays "Waiting for phone…" and `screenshot` says "Don't have video focus". Probably the old DHU against Android Auto 17.9.664044. Needs a newer DHU or a real car. Android Auto developer mode was turned off again afterwards.
- What could be checked without the car: the media session Musify gives Android Auto (title/artist/album, Like and Tag custom actions) is correct apart from A2.

### A3. Same-named folders look identical

- **Steps:** add two music folders that both contain `Mixed/Deep/Deeper` (here the phone's older `MusifyTest` and the new `MusifyMJQ`).
- **Actual:** two rows "Deeper • Folder • Mixed/Deep/Deeper", no way to tell which top folder each is in. Show the top folder's name when paths collide.

## 4. What passed

- **Update 1.0.2 → 1.0.3 (3.17, 2.4):** in-place update kept playlists, likes, pins, server, the paused song; cold start 992 ms, 847 ms after a kill.
- **Add folder (3.1, 3.4):** + → Add folder → Android folder picker → "Allow Musify to access folder?" → Allow; the new folder's 9 playlists joined the old ones within ~6 s, including the 1,100-song one.
- **Playback + Android media session (5.1, 5.10 notification part):** media notification with cover, title, seek bar, previous/next, **♥ and tag buttons**; ♥ in the notification liked the song (Liked Songs 1 → 2); next skipped. Media session exposes `Like` and `Tag To replace` custom actions.
- **Hardware media keys:** 150 × KEYCODE_MEDIA_NEXT handled exactly.
- **Rotation (2.5):** landscape adapts, nothing cut off (only ~2.5 rows visible above mini player + tabs, like iPhone).
- **Back key:** from a folder page → Your Library; from a tab → Home.
- **Queue (6.1, 6.2, 6.3, 6.5, 6.9):** Play next Beat It, Play next Billie Jean, Add to queue Human Nature → "Next in queue: Billie Jean, Beat It, Human Nature"; swipe right → "Added to queue"; queue survives a force-stop and plays first after starting another playlist.
- **Tags (4.5, 4.7, new Tags in Your Library):** swipe left opens the tag sheet; "To replace" adds the tag and the folder shows "All / To replace" chips; Your Library lists "To replace • Tag • 1 song"; its page shows "Beat It • Michael Jackson • Thriller".
- **Equalizer (5.15):** "Uses your phone's built-in equalizer", 5 bands (60 Hz–14 kHz), presets apply (Rock), and `dumpsys media.audio_flinger` shows the system Equalizer effect attached while playing.
- **Spotify import (11.4/11.5):** "Finding its songs on YouTube Music: about half a minute for 200 songs" → "Imported 191 songs. Not on YouTube: … and 1 more" in 31 s (same as macOS).
- **YouTube playback (9.2):** chart/import song starts in ~3 s and plays steadily (0:26 → 0:31 in 5 s). The media notification for a YouTube song shows ♥ but no tag button (correct: YouTube songs can't be tagged).
- **Sync join (12.2):** Settings → Sync → Join → code → "Waiting for approval".

## 5. Not tested and why

- **Sync (12.x) on Android:** Android sent a join request to the iPhone's group, but the iPhone mini dropped off USB at that moment (`devicectl`: unavailable), so it was never approved. Library sync, file sync and conflicts need the iPhone back (or the Mac in the group). File sync will very likely hit A4 (`.part` in `sync_service.dart:1804`).
- **Android Auto (5.17):** see A7.
- **Skipped as asked:** headphones, lock screen, airplane mode, voice assistant.
- **Phone calls (5.12):** no second phone.
- **Shared Dart code already covered on iOS/macOS** (theme, sleep timer, lyrics, wrong server key, conflicts UI): not repeated on Android for time.
- **Downloads (10.x) and folder rename/move/delete (3.9–3.15):** blocked by A4/A5.

## 6. Frame timings

Profile build, measured with `dumpsys SurfaceFlinger --latency` on Musify's Flutter `SurfaceView` (`dumpsys gfxinfo` reports 0 frames because Flutter draws on its own surface). Panel: 90 Hz (11.1 ms vsync).

| Screen / action | Frames | p50 | p90 | p99 | Max | Frames over 2 vsyncs |
|---|---|---|---|---|---|---|
| Home, fling up/down ×8 | 127 | 11.0 ms | 11.1 ms | 11.2 ms | 55 ms | 2 / 126 |
| Big Archive (1,100 songs), fling ×8 | 127 | 22.1 ms | 33.2 ms | 33.2 ms | 33 ms | 32 / 126 |

Cold start (`am start -W`, TotalTime): 992 ms after the update, 847 ms and 965 ms after force-stops. Memory while playing the 1,100-song folder: PSS 356 → 364 MB after 150 skips; threads 102 → 123.

## 7. Left behind on device

- Musify **1.0.3 profile build** (debug key) installed over the old 1.0.2 debug build; its existing data kept (older test library `MusifyTest`/`MusifyBig`, playlists, server key).
- New test library `/sdcard/Music/MusifyMJQ` (~125 MB), added as a music folder. Imported playlist "Travel". Tag on "Beat It". Equalizer on, preset Rock.
- **A pending sync join request** to the iPhone's group (Settings → Sync shows "Waiting for approval"; Cancel to drop it).
- Android Auto: developer mode turned off again, head unit server stopped. On the Mac: Desktop Head Unit installed under `~/Library/Android/sdk/extras/google/auto`.
- Auto-rotate restored. Phone was muted the whole time.
