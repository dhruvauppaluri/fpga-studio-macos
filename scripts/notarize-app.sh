#!/bin/zsh
set -euo pipefail

app=${1:?"usage: notarize-app.sh /path/to/FPGA Studio.app"}
profile=${NOTARY_PROFILE:?"Set NOTARY_PROFILE to an xcrun notarytool keychain profile"}
archive="${app:r}.zip"

ditto -c -k --keepParent "$app" "$archive"
xcrun notarytool submit "$archive" --keychain-profile "$profile" --wait
xcrun stapler staple "$app"
spctl --assess --type execute --verbose=2 "$app"
