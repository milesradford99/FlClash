#!/bin/bash
set -euo pipefail

if [[ $# != 4 ]]; then
  echo "Usage: $0 TEAM_ID DEVELOPER_ID_APPLICATION HOST_PROFILE FILTER_PROFILE" >&2
  exit 64
fi

team=$1
identity=$2
host_profile=$3
filter_profile=$4
[[ "$team" =~ ^[A-Z0-9]{10}$ ]]
[[ -f "$host_profile" && -f "$filter_profile" ]]
xcodebuild -version

root="$(cd "$(dirname "$0")/.." && pwd)"
host_profile="$(cd "$(dirname "$host_profile")" && pwd)/$(basename "$host_profile")"
filter_profile="$(cd "$(dirname "$filter_profile")" && pwd)/$(basename "$filter_profile")"
cd "$root"

flutter pub get
flutter build macos --release --no-pub --dart-define=APP_ENV=stable \
  --dart-define=FLCLASH_REPOSITORY=milesradford99/FlClash --dart-define=MANAGED_ISP_PROTECTION=true
built="$root/build/macos/Build/Products/Release/FlClash.app"
[[ -f "$built/Contents/MacOS/FlClashCore" ]]

mkdir -p "$root/dist"
output="$(mktemp -d "$root/dist/flclash-isp.XXXXXXXX")"
app="$output/FlClash ISP.app"
ditto "$built" "$app"
metadata="$output/signing"
mkdir -p "$metadata"
identifier="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Contents/Info.plist")"
extension_id="$identifier.filter"
extension="$app/Contents/Library/SystemExtensions/$extension_id.systemextension"
mkdir -p "$extension/Contents/MacOS"

python3 - "$app" "$extension" "$metadata" "$identifier" "$team" <<'PY'
from pathlib import Path
import plistlib
import sys

app, extension, metadata = (Path(x) for x in sys.argv[1:4])
app_id, team = sys.argv[4:]
extension_id = app_id + ".filter"
usage = "Filters outbound traffic while the fixed ISP profile is active."
host_info = app / "Contents/Info.plist"
with host_info.open("rb") as source:
    host = plistlib.load(source)
host["CFBundleDisplayName"] = "FlClash ISP"
host["LSMinimumSystemVersion"] = "15.0"
host["NSSystemExtensionUsageDescription"] = usage
with host_info.open("wb") as target:
    plistlib.dump(host, target)

extension_info = {
    "CFBundleIdentifier": extension_id,
    "CFBundleExecutable": "FlClashFilter",
    "CFBundleName": "FlClash ISP Network Filter",
    "CFBundlePackageType": "SYSX",
    "CFBundleVersion": host["CFBundleVersion"],
    "CFBundleShortVersionString": host["CFBundleShortVersionString"],
    "LSMinimumSystemVersion": "15.0",
    "FilterTeam": team,
    "NSSystemExtensionUsageDescription": usage,
    "NetworkExtension": {
        "NEMachServiceName": team + "." + extension_id,
        "NEProviderClasses": {
            "com.apple.networkextension.filter-packet": "FlClashFilter.PacketFilterProvider",
            "com.apple.networkextension.filter-data": "FlClashFilter.SocketFilterProvider",
        },
    },
}
with (extension / "Contents/Info.plist").open("wb") as target:
    plistlib.dump(extension_info, target)

network = "com.apple.developer.networking.networkextension"
filter_entitlements = {network: ["content-filter-provider-systemextension"]}
with (metadata / "filter.plist").open("wb") as target:
    plistlib.dump(filter_entitlements, target)

with Path("macos/Runner/Release.entitlements").open("rb") as source:
    host_entitlements = plistlib.load(source)
host_entitlements.update(filter_entitlements)
host_entitlements["com.apple.developer.system-extension.install"] = True
with (metadata / "app.plist").open("wb") as target:
    plistlib.dump(host_entitlements, target)
PY

cp "$host_profile" "$app/Contents/embedded.provisionprofile"
cp "$filter_profile" "$extension/Contents/embedded.provisionprofile"
executable="$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$app/Contents/Info.plist")"
binaries=()
for arch in $(xcrun lipo -archs "$app/Contents/MacOS/$executable"); do
  target="$metadata/FlClashFilter-$arch"
  xcrun swiftc -O -module-name FlClashFilter -target "${arch}-apple-macos15.0" \
    macos/NetworkProtection/*.swift -o "$target"
  binaries+=("$target")
done
xcrun lipo -create "${binaries[@]}" -output "$extension/Contents/MacOS/FlClashFilter"

sign=(codesign --force --options runtime --timestamp --sign "$identity")
while IFS= read -r -d '' item; do
  "${sign[@]}" "$item"
done < <(find "$app/Contents/Frameworks" -maxdepth 1 \( -name '*.framework' -o -name '*.dylib' \) -print0)
"${sign[@]}" --identifier "$identifier.core" "$app/Contents/MacOS/FlClashCore"
"${sign[@]}" --entitlements "$metadata/filter.plist" "$extension"
"${sign[@]}" --entitlements "$metadata/app.plist" "$app"
codesign --verify --deep --strict "$app"

archive="$output/FlClash-ISP-macOS.zip"
ditto -c -k --keepParent "$app" "$archive"
if [[ -n "${MANAGED_NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$archive" --keychain-profile "$MANAGED_NOTARY_PROFILE" --wait
  xcrun stapler staple "$app"
  rm "$archive"
  ditto -c -k --keepParent "$app" "$archive"
fi
shasum -a 256 "$archive"
