# Musify

A Spotify-style music player for iPhone, Android and the Mac that plays
**your own music files**, with YouTube on top: search it, play it, keep songs in your
playlists, see the charts, and download songs into your folders.

- **Your library**: add music folders (from Files on iPhone); every folder
  becomes a playlist. Liked Songs, your own playlists, tags (e.g. "To
  replace"), and pinned playlists on Home.
- **Player**: queue (play next / add to queue), shuffle, repeat, sleep
  timer, lyrics from the files' tags, swipe between songs, lock screen and
  Control Center, Android Auto, Siri ("play … on Musify").
- **Equalizer**: 10 bands with presets.
- **YouTube**: search results next to your own songs, played in YouTube's own
  player (hidden), so YouTube songs behave like the rest: queue, lock screen,
  playlists, Liked Songs.
- **Charts** on Home: YouTube Music's Top 100 Global, US, UK, Canada,
  Australia and India.
- **Downloads**: save a YouTube song, or a whole playlist, as M4A with title,
  artist and cover into one of your folders.
- **Sync** between your devices: playlists, tags, Liked Songs, Home pins,
  what's playing (pause on one, carry on from another) and, if you choose a
  folder, the music files themselves, mirrored in the same subfolders. A
  device joins with another's sync code, once approved there.
- **Light or dark**, or as the device is set (Settings).

Charts, downloads and sync need your own
[Musify backend](https://github.com/fatmachines/musify_backend), a small
server running yt-dlp: YouTube doesn't let phones download. Everything else
works without it.

## Build

You need [Flutter](https://docs.flutter.dev/get-started/install) 3.47 or
newer (Dart 3.13), and Xcode for iPhone or Android Studio / the Android SDK for Android.

```sh
git clone https://github.com/fatmachines/musify_frontend.git
cd musify_frontend
flutter pub get
flutter run            # on a connected phone
```

### iPhone

1. Open `ios/Runner.xcworkspace` in Xcode.
2. **Runner → Signing & Capabilities**: pick your team, and change the bundle
   identifier (`com.fatmachines.musify`) to one of your own.
3. Keep the capabilities: **Background Modes → Audio** (playing with the
   screen locked) and **Siri** (voice requests, set in
   `ios/Runner/Runner.entitlements`). Siri needs a paid Apple Developer
   account; with a free one, remove it there (the app then simply skips
   Siri).
4. `flutter run`, or Run in Xcode.

CarPlay needs Apple's CarPlay audio entitlement, which Apple gives on
request; without it Musify shows in CarPlay's Now Playing only.

### Mac

```sh
flutter run -d macos
```

or open `macos/Runner.xcworkspace` in Xcode, pick your team under **Runner →
Signing & Capabilities**, and Run. On a wide window Musify switches to a
desktop layout (library sidebar, search bar on top, player across the
bottom; space plays and pauses). The app is sandboxed: music folders are
added with the open panel and stay readable across launches.

To hand the Mac app to others, `scripts/make_dmg.sh` builds it, signs it
with your Developer ID, packs `dist/Musify-<version>.dmg` and has Apple
notarize it, so it opens without a warning. The script's header lists the
one-time setup (certificate and notarization credentials).

### Android

Change `applicationId` in `android/app/build.gradle.kts` if you publish your
own build, then `flutter run`.

## Connect your server

Deploy the [backend](https://github.com/fatmachines/musify_backend) (its
README walks through it), then in the app: **Your Library → ⋮ → Musify
server**, and enter its address and key. Or build them in:

```sh
flutter run --dart-define=MUSIFY_SERVER=https://musify.example.com \
            --dart-define=MUSIFY_KEY=<your key>
```

## Development

```sh
flutter analyze
flutter test
```

- `packages/just_audio` is a copy of [just_audio](https://pub.dev/packages/just_audio)
  with Musify's iOS equalizer (`MusifyEqualizer.m`); otherwise unchanged.
- `ios/Runner/AppDelegate.swift` holds the native parts: folder access
  (security-scoped bookmarks) and Siri.
- YouTube playback: `lib/services/youtube/youtube_web_player.dart` keeps
  YouTube's mobile player in a hidden web view in step with the app's player,
  which plays silence of the same length for each YouTube song.

## Use responsibly

Musify is for your own listening. Download only what you have the right to,
and respect YouTube's terms where you live.
