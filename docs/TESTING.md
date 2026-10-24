# Musify test plan

For: whoever tests Musify 1.0.2 on iPhone, Mac and Android.
Goal: try every feature the way a real person would, then try to break it.

Musify is a Spotify-style player for **your own music files**. It also has
**optional** extras that need a Musify server: YouTube Music, downloads and
sync between devices. Test both halves.

---

## 1. Before you start

### What you need

- **Devices:** at least one iPhone and one Mac. An Android phone and a
  second iPhone or iPad help with sync testing.
- **The app:**
  - Mac: the `.dmg` from GitHub Releases. Open it and drag Musify into
    Applications.
  - Android: the `.apk` from GitHub Releases. Allow installing from your
    browser or Files when asked.
  - iPhone: installed for you by the team (via Xcode / TestFlight).
- **A Musify server:** ask the team for its **address** and **key**. Never
  share the key.
- **Music files:** 30 to 50 songs (MP3, M4A, FLAC, plus at least one WAV or
  OGG), in folders inside folders, for example:

  ```
  Music/
  ├── Artist A/
  │   ├── Album 1/   (5–10 songs)
  │   └── Album 2/   (5–10 songs)
  ├── Artist B/      (songs directly in here)
  └── Mixed/
      └── Deep/Deeper/  (2 songs, to test deep folders)
  ```

  Include a few awkward ones:
  - names with emoji, accents and long titles;
  - a song with no tags (no title or artist inside the file);
  - one non-music file (a `.txt` or `.jpg`).
- **Also have:** a public YouTube playlist link, a public YouTube Music
  playlist link, and two public Spotify playlist links (one under 100 songs,
  one over 100).

### How to report a bug

For every bug, collect this, using the template in section 15:

- the device, OS version and Musify version (Settings, at the bottom);
- the exact steps, numbered, starting from a known state;
- what you expected and what happened;
- a screen recording if anything moves, jumps or flickers;
- **the debug log:** Settings → **Copy debug log**, pasted into the report.
  Copy it right after the bug happens.

Rate each bug:
- **Blocker:** crashes, data loss, music files deleted wrongly, can't play
  at all.
- **Major:** a feature doesn't work.
- **Minor:** works, but wrong or ugly.
- **Polish:** small visual or wording issue.

---

## 2. Install and first launch

| # | Steps | Expected |
|---|---|---|
| 2.1 | Mac: open the `.dmg`, drag Musify to Applications, open it. | Opens with **no** "can't be checked for malware" warning. |
| 2.2 | Android: install the `.apk`, open it. | Installs; the splash screen, then the app. |
| 2.3 | First launch on each device. | Green splash, then an empty library inviting you to add a folder. No crash. |
| 2.4 | Close the app fully and reopen it. | It reopens fast, the same as before. |
| 2.5 | Turn the phone sideways (iPhone, Android). | The layout adapts; nothing is cut off. |

---

## 3. Library and folders (offline, no server needed)

Turn **Wi-Fi and mobile data off** for this whole section, to prove it works
offline.

| # | Steps | Expected |
|---|---|---|
| 3.1 | Your Library → **+** → **Add folder** → pick `Music`. | Each folder that holds songs becomes a playlist: Album 1, Album 2, Artist B, Deeper. Folders with no songs of their own (`Artist A`, `Mixed`) don't appear. |
| 3.2 | Look at each playlist's subtitle. | Shows "Folder" and where it is (e.g. `Artist A/Album 1`). |
| 3.3 | Open a folder playlist. | Songs show with title, artist and cover from their tags. The untagged song shows its file name. The `.txt` and `.jpg` don't appear. A folder whose songs have no cover of their own but a `cover.jpg` (or `folder.jpg`) shows that picture. |
| 3.4 | Add a second, separate folder (e.g. from iCloud Drive, or another disk on Mac). | Its playlists join the library. |
| 3.5 | Outside the app (Files / Finder), add a song to a folder, then pull down in Your Library. | The new song appears. |
| 3.6 | Outside the app, delete a song, then pull down. | It disappears, including from any playlist it was in. |
| 3.7 | Settings → **Manage folders** → remove a folder. | Its playlists disappear. **The files on disk are untouched** (check in Files / Finder). |
| 3.8 | Folder ••• → **Delete** → **Hide from Musify**. Then Settings → Manage folders → unhide it. | It disappears, then comes back. |
| 3.9 | Folder ••• → **Rename folder** → a new name. | Renamed in the app **and on disk**. The songs stay in Liked Songs and your playlists. **Android 11+:** the first time, Musify explains and opens "All files access"; after allowing it, renaming, moving and deleting work on songs copied over USB too. |
| 3.10 | Rename a folder while one of its songs is playing. | The music keeps playing without stopping. |
| 3.11 | Rename a folder to a name that already exists next to it, or a name with `/` in it. | Refused, with a clear message; nothing changes. |
| 3.12 | Try to rename a top-level folder you added in 3.1. | Refused, with a message telling you to rename it in Files / Finder. |
| 3.13 | Song ••• → **Move to folder** → another folder. | The file moves on disk and stays in your playlists and likes. |
| 3.14 | Song ••• → **Delete from device**. | Asks first; then the file is gone from disk and from every playlist. |
| 3.15 | Folder ••• → **Delete** → choose to delete the songs. | Asks first; the songs are deleted, other files in that folder are kept. |
| 3.16 | Close and reopen the app. | The folders are still there; nothing to add again. |
| 3.17 | iPhone: reinstall the app (or update it) and reopen. | Folders reconnect, or the app clearly asks you to add them again. No crash. |

