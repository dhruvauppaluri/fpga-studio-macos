#!/bin/zsh
set -euo pipefail

project_root=${0:A:h:h}
version=${1:-}

if [[ -z "$version" ]]; then
  print -u2 "Usage: scripts/publish-release.sh <version>"
  print -u2 "  e.g.: scripts/publish-release.sh 2026.09.1"
  exit 2
fi

if ! command -v gh &>/dev/null; then
  print -u2 "GitHub CLI (gh) is not installed. brew install gh"
  exit 2
fi

if [[ -n "$(git -C "$project_root" status --porcelain)" ]]; then
  print -u2 "Working tree has uncommitted changes. Commit or stash first."
  exit 2
fi

signing_key=${TOOLCHAIN_SIGNING_PRIVATE_KEY_FILE:-"$project_root/Toolchains/toolchain-signing.key"}
if [[ ! -f "$signing_key" ]]; then
  print -u2 "Signing key not found at $signing_key. Set TOOLCHAIN_SIGNING_PRIVATE_KEY_FILE."
  exit 2
fi

print "==> Building toolchain bundle..."
TOOLCHAIN_SIGNING_PRIVATE_KEY_FILE="$signing_key" "$project_root/scripts/package-toolchain.sh"

print "==> Building FPGA Studio.app..."
"$project_root/scripts/package-app.sh"

print "==> Verifying the bundled toolchain without Homebrew..."
"$project_root/scripts/verify-bundled-toolchain.sh"

print "==> Creating DMG..."
"$project_root/scripts/make-dmg.sh"

dmg="$project_root/dist/FPGA Studio.dmg"
if [[ ! -f "$dmg" ]]; then
  print -u2 "DMG was not created. Check the build output above."
  exit 2
fi

print "==> Tagging v$version and publishing release..."
git -C "$project_root" tag -a "v$version" -m "Release $version"
git -C "$project_root" push origin "v$version"

gh release create "v$version" "$dmg" \
  --repo "$(git -C "$project_root" remote get-url origin)" \
  --title "FPGA Studio $version" \
  --notes "## FPGA Studio $version

Download **FPGA Studio.dmg**, open it, and drag the app to Applications.

The complete FPGA synthesis toolchain (Yosys, nextpnr-mistral, openFPGALoader, Icarus Verilog, Verilator, GHDL) is bundled — no Homebrew or manual setup required.

### First launch (ad-hoc signed)
Since this build is not notarized, macOS will show a warning on first launch.
Right-click the app → **Open** → click **Open** in the dialog. You only need to do this once.

### Included tools
- **Yosys** — RTL synthesis
- **nextpnr-mistral** — place and route for Intel Cyclone V
- **openFPGALoader** — FPGA/flash programming
- **Icarus Verilog** — Verilog simulation
- **Verilator** — Verilog linting
- **GHDL** — VHDL simulation and synthesis (via ghdl-yosys-plugin)

All bundled open-source projects are credited in **Third-Party Software Notices.md** inside the DMG, with complete license texts and source revision links."

print "Released FPGA Studio $version"
