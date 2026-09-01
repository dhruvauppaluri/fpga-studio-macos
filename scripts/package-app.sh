#!/bin/zsh
set -euo pipefail

project_root=${0:A:h:h}
configuration=${CONFIGURATION:-release}
output_root=${1:-"$project_root/dist"}
app="$output_root/FPGA Studio.app"
cache="$project_root/.build/module-cache"

mkdir -p "$cache" "$output_root"
CLANG_MODULE_CACHE_PATH="$cache" SWIFTPM_MODULECACHE_OVERRIDE="$cache" \
  swift build --package-path "$project_root" --configuration "$configuration" --disable-sandbox

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
mkdir -p "$app/Contents/Resources/Boards"
cp "$project_root/.build/$configuration/FPGAStudio" "$app/Contents/MacOS/FPGAStudio"
cp "$project_root/Packaging/Info.plist" "$app/Contents/Info.plist"
cp "$project_root/Sources/FPGAStudioCore/Resources/Boards/terasic-c5g.json" "$app/Contents/Resources/Boards/terasic-c5g.json"
cp "$project_root/Sources/FPGAStudioCore/Resources/ToolchainManifest.json" "$app/Contents/Resources/ToolchainManifest.json"
if [[ -f "$project_root/Toolchains/bootstrap.zip" ]]; then
  mkdir -p "$app/Contents/Resources/Toolchains"
  cp "$project_root/Toolchains/bootstrap.zip" "$app/Contents/Resources/Toolchains/bootstrap.zip"
fi

# Finder and cloud-provider metadata invalidates strict code-signature checks.
xattr -cr "$app"

if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  codesign --force --options runtime --timestamp \
    --entitlements "$project_root/Packaging/FPGAStudio.entitlements" \
    --sign "$DEVELOPER_ID_APPLICATION" "$app"
else
  codesign --force --sign - "$app"
  print "Created an ad-hoc signed development build. Set DEVELOPER_ID_APPLICATION for distribution signing."
fi

print "$app"
