#!/bin/bash
# Builds Musify for Mac, signs it with your Developer ID, packs it in a
# .dmg, and has Apple notarize it, so it opens on any Mac without a
# warning. Run on a Mac from the repo root:
#
#   scripts/make_dmg.sh
#
# Needs, once:
#   - a "Developer ID Application" certificate in your keychain (Xcode →
#     Settings → Accounts → your team → Manage Certificates → + ).
#   - notarization credentials saved in your keychain under a profile
#     (an app-specific password from account.apple.com):
#       xcrun notarytool store-credentials musify-notary \
#         --apple-id <you@example.com> --team-id <TEAMID> \
#         --password <app-specific-password>
#
# SIGN_IDENTITY picks a certificate when there are several; NOTARY_PROFILE
# names another keychain profile; NOTARIZE=0 skips notarizing.
set -euo pipefail

cd "$(dirname "$0")/.."

identity="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning |
  grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')}"
if [ -z "$identity" ]; then
  echo "No Developer ID Application certificate in the keychain." >&2
  echo "Make one in Xcode → Settings → Accounts → Manage Certificates." >&2
  exit 1
fi
profile="${NOTARY_PROFILE:-musify-notary}"
version="$(grep '^version:' pubspec.yaml | sed 's/version: *//; s/+.*//')"
app=build/macos/Build/Products/Release/Musify.app
dmg="dist/Musify-$version.dmg"

echo "== Building"
flutter build macos --release

echo "== Signing with $identity"
sign() {
  codesign --force --timestamp --options runtime --sign "$identity" "$@"
}
# Inside out: frameworks and libraries first, then the app around them.
find "$app/Contents/Frameworks" -depth \( -name '*.framework' -o -name '*.dylib' \) -print0 |
  while IFS= read -r -d '' item; do sign "$item"; done
sign --entitlements macos/Runner/Release.entitlements "$app"
codesign --verify --deep --strict "$app"

echo "== Packing $dmg"
stage=dist/dmg
rm -rf "$stage" "$dmg"
mkdir -p "$stage"
cp -R "$app" "$stage/"
ln -s /Applications "$stage/Applications"
hdiutil create -volname Musify -srcfolder "$stage" -ov -format UDZO "$dmg"
rm -rf "$stage"
codesign --force --timestamp --sign "$identity" "$dmg"

if [ "${NOTARIZE:-1}" != 0 ]; then
  echo "== Notarizing (a few minutes)"
  xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait
  xcrun stapler staple "$dmg"
  spctl --assess --type open --context context:primary-signature -v "$dmg"
fi

echo "== Done: $dmg"