**Edge cases to try:**
- A folder with 1,000+ songs: how long does it take to load, and does it stay smooth?
- Folders 6+ levels deep.
- A song or folder with an emoji or a very long name.
- Mac: add a folder on a USB drive, then unplug the drive.
- iPhone: an iCloud Drive folder whose files aren't downloaded yet.
- Rename a folder in Finder **while the app is open**.

---

## 4. Playlists, likes, tags, pins

| # | Steps | Expected |
|---|---|---|
| 4.1 | **+** → **Create playlist**, name it. | An empty playlist opens. |
| 4.2 | Add songs from 3 different folders (song ••• → Add to playlist). | All appear. Adding the same song twice doesn't duplicate it. |
| 4.3 | Playlist ••• → Rename, then Delete. | Works. Deleting asks first and **doesn't delete any files**. |
| 4.4 | Like songs (♥). Open Liked Songs. | Newest likes at the top. |
| 4.5 | **Swipe a song left.** | The tag sheet opens; pick "To replace". A coloured dot appears on the song. |
| 4.6 | Swipe the tagged song left again. | Its tag is removed (a message says so). |
| 4.7 | Open the tag's chip at the top of a playlist / the tag playlist. | Shows only songs with that tag. |
| 4.8 | Pin playlists, folders, Liked Songs and a tag to Home (••• → Pin to Home). | They show on Home in the order pinned. Unpin works. |
| 4.9 | In a long playlist: **Find on this page** (Mac: ⌘F). | Filters the songs as you type. |

---

## 5. Playing music (use your own files first)

| # | Steps | Expected |
|---|---|---|
| 5.1 | Tap a song. | It plays. The mini player appears at the bottom. |
| 5.2 | Play / pause, next, previous in the mini player and the full player. | Works. Previous restarts the song if it's a few seconds in. |
| 5.3 | **Drag the seek bar** slowly and quickly, and let go. | The bar follows your finger with **no jumping back**, and the song continues from where you let go. |
| 5.4 | **Swipe the mini player** sideways, and the big cover in the full player. | Next / previous song, like Spotify. |
| 5.5 | Drag the mini player up; drag the full player down. | Opens / closes smoothly. |
| 5.6 | Shuffle on and off while playing. | The current song keeps playing; the order of the rest changes. |
| 5.6b | Turn shuffle **on**, fully close the app, reopen, start any playlist (play button or tap a song). | Shuffle is still on and the playlist plays shuffled. Turning it off is remembered the same way. |
| 5.7 | Repeat: tap through all → one → off. | Repeat one replays the song; repeat all goes from the last song back to the first; off stops at the end. |
| 5.8 | **Sleep timer:** 5 minutes, then "End of track". | The music stops when it should. The countdown shows. |
| 5.10 | **Lock screen / Control Center:** play, pause, skip, seek. | All work. The right title and cover show. |
| 5.11 | Pull headphones out / take AirPods out. | The music pauses. |
| 5.12 | **Get a phone call** while playing (or start a voice memo or another music app). After the call, press play. | Pauses for the call; plays again after. |
| 5.13 | Lock the phone and let 3–4 songs play through. | It keeps playing song after song. |
| 5.14 | Fully close the app while playing, then reopen. | The same song comes back **paused** where it was, with its queue. |
| 5.15 | **Equalizer** (Settings): turn it on, pick presets, drag the bands. | The sound changes right away. Off gives the original sound. |
| 5.16 | iPhone: Siri, "Play Album 1 on Musify". | Plays that playlist. |
| 5.17 | In a car: CarPlay or Android Auto. | Now Playing shows and controls work. CarPlay: tabs Home, Recently Played, Your Library. Home shows the greeting over recent covers, then Pinned, playlists, folders; Now Playing opens from CarPlay's button top right. A playlist shows Shuffle and its songs; a song plays and opens Now Playing. Now Playing: Queue lists what's next (tap jumps); the + button adds to/removes from a playlist (ticked if in it); the tag button lists your tags, tapping one tags or untags; the download button (YouTube songs) lists folders and starts the download. Renaming a playlist on the phone updates the car within a second. |
| 5.18 | Settings → Appearance: Light, Dark, Same as this device. Then change the phone's own setting. | Switches instantly, everywhere, including open screens. |

