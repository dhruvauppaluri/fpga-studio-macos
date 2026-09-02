#!/bin/zsh
set -euo pipefail

project_root=${0:A:h:h}
app_path=${1:-"$project_root/dist/FPGA Studio.app"}
dmg_path=${2:-"$project_root/dist/FPGA Studio.dmg"}

if [[ ! -d "$app_path" ]]; then
  print -u2 "App not found at $app_path. Run scripts/package-app.sh first."
  exit 2
fi

staging=$(mktemp -d "${TMPDIR:-/tmp}/fpga-studio-dmg.XXXXXX")
trap 'rm -rf "$staging"' EXIT

dmg_contents="$staging/dmg"
mkdir -p "$dmg_contents"
ditto --norsrc "$app_path" "$dmg_contents/FPGA Studio.app"
cp "$project_root/THIRD_PARTY_NOTICES.md" "$dmg_contents/Third-Party Software Notices.md"
mkdir -p "$dmg_contents/Third-Party Licenses"
/bin/cp -X "$project_root/ThirdPartyLicenses"/* "$dmg_contents/Third-Party Licenses/"
ln -s /Applications "$dmg_contents/Applications"
find "$dmg_contents" -exec xattr -c {} + 2>/dev/null

codesign --verify --deep --strict "$dmg_contents/FPGA Studio.app" || {
  print -u2 "App at $app_path has an invalid or missing code signature."
  exit 2
}

rm -f "$dmg_path"
hdiutil create \
  -volname "FPGA Studio" \
  -srcfolder "$dmg_contents" \
  -ov -format UDZO \
  "$dmg_path"

print "$dmg_path"
