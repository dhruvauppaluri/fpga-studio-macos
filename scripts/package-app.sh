#!/bin/zsh
set -euo pipefail

project_root=${0:A:h:h}
configuration=${CONFIGURATION:-release}
output_root=${1:-"$project_root/dist"}
final_app="$output_root/FPGA Studio.app"
cache="$project_root/.build/module-cache"
staging_root=$(mktemp -d)
app="$staging_root/FPGA Studio.app"

mkdir -p "$cache" "$output_root"
CLANG_MODULE_CACHE_PATH="$cache" SWIFTPM_MODULECACHE_OVERRIDE="$cache" \
  swift build --package-path "$project_root" --configuration "$configuration" --disable-sandbox

mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
mkdir -p "$app/Contents/Resources/Boards"
cp "$project_root/.build/$configuration/FPGAStudio" "$app/Contents/MacOS/FPGAStudio"
cp "$project_root/Packaging/Info.plist" "$app/Contents/Info.plist"
cp "$project_root/Sources/FPGAStudioCore/Resources/Boards/terasic-c5g.json" "$app/Contents/Resources/Boards/terasic-c5g.json"
cp "$project_root/THIRD_PARTY_NOTICES.md" "$app/Contents/Resources/THIRD_PARTY_NOTICES.md"
mkdir -p "$app/Contents/Resources/ThirdPartyLicenses"
/bin/cp -X "$project_root/ThirdPartyLicenses"/* "$app/Contents/Resources/ThirdPartyLicenses/"
toolchain_manifest="$project_root/Sources/FPGAStudioCore/Resources/ToolchainManifest.json"
if [[ -f "$project_root/Toolchains/bootstrap.zip" ]]; then
  release_manifest="$project_root/Toolchains/ToolchainManifest.json"
  if [[ ! -f "$release_manifest" ]]; then
    print -u2 "Toolchains/bootstrap.zip exists without its signed Toolchains/ToolchainManifest.json."
    exit 2
  fi
  CLANG_MODULE_CACHE_PATH="$cache" swift "$project_root/scripts/toolchain-signing.swift" verify \
    "$project_root/Toolchains/bootstrap.zip" "$release_manifest"
  toolchain_manifest="$release_manifest"
  mkdir -p "$app/Contents/Resources/Toolchains"
  cp "$project_root/Toolchains/bootstrap.zip" "$app/Contents/Resources/Toolchains/bootstrap.zip"
fi
cp "$toolchain_manifest" "$app/Contents/Resources/ToolchainManifest.json"

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

codesign --verify --deep --strict "$app"
# Build and sign in a local (non-cloud-synced) temp directory to avoid
# iCloud/file-provider xattr races that break strict codesign verification.
clean_app=$(mktemp -d)/FPGAStudio.app
ditto --norsrc "$app" "$clean_app"
find "$clean_app" -exec xattr -c {} + 2>/dev/null
if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  codesign --force --deep --options runtime --timestamp \
    --entitlements "$project_root/Packaging/FPGAStudio.entitlements" \
    --sign "$DEVELOPER_ID_APPLICATION" "$clean_app"
else
  codesign --force --deep --sign - "$clean_app"
fi
codesign --verify --deep --strict "$clean_app"
rm -rf "$final_app"
ditto "$clean_app" "$final_app"
rm -rf "${clean_app:h}"
rm -rf "$staging_root"

print "$final_app"
