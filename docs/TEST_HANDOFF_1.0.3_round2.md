# Musify 1.0.3, round 2: test handoff

You are testing fixes for the bugs found in the first 1.0.3 round, for the
person who builds Musify. Your report goes back to the builder (another
Claude), who fixes what you find. Use real devices and simulators where you
have them, and write a report at the end.

The first round's reports are in `docs/`: `TESTED_1.0.3_android.md` (A…),
`TESTED_1.0.3_ios.md` (I…), `TESTED_1.0.3_macos.md` (M…) and
`TESTED_1.0.3_carplay.md` (C…). Bug numbers below are theirs.

## What to test

- **Frontend:** `git@github.com:fatmachines/musify_frontend.git`, branch
  **`fix/test-report-1.0.3`** (not `main`), at its latest commit.
- **Version:** `pubspec.yaml` says `1.0.3+5`. Settings now shows it at the
  bottom: "Musify 1.0.3 (5)".
- **Backend:** `git@github.com:fatmachines/musify_backend.git`, branch
  `fix/test-report-1.0.3`. Some fixes (marked **server**) need it. Check
  whether `https://musify.fatmachines.com` runs it: importing a made-up
  YouTube playlist link should say "there's no public playlist or song at
  that link", not "502". If it doesn't, either run the branch yourself
  (`docker compose up`, see its README) or skip those items and say so.
- **Server key:** take it from an installed Musify's settings (Settings →
  Musify server) or ask the person. Never write the key into the report or
  any file.
- **Plan:** `docs/TESTING.md` for the steps it mentions.

## Where to test

The same as round 1: Android phone (profile build over adb), iPhone with
the CarPlay Simulator, the Mac (`flutter run -d macos`, `.dev` bundle), and
two devices for sync. Run `flutter analyze` and `flutter test` on Linux
**and on the Mac** (M2).

Use the same test library (ffmpeg-made, **Michael Jackson and Queen**
names), including the 1,100-song Big Archive and the `cover.jpg`-only
Queen Greatest Hits. On Android, also a folder copied over adb/USB (not
made by Musify).

## 1. Re-check every fix

For each, say **fixed**, **not fixed** (with what you saw) or **not
tested** (and why).

### Blockers

| Bug | What changed | How to check |
|---|---|---|
| I0, A0 | A big playlist goes to the player 50 songs ahead and 25 behind at a time, moved along as it plays, wrapping round with repeat-all. | iPhone and Android: play Big Archive with repeat all, let it auto-advance **20+ minutes** (a few hundred 4 s songs), skip a lot, then use the app. It must stay responsive. iPhone: thread count stays low (Instruments or a spindump; round 1 hit 512). Android: no ANR; main-thread CPU per skip in Big Archive close to a 1-song folder (round 1: 8×). |
| A4 | Downloads write to `Song.musify-part.m4a` while downloading (Android 11+ refused `.m4a.part` in `Music/`). | Android: download a YouTube song into a folder under `Music/`. It saves, with tags and cover, and no `*.musify-part.*` file is left. Also download a whole playlist. |
| A5 | On Android 11+, rename / move / delete first explains and opens "All files access"; below 11, write permission. | Android: on adb-copied music, Rename folder, Move to folder, Delete from device, Delete folder from device. First time: the explanation, then the system's All files access screen; after allowing, each works on disk. "Not now": nothing happens, no error. |

### Majors

| Bug | What changed | How to check |
|---|---|---|
| C0, I1, A2 | The playlist is set before its songs load. | CarPlay: play Thriller on the phone; Recently Played shows Thriller at once; then Queen: "Queen, Thriller". Android: `dumpsys media_session` album is the new playlist, not the previous one. |
| M0 | The server and import dialogs own their text fields. | Mac debug build: Connect → type in the Key field → **Escape**. No red screen. Same in Import playlist. |
| M9 | Download playlist only hides the playlist on the device that now has the folder; other devices keep it. | Two synced devices, library only: download an own playlist on one. It becomes a folder there (pin moves to it); on the other the playlist stays with its songs. |

### Minors and polish

