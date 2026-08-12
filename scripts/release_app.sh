#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
cd "$repo_root"

: "${EVEE_CODESIGN_IDENTITY:?Set EVEE_CODESIGN_IDENTITY to a Developer ID Application identity}"
: "${EVEE_NOTARY_PROFILE:?Set EVEE_NOTARY_PROFILE to an xcrun notarytool keychain profile}"

case "$EVEE_CODESIGN_IDENTITY" in
  *"Developer ID Application:"*) ;;
  *) echo "EVEE_CODESIGN_IDENTITY must be a Developer ID Application identity" >&2; exit 64 ;;
esac

EVEE_CODESIGN_IDENTITY="$EVEE_CODESIGN_IDENTITY" scripts/package_app.sh release
scripts/verify_app.sh dist/Evee.app
codesign --verify --deep --strict --verbose=2 dist/Evee.app
signature_details="$(codesign -d --verbose=4 dist/Evee.app 2>&1)"
grep -q 'Authority=Developer ID Application:' <<<"$signature_details"
grep -q 'flags=.*runtime' <<<"$signature_details"

mkdir -p dist
zip_path="dist/Evee-notarization.zip"
dmg_path="dist/Evee.dmg"
rm -f "$zip_path" "$dmg_path"
ditto -c -k --keepParent dist/Evee.app "$zip_path"
xcrun notarytool submit "$zip_path" --keychain-profile "$EVEE_NOTARY_PROFILE" --wait
xcrun stapler staple dist/Evee.app
xcrun stapler validate dist/Evee.app
spctl --assess --type execute --verbose=2 dist/Evee.app
rm -f "$zip_path"

hdiutil create -volname Evee -srcfolder dist/Evee.app -ov -format UDZO "$dmg_path"
codesign --force --sign "$EVEE_CODESIGN_IDENTITY" --timestamp "$dmg_path"
xcrun notarytool submit "$dmg_path" --keychain-profile "$EVEE_NOTARY_PROFILE" --wait
xcrun stapler staple "$dmg_path"
xcrun stapler validate "$dmg_path"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg_path"
shasum -a 256 "$dmg_path" >"$dmg_path.sha256"
echo "$dmg_path"
