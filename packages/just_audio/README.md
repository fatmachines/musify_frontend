# just_audio (vendored)

A copy of [just_audio](https://pub.dev/packages/just_audio) 0.10.6 (MIT, see
LICENSE), used through `dependency_overrides` in the app's pubspec.

Musify's only change is the iOS/macOS equalizer: `MusifyEqualizer.m`
attaches an audio processing tap to each player item (from
`UriAudioSource.createPlayerItem`) and is controlled over the
`musify/equalizer` method channel registered in `JustAudioPlugin`. Search
the darwin sources for "Musify" to find every change.