| Bug | What changed | How to check |
|---|---|---|
| C1, I2, M3 | A song with no embedded cover uses its folder's `cover.jpg` (also `folder`, `front`, `album`, any case, `.jpg`/`.png`). | Queen Greatest Hits: cover in the library row, folder header, song rows, Now Playing, lock screen, CarPlay. |
| M4 | Files changed since they were read are read again on Rescan. | Replace or re-tag a song outside the app, Rescan: new length, tags, cover. |
| M5 | The Mac uses its computer name in sync, and sends it, so groups it's already in update too. | Sync the Mac and a phone: the phone lists the Mac by its System Settings name, also in "Playing on …". |
| I3, M6 | Version at the bottom of Settings. | "Musify 1.0.3 (5)" on each platform. |
| M2 | Under `flutter test`, folders don't go to the native side. | `flutter test` on the Mac: all pass. |
| I5 | Search: your songs, then the artist, then YouTube (as `TESTING.md` 9.1). | Search "Billie". |
| M1 | Plain connection errors. | Connect with a typo'd address: "can't find that server; check the address". |
| M11 **server** | A missing playlist answers 404 with a message (yt-dlp errors no longer 502). | Import a made-up YouTube playlist link. |
| M12 **server** | Spotify import counts repeats and items that aren't songs, and pages by items. | Import the same Spotify playlist (207 items): the toast accounts for every item (imported + not on YouTube + in it twice + not songs). |
| M10 | A device that can't reach the server stops showing "Playing on …" once the other device's last word is old. | Round 1's steps (Play here, pause, one device offline a while): no bar on either after 10 min idle (12.12). |
| M16 | Most of a folder missing: a message once ("N synced songs are missing from …"), and the device no longer reports itself as lacking them. | Repeat 12.18: the message appears on the Mac; the phone does **not** start uploading the 1,100 songs; nothing is deleted. |
| M13 | A YouTube song moving to the stream never starts past its stand-in. | Play 5 never-played YouTube songs: no jump of more than a second or two at the switch. |
| A1 | Covers are read on one long-lived isolate; a folder's picture looked for once. | Android profile: Big Archive fling ×8, frame timings as in round 1 (was p50 22 ms on a 90 Hz screen). |
| A3 | Same path in two music folders: the subtitle starts with the music folder's name. | Two added folders both with `Mixed/Deep/Deeper`. |
| A6 | The queue sheet reads songs' tags when opened. | Queue songs, force-stop, reopen, open the queue: titles and artists, not file names. |
| M7 | Light theme: "Playing on …" in the mini player is in the text colour. | Light theme, play on the other device. |
| M8 | Move to folder leaves out the song's own folder. | Song ••• → Move to folder. |
| M14 | "Save to a folder on this device"; right-click (Mac) or long-press on a song row opens its menu. | Mac: right-click a song in a playlist and in search. Phone: long-press. |
| M15 | Quotes in titles become `'` in file names, no stray spaces. | Download `Darasal (From "Raabta")`: `Darasal (From 'Raabta').m4a`. |
| C2 | Ticking a playlist from CarPlay updates its song count. | Now Playing → + → an empty playlist: "1 song" at once. |
| C3 | The download confirmation is short ("Downloading to Bad") and goes away by itself after about 2.5 s. | CarPlay download of a YouTube song. |
| C4 | Tagging a YouTube song from CarPlay says "Download it to tag it". | |
| C5 | Rows start with a plain tile, so they don't shift when covers arrive. | Open Big Archive in the car. |
| C6 | A list longer than the car allows ends with "N more" ("Shuffle plays them all"). | Scroll to the end of Big Archive in the car (or note the limit if you can't reach it). |

I7 (lyrics) is gone: Musify no longer shows lyrics, so don't test or
report them.

Not changed, as info only: A7 (Android Auto needs a newer head unit or a
real car), I6 (Siri), I8 (artist page
marks with sine-wave test files: re-check with real rips if you can).

## 2. Regressions to watch

The windowed queue (I0/A0) touches the queue's core. Re-run `TESTING.md`
§6 (queue) in full, plus:

- Repeat all at the end of a big folder wraps to its first song; repeat
  off stops at the last.
- Shuffle on and off in a big folder: each song once, current song and
  queued songs kept.
- Previous at the start of a big folder (repeat all): goes to its last
  song.
- Kill and reopen while in the middle of Big Archive: it comes back at the
  same song and position, and next/previous carry on through the **whole**
  folder (not just 75 songs).
- Rename the folder that's playing (3.10) while in Big Archive.
- Sync handoff ("Play here") of a song in Big Archive.
- CarPlay Queue and the queue sheet show the next songs ("Next from: …").
- Android Auto / notification: next and previous still work.

Also: downloads still land last in their folder (1.0.3's folder order), and
sync file transfers (12.13–12.17) still work, since they use the new
download file name too.

## 3. Then a quick full pass

If time allows, the rest of `docs/TESTING.md` on one phone and the Mac,
reporting anything new.

## The report

Write `TEST_REPORT_1.0.3_round2.md`:

1. **How it was tested:** targets, frontend and backend commits tested,
   whether the live server ran the backend branch, test library.
2. **Fix check:** a table of every bug above, fixed / not fixed / not
   tested, with a note.
3. **New bugs:** numbered **R0, R1, …**, severity (Blocker, Major, Minor,
   Polish, Info as in `docs/TESTING.md`), area, one-line title; then
   details per bug: steps, expected, actual, device, logs (shortest
   decisive lines), file:line if you found the cause.
4. **What passed**, **Not tested and why**, frame timings (Android profile
   build), anything left behind on the devices.

Rules:

- Don't change the app's code or push anything; report only. Throwaway
  test harnesses stay outside the repo.
- Screenshots only with Michael Jackson and Queen sample songs.
- No server key, personal names or emails in the report.