---

## 6. The queue (compare with Spotify)

This must behave **exactly like Spotify**. Write down any difference.

| # | Steps | Expected |
|---|---|---|
| 6.1 | Playing song A from a playlist: on song X ••• → **Play next**, then on Y → Play next. | Queue (full player → queue icon): **Next in queue: Y, X**. The last one you picked plays first. |
| 6.2 | Then on Z ••• → **Add to queue**. | Z goes **after** Y and X, before the rest of the playlist. |
| 6.3 | **Swipe a song right** (anywhere: folder, playlist, search). | It's added to the queue, with a small vibration and a message. |
| 6.4 | Skip through the queue. | Each queued song plays **once**, then leaves the queue. |
| 6.5 | With songs queued, start a **different playlist**. | The queued songs are still queued and play first. |
| 6.6 | With songs queued, turn shuffle on / off. | The queue stays in order; only "Next from: playlist" is shuffled. |
| 6.7 | Queue sheet → **Clear queue**. | Only the queued songs go; the playlist continues. |
| 6.8 | Tap a song in the queue sheet. | It jumps to that song. |
| 6.9 | Close and reopen the app with songs queued. | The queue is still there. |

---

## 7. Mac only

| # | Steps | Expected |
|---|---|---|
| 7.1 | Make the window wide, then narrow. | Wide: sidebar + top search + player bar. Narrow: phone-style tabs. No broken layout in between. |
| 7.2 | Press **Space**. | Play / pause, unless you're typing in a search box. |
| 7.3 | ⌘F on a playlist. | "Find on this page" opens. |
| 7.4 | Volume slider in the player bar; the keyboard's media keys. | Both work. |
| 7.5 | Quit and reopen. | Folders still readable (no asking again), same song paused. |

---

## 8. Connect the server

| # | Steps | Expected |
|---|---|---|
| 8.1 | Settings → **Musify server** → a wrong address or a wrong key. | "Couldn't connect" with a reason; the old settings are kept. |
| 8.2 | Enter the right address and key. | "Connected"; Home shows the **Charts**. |
| 8.3 | Turn the internet off and open Home / Search. | A clear message, no endless spinner, no crash. Your own music still plays. |

---

## 9. YouTube Music (server needed)

