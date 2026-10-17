#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mode="${1:-simulator}"
case "$mode" in simulator|device|archive) ;; *) echo "Usage: $0 [simulator|device|archive]" >&2; exit 2 ;; esac
./scripts/generate.sh
args=(-project BoostyAppleTV.xcodeproj -scheme BoostyAppleTV -derivedDataPath DerivedData)
if [[ -n "${APP_BUNDLE_IDENTIFIER:-}" ]]; then
    args+=("APP_BUNDLE_IDENTIFIER=$APP_BUNDLE_IDENTIFIER")
fi
case "$mode" in
  simulator)
    xcodebuild "${args[@]}" -destination 'generic/platform=tvOS Simulator' CODE_SIGNING_ALLOWED=NO build
    ;;
  device)
    xcodebuild "${args[@]}" -destination 'generic/platform=tvOS' CODE_SIGNING_ALLOWED=NO build
    ;;
  archive)
    : "${DEVELOPMENT_TEAM:?Укажите DEVELOPMENT_TEAM вашей команды Apple Developer}"
    xcodebuild "${args[@]}" -configuration Release -destination 'generic/platform=tvOS' \
      -archivePath build/BoostyAppleTV.xcarchive "DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM" archive
    ;;
esac
