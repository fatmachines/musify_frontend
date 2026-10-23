# Musify 1.0.3: test handoff

You are testing Musify 1.0.3 for the person who builds it. Your report
goes back to the builder (another Claude), who fixes what you find. Use
real devices and simulators where you have them, the plan in
`docs/TESTING.md`, and write a report at the end.

## What to test

- **Repo:** `git@github.com:fatmachines/musify_frontend.git`, branch
  `main`, at or after `e604116 Soft rounded shuffle, repeat and share
  icons`.
- **Version:** `pubspec.yaml` says `1.0.3+4`.
- **Server:** `https://musify.fatmachines.com`. Take the key from an
  installed Musify's settings (Settings → Musify server) or ask the
  person. Never write the key into the report or any file.
- **Plan:** `docs/TESTING.md` (whole app), plus the focus list below.

## Where to test

Whatever you can reach of these, and say which you used:

| Target | Notes |
|---|---|
| Android phone | `flutter run --profile`, driven over adb. |
| iPhone simulator + **CarPlay** simulator | Xcode simulator, then I/O → External Displays → CarPlay. CarPlay is new in 1.0.3. |
| macOS | `flutter run -d macos` (the `.dev` bundle ID, so the installed app is untouched). |
| Two devices for sync | Any two of the above in one sync group. |
| Tests | `flutter analyze` and `flutter test`, on Linux and on the Mac. |

Use a made-up test library (for example ffmpeg-generated files), with **Michael Jackson and Queen** names for anything that ends
up in screenshots. Include folders with covers, untagged files, a big
folder (1,000+ songs) and at least one `cover.jpg`-only folder.

## This is a fresh round

Test the whole app from scratch with `docs/TESTING.md`. There is no list
of earlier bugs to re-check: report everything you find as new.

## Focus: new in 1.0.3

### CarPlay (iPhone simulator + CarPlay simulator)

Before 1.0.3, opening Musify in CarPlay crashed. Now:

1. **Opens without crashing.** If Musify isn't running on the phone,
   the car may say "Open Musify on your iPhone"; after opening it, the
   car fills in by itself.
2. **Tabs:** Home, Recently Played, Your Library (Spotify-style).
3. **Home:** "Good morning/afternoon/evening" over a row of recent
   playlist covers (tap a cover opens it; tap the greeting goes to
   Recently Played), then Pinned, Your playlists, Your folders.
4. **Recently Played:** playlists played from car or phone, latest
   first; survives a restart.
5. **Your Library:** sections Playlists (with Liked Songs), Folders,
   Tags (only tags with songs).
6. **Covers:** playlist mosaic like the app, Liked Songs heart on its
   gradient, tags in their colour, song covers in song lists.
7. **A playlist:** Shuffle row, then songs; tapping a song plays it
   with the rest of the playlist after it and opens Now Playing.
8. **Now Playing:** system screen (cover, controls, progress). Check:
   - **Queue** (top right): "Next in queue" then "Next from: …"; tap
     jumps to that song.
   - **+ (add to playlist):** your own playlists, ticked if the song
     is in it; tap toggles add/remove. Check it on the phone after.
   - **Tag:** your existing tags, ticked if applied; tap toggles; can
     tap several. YouTube song: says it can be tagged once downloaded.
   - **Download:** YouTube songs only, folders listed (last used
     first); tap starts it with a short confirmation. Own file: says
     it's already on the iPhone. No server: says so.
   - CarPlay's own Now Playing button (top right of the tabs) appears
     while playing and opens this screen.
9. **Live updates:** rename/create a playlist or pin something on the
   phone: the car's lists update within about a second.
10. Long lists (1,000+ songs): opens in reasonable time, scrolls,
    covers fill in.

### Folder song order

Songs in a folder playlist are now in the order they were added
(oldest first, new ones last). Songs added together (within 2 minutes,
like an album copied at once) are in name order.

- Copy a new song into an existing folder, rescan: it's last.
- Download a YouTube song into a folder: it's last.
- Move a song into another folder (Move to folder): it's last there.
- Existing library copied in one go: name order, as before.
- Playlists you make: new songs were already added at the end; still are.

### Tags in Your Library

- Your tags are listed at the end of Your Library, each in its colour
  with its song count; tapping one opens its songs.
- In a tag's song list (from Your Library or Search), each song shows
  where it is after the artist: its folder, then any of your playlists
  holding it ("Artist • Folder, Gym").

### Icons

Shuffle, repeat (and repeat-one, with a "1"), and share use new soft,
rounded icons: phone full player, its ••• menu, the desktop player bar,
and the playlist Shuffle button. Check they're crisp, the same visual
size as their neighbours, coloured green when on, greyed when disabled
(desktop, nothing loaded), in light and dark themes.

## Not in this build (don't report as missing)

- A CarPlay search tab (CarPlay doesn't allow keyboard search for
  music apps; voice via Siri works).
- Detecting the car's mute (no API for it).

## The report

Write `TEST_REPORT_1.0.3.md`:

1. **How it was tested:** targets, commit tested, test library.
2. **Summary table:** new bugs numbered **C0, C1, …**, severity
   (Blocker, Major, Minor, Polish, Info as in `docs/TESTING.md`), area,
   one-line title.
3. **Details per bug:** steps, expected, actual, device, logs (shortest
   decisive lines), file:line if you found the cause.
4. **What passed**, **Not tested and why**, frame timings (Android
   profile build), anything left behind on the devices.

Rules:

- Don't change the app's code or push anything; report only. Throwaway
  test harnesses stay outside the repo.
- Screenshots only with Michael Jackson and Queen sample songs.
- No server key, personal names or emails in the report.