| # | Steps | Expected |
|---|---|---|
| 9.1 | Search a song name. | Your own matching songs first, then the artist (if it's a name), then YouTube Music songs. |
| 9.2 | Play a YouTube song **you've never played before**. | It starts within a few seconds. **A small blip a few seconds in is expected** (it moves from YouTube's player to the server's stream). |
| 9.3 | Play the same song again later. | Starts at once. |
| 9.4 | Play a YouTube playlist (a chart, an artist). Let 3 songs end by themselves. | Each next song starts with **no gap**. |
| 9.5 | Same as 9.4 with **shuffle on**. | Same: no gap. |
| 9.6 | **Lock the phone** while a YouTube song plays; let it reach the next song. | The next song plays with the screen locked. *(This was a past bug; test it well.)* |
| 9.7 | YouTube song playing → take a phone call → after the call, press play in Control Center. | It plays again. *(Past bug.)* |
| 9.8 | Skip quickly 5 times through YouTube songs. | Each starts; nothing gets stuck playing silence with the seek bar moving. |
| 9.9 | Seek within a YouTube song. | Jumps there and plays. |
| 9.10 | Turn on airplane mode in the middle of a YouTube song. | It plays what it already loaded, then stops calmly. Turning the internet back on and pressing play recovers. |
| 9.11 | Open an **artist** (from search or a song). | Albums row + all songs. Pin button (📌) pins the artist to Home; tapping it there opens the artist. |
| 9.12 | Open an album. | Its songs. |
| 9.13 | Open each chart on Home. | Up to 100 songs each. |
| 9.14 | Add YouTube songs to your own playlists, like them, queue them. | Same as your own files. |
| 9.15 | **A YouTube song you already have as a file** (search for one of your own songs). | It shows the **green downloaded mark** and plays from your file (works in airplane mode). |
| 9.16 | Open an artist where some of their songs are on your device. | Those songs have the green mark; the others don't. Playing the artist mixes both. |

**Look out for:**
- a YouTube song that never starts;
- silence while the seek bar moves;
- the wrong song playing;
- any ads.

---

## 10. Downloads (server needed)

| # | Steps | Expected |
|---|---|---|
| 10.1 | YouTube song ••• → **Download** → pick a folder. | Progress shows; then the song is in that folder with title, artist and cover, and has the green mark everywhere. |
| 10.2 | The downloaded song's ••• menu. | Says "Downloaded", not "Download". |
| 10.3 | A chart / artist ••• → **Download playlist**. | Downloads one at a time with progress ("3/40"). Songs you already have are skipped. |
| 10.4 | One of **your own** playlists that has YouTube songs → Download playlist. | When everything is downloaded, the playlist becomes a folder (and stays pinned if it was pinned). |
| 10.5 | Turn the internet off in the middle of a download. | It fails for those songs with a message; nothing half-written stays in the folder. |
| 10.6 | Download two songs with the same title. | Both are kept ("Title (2)"). |

---

## 11. Import a playlist (server needed)

Your Library → **+** → **Import playlist**.

| # | Steps | Expected |
|---|---|---|
| 11.1 | Copy a YouTube playlist link, then open Import. | The link is already filled in. |
| 11.2 | Import a YouTube playlist. | A new playlist with the same name and songs. A message: "Imported N songs (M already on this device)". |
| 11.3 | Import a YouTube Music playlist link. | Same. |
| 11.4 | Import a **Spotify** playlist with under 100 songs. | Takes a few seconds ("Finding its songs on YouTube Music…"); then the playlist. Songs that weren't found are named in the message. |
| 11.5 | Import a **Spotify** playlist with **more than 100 songs** (e.g. 200). | **All** songs are imported, not just 100. Count them. |
| 11.6 | A private / deleted playlist, a random link, plain text. | A clear message ("isn't a playlist link" / "No songs in it"). Nothing is created. |
| 11.7 | Spot-check 10 songs from a Spotify import. | Same song, same artist (a remastered or live version now and then is acceptable; note it). |
| 11.8 | Download an imported playlist (••• → Download playlist). | Works like 10.4. |

---

## 12. Sync between devices (server needed)

Use **two devices** (A = iPhone, B = Mac); a third device is a bonus.

### 12a. Joining

| # | Steps | Expected |
|---|---|---|
| 12.1 | A: Settings → Sync → **Turn on sync**. | Shows a code like `K7QM-4XPA`. |
| 12.2 | B: Settings → Sync → **Join** → type A's code. | B says "waiting for approval"; A shows "B wants to sync" with Approve / Deny. |
| 12.3 | A: Deny. Then try again and Approve. | Deny: B is told. Approve: both list both devices. |
| 12.4 | A: remove device B. | B leaves sync; its music and playlists stay on B. |

### 12b. Library

| # | Steps | Expected |
|---|---|---|
| 12.5 | A: create a playlist, like songs, add a tag, pin something. | Within a few seconds, all of it appears on B. |
| 12.6 | B: edit those. | Changes reach A. |
| 12.7 | Delete a playlist on A. | It goes from B too. |

### 12c. What's playing (handoff and remote control)

| # | Steps | Expected |
|---|---|---|
| 12.8 | Play on A, pause on A. Open B. | B shows the **same song at the same second**. Pressing play on B continues there. |
| 12.9 | Play on A. Look at B. | B shows a green **"Playing on (A's name)"** bar and A's play/pause state. |
| 12.10 | On B, press pause / next / seek. | **A** pauses / skips / seeks (within about 3 seconds). B stays silent. |
| 12.11 | On B, tap **Play here**. | A pauses; B continues from the same spot. |
| 12.12 | Both devices idle for 10+ minutes. | The "Playing on" bar goes away. |

### 12d. Music files

Settings → Sync → pick the **music folder** on **each** device.

| # | Steps | Expected |
|---|---|---|
| 12.13 | Add 5 songs to the folder on A (in Files / Finder). | They appear on B, in the same subfolders, without pressing anything (give it a minute). |
| 12.14 | Delete a song on B. | It's deleted on A. |
| 12.15 | Move a song to another subfolder on A. | Moved on B, not downloaded again. |
| 12.16 | Rename a folder on A (in the app or in Finder). | Renamed on B. No duplicate folder left behind. |
| 12.17 | B copies the same songs A already has (same files), then joins sync. | Nothing is uploaded or downloaded for those. |
| 12.18 | Make most of the folder **disappear** on A (e.g. unplug the disk it's on). | Sync refuses to delete those songs on B, with a message. **Nothing is deleted on B.** |
| 12.19 | Sync 200+ songs at once. | Progress shows ("Downloading 12/200"); finishes; no duplicates. |

### 12e. Conflicts (devices offline)

Put **both** devices in **airplane mode**, make the changes, then turn the
internet back on: first on one device, then on the other.

| # | Change on A | Change on B | Expected when both are back online |
|---|---|---|---|
| 12.20 | Rename playlist P to "Summer". | Rename the same playlist to "Drive". | The second device online asks **"Playlist renamed on two devices"**: pick one. Both end up with the choice. |
| 12.21 | Rename P. | Add songs to P. | **No question:** both the new name and the new songs are kept. |
| 12.22 | Add songs to P. | Remove other songs from P. | **No question:** all changes kept. |
| 12.23 | Delete P. | Edit P (add a song). | P survives with the edit. |
| 12.24 | Rename a song file to "X" (Finder). | Rename the same file to "Y". | A question with both names; afterwards the song exists **once**, with the chosen name, on both devices. |
| 12.25 | Rename a folder to "Old". | Rename the same folder to "Classic". | **One** question for the whole folder (not one per song). |
| 12.26 | Any conflict → **Decide later**. Close and reopen the app. | The conflict is still on the Sync screen ("Choose"); Settings shows "1 to settle". |

**Sync edge cases:**
- Three devices in one group.
- Turn the server off in the middle of a file sync.
- A device offline for days, then back online.
- Two devices adding the same new song at the same time.
- A song with the same path but **different content** on both devices.

---

## 13. Stress and stability

- Play continuously for 2+ hours with the screen off. Check: still playing, battery drain, phone not hot.
- Library of 2,000+ songs: start time, scrolling, search speed.
- Quickly tap around while things load (open/close the player, switch tabs, go back).
- Low storage on the phone while downloading.
- Slow network (iPhone: Settings → Developer → Network Link Conditioner, "3G").
- Kill the app during: a download, a file sync, a folder rename, an import.
  On reopening: nothing half-done or duplicated.

---

## 14. Known limits (not bugs)

- **iPhone app:** only available by building it with Xcode (no App Store).
- **CarPlay:** browsing needs Apple's CarPlay audio entitlement. Opened from the car with Musify not running, it asks to open Musify on the iPhone first.
- **First play of a YouTube song:** a short blip a few seconds in, when it switches to the server's stream.
- **Remote control:** about 3 seconds of delay. The idle device's lock-screen controls only control that device.
- **Top-level folders** you added can't be renamed in the app.
- **Song titles from YouTube** music-video playlists can include "(Official Video)".
- **Spotify import:** a few songs may not be on YouTube Music (they're listed). Occasionally a remastered or live version is picked.
- **Without a server:** no YouTube, charts, downloads, imports or sync. That's by design.

---

## 15. Bug report template

```
Title: <short, specific>

Severity: Blocker / Major / Minor / Polish
Device + OS: iPhone 15 Pro, iOS 26.1   (or Mac model + macOS / Android model)
Musify version: (Settings, at the bottom, e.g. 1.0.3 (5))
Server connected: yes / no      Sync on: yes / no

Steps:
1.
2.
3.

Expected:
Actual:

Happens: every time / sometimes (x of y tries) / once
Attachments: screen recording, screenshots
Debug log: (Settings → Copy debug log, paste here)
```
