#!/bin/bash
# Builds the Android app as one APK for any phone, signed with your release
# key, at dist/Musify-<version>.apk. Run from the repo root:
#
#   scripts/make_apk.sh
#
# Needs the Android SDK (Android Studio installs it) and, once, a release
# key, kept safe: every later version has to be signed with the same one,
# or phones refuse it as an update.
#
#   keytool -genkey -v -keystore ~/musify-release.jks -keyalg RSA \
#     -keysize 2048 -validity 10000 -alias musify
#
# then android/key.properties (kept out of git):
#
#   storeFile=/Users/<you>/musify-release.jks
#   storePassword=<password>
#   keyAlias=musify
#   keyPassword=<password>
set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -f android/key.properties ]; then
  echo "No android/key.properties: the APK gets the debug key." >&2
  echo "Fine to try out; for a release, make a key (see this script's top)." >&2
fi
version="$(grep '^version:' pubspec.yaml | sed 's/version: *//; s/+.*//')"

flutter build apk --release
mkdir -p dist
cp build/app/outputs/flutter-apk/app-release.apk "dist/Musify-$version.apk"
echo "== Done: dist/Musify-$version.apk"
