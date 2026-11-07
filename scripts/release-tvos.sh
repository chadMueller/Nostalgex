#!/usr/bin/env bash
# Archive, export, validate and upload the tvOS app to App Store Connect.
#
#   ./scripts/release-tvos.sh            # archive -> validate -> upload
#   ./scripts/release-tvos.sh --dry-run  # stop after validation, upload nothing
#
# Bump MARKETING_VERSION / CURRENT_PROJECT_VERSION in the Xcode project first.
# This never submits for review: it leaves the build waiting in App Store
# Connect so a human makes that call.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCHIVE=/tmp/Nostalgex.xcarchive
EXPORT=/tmp/nostalgex-export
# altool (validate, upload) reads its key from ~/.appstoreconnect/private_keys.
KEY_ID=2Y8K8NTUV3
ISSUER=e9e9d3ec-0c04-4694-bcb9-55e8407672f6
# xcodebuild signs with automatic signing and this key, so it can fetch or update
# the App Store profiles with every capability the targets have (iCloud, App
# Groups). See the comment in Nostalgex/ExportOptions.plist.
SIGN_KEY_ID=BF3LR5NQQK
SIGN_KEY_PATH="$HOME/.appstoreconnect/AuthKey_$SIGN_KEY_ID.p8"
SIGNING=(
  -allowProvisioningUpdates
  -authenticationKeyPath "$SIGN_KEY_PATH"
  -authenticationKeyID "$SIGN_KEY_ID"
  -authenticationKeyIssuerID "$ISSUER"
)
[ -f "$SIGN_KEY_PATH" ] || { echo "missing $SIGN_KEY_PATH"; exit 1; }
DRY_RUN=${1:-}

VERSION=$(grep -m1 "MARKETING_VERSION = " "$ROOT/Nostalgex/Nostalgex.xcodeproj/project.pbxproj" | sed 's/.*= *//;s/;//')
BUILD=$(grep -m1 "CURRENT_PROJECT_VERSION = " "$ROOT/Nostalgex/Nostalgex.xcodeproj/project.pbxproj" | sed 's/.*= *//;s/;//')
echo "==> Releasing $VERSION (build $BUILD)"

rm -rf "$ARCHIVE" "$EXPORT"

echo "==> Archiving"
xcodebuild archive \
  -project "$ROOT/Nostalgex/Nostalgex.xcodeproj" \
  -scheme Nostalgex \
  -destination 'generic/platform=tvOS' \
  -archivePath "$ARCHIVE" \
  "${SIGNING[@]}" > /tmp/release-archive.log 2>&1 \
  || { echo "archive failed, see /tmp/release-archive.log"; tail -20 /tmp/release-archive.log; exit 1; }

# The app is useless without current channel data, and the copy phase pulls it
# from the repo root, so confirm it actually landed rather than trusting it.
APP="$ARCHIVE/Products/Applications/Nostalgex.app"
for f in channels.json channels-memberships.json; do
  [ -f "$APP/$f" ] || { echo "MISSING $f in the archive"; exit 1; }
done
echo "    bundled $(basename "$APP"), channel data present"

# The keys come from the gitignored Nostalgex/Secrets.xcconfig. A checkout without it (a fresh
# worktree, a clone) builds and archives fine with the keys empty and the enrichment layer
# silently off, so confirm they landed. Never print them.
for k in SupabaseURL SupabaseAnonKey TelemetryDeckAppID; do
  v=$(/usr/libexec/PlistBuddy -c "Print :$k" "$APP/Info.plist" 2>/dev/null || true)
  [ -n "$v" ] || { echo "EMPTY $k in the archive's Info.plist: is Nostalgex/Secrets.xcconfig missing?"; exit 1; }
done
echo "    API keys present in Info.plist"

echo "==> Exporting"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT" \
  -exportOptionsPlist "$ROOT/Nostalgex/ExportOptions.plist" \
  "${SIGNING[@]}" > /tmp/release-export.log 2>&1 \
  || { echo "export failed, see /tmp/release-export.log"; grep -E "error:" /tmp/release-export.log | head; exit 1; }

# altool reports failure in its OUTPUT but still exits 0, so `set -e` does not
# catch it. Check for the success marker instead of trusting the exit code, or
# a rejected build sails straight through to upload.
run_altool() {
  local action="$1" marker="$2" log="$3"
  set +e
  xcrun altool "$action" -f "$EXPORT/Nostalgex.ipa" -t tvos \
    --apiKey "$KEY_ID" --apiIssuer "$ISSUER" 2>&1 | tee "$log"
  set -e
  if ! grep -q "$marker" "$log"; then
    echo
    echo "FAILED: $action did not report '$marker'. See $log"
    exit 1
  fi
}

echo "==> Validating"
run_altool --validate-app "VERIFY SUCCEEDED" /tmp/release-validate.log

if [ "$DRY_RUN" = "--dry-run" ]; then
  echo "==> Dry run, not uploading."
  exit 0
fi

echo "==> Uploading"
run_altool --upload-app "UPLOAD SUCCEEDED" /tmp/release-upload.log

echo "==> Uploaded. Processing takes a few minutes."
echo "    Then attach the build to the version and submit for review."
