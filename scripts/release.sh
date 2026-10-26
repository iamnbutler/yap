#!/usr/bin/env bash
#
# Build, sign, notarize and staple a Developer ID release of the Mac app.
#
#   scripts/release.sh <version> <output-dir>
#
# Wants the Developer ID identity in the login keychain and a notarytool
# keychain profile (NOTARY_PROFILE). Writes <output-dir>/Yap-<version>.zip,
# stapled, so a first launch doesn't need to reach Apple.
set -euo pipefail

VERSION="${1:?usage: release.sh <version> <output-dir>}"
OUT_DIR="${2:?usage: release.sh <version> <output-dir>}"
NOTARY_PROFILE="${NOTARY_PROFILE:?set NOTARY_PROFILE to a notarytool keychain profile}"

case "$VERSION" in
*[!0-9.]* | *..* | .* | *.) echo "error: version must be MAJOR.MINOR.PATCH, got $VERSION" >&2; exit 1 ;;
esac
IFS=. read -r MAJOR MINOR PATCH EXTRA <<< "$VERSION"
if [ -z "${PATCH:-}" ] || [ -n "${EXTRA:-}" ]; then
	echo "error: version must be MAJOR.MINOR.PATCH, got $VERSION" >&2
	exit 1
fi
# One number that grows with the version: the patch alone would reset on a
# minor bump and make 0.2.0 look older than 0.1.19.
BUILD_NUMBER=$((MAJOR * 1000000 + MINOR * 1000 + PATCH))

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/export/Yap.app"
mkdir -p "$OUT_DIR"
ZIP="$(cd "$OUT_DIR" && pwd)/Yap-$VERSION.zip"

say() { printf '\n==> %s\n' "$*"; }

say "Archiving $VERSION (build $BUILD_NUMBER, $(git -C "$REPO_ROOT" rev-parse --short HEAD))"
(cd "$REPO_ROOT" && xcodegen generate --quiet)
xcodebuild archive -quiet \
	-project "$REPO_ROOT/Yap.xcodeproj" -scheme Yap -configuration Release \
	-destination 'generic/platform=macOS' \
	-archivePath "$WORK/Yap.xcarchive" -derivedDataPath "$WORK/dd" \
	CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" \
	MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
	OTHER_CODE_SIGN_FLAGS="--timestamp"
xcodebuild -exportArchive -quiet \
	-archivePath "$WORK/Yap.xcarchive" -exportPath "$WORK/export" \
	-exportOptionsPlist "$REPO_ROOT/scripts/ExportOptions.plist"

# Notarization needs both; catch their absence before a round trip to Apple.
# Read into a variable: `codesign | grep -q` can SIGPIPE codesign into a
# failure that pipefail reports.
SIGN_INFO="$(codesign -d -vv "$APP" 2>&1)"
for needed in "(runtime)" "Developer ID Application"; do
	case "$SIGN_INFO" in
	*"$needed"*) ;;
	*) echo "error: $APP lacks $needed" >&2; echo "$SIGN_INFO" >&2; exit 1 ;;
	esac
done

say "Notarizing (this waits on Apple)"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

say "Stapling"
xcrun stapler staple "$APP"
# The ticket lives inside the app, so zip the stapled copy again.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose "$APP"

say "Done"
echo "  $ZIP"
