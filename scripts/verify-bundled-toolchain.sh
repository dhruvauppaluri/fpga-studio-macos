#!/bin/zsh
set -euo pipefail

project_root=${0:A:h:h}
app_path=${1:-"$project_root/dist/FPGA Studio.app"}
archive="$app_path/Contents/Resources/Toolchains/bootstrap.zip"
manifest="$app_path/Contents/Resources/ToolchainManifest.json"
fixtures="$project_root/scripts/fixtures/toolchain-smoke"

if [[ ! -f "$archive" || ! -f "$manifest" ]]; then
  print -u2 "The app does not contain a bundled toolchain and manifest: $app_path"
  exit 2
fi

for fixture in top.v top_tb.v vhdl_smoke.vhd c5g.qsf; do
  if [[ ! -f "$fixtures/$fixture" ]]; then
    print -u2 "Missing smoke-test fixture: $fixtures/$fixture"
    exit 2
  fi
done

scratch=$(mktemp -d "${TMPDIR:-/tmp}/fpga-studio-isolated-toolchain.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
prefix="$scratch/toolchain"
work="$scratch/work"
module_cache="$scratch/module-cache"
mkdir -p "$prefix" "$work" "$module_cache"

print "==> Verifying the embedded archive signature..."
CLANG_MODULE_CACHE_PATH="$module_cache" SWIFT_MODULECACHE_PATH="$module_cache" \
  swift "$project_root/scripts/toolchain-signing.swift" verify "$archive" "$manifest"

/usr/bin/ditto -x -k "$archive" "$prefix"
mkdir -p "$work/fixtures"
/bin/cp -X "$fixtures/top.v" "$fixtures/top_tb.v" "$fixtures/vhdl_smoke.vhd" "$fixtures/c5g.qsf" "$work/fixtures/"

print "==> Checking executable completeness and relocatability..."
required=(yosys yosys-abc nextpnr-mistral mistral-cv openFPGALoader iverilog vvp verilator verilator_bin ghdl ghdl1-llvm ghwdump)
for executable in $required; do
  if [[ ! -x "$prefix/bin/$executable" ]]; then
    print -u2 "Bundled executable is missing or not executable: bin/$executable"
    exit 1
  fi
done

required_notices=(
  THIRD_PARTY_NOTICES.md
  licenses/Yosys-COPYING
  licenses/Berkeley-ABC-copyright.txt
  licenses/nextpnr-COPYING
  licenses/Mistral-LICENSE
  licenses/openFPGALoader-LICENSE
  licenses/Icarus-Verilog-COPYING
  licenses/Verilator-LICENSE
  licenses/GHDL-COPYING.md
  licenses/GHDL-Yosys-Plugin-LICENSE
  licenses/Boost-LICENSE_1_0.txt
  licenses/libftdi1-COPYING.LIB
  licenses/libusb-COPYING
  licenses/GCC-COPYING.RUNTIME
  licenses/XZ-Utils-COPYING.0BSD
  licenses/GNU-Readline-COPYING
  licenses/Tcl-license.terms
  licenses/LibTomMath-LICENSE
  licenses/Zstandard-LICENSE
)
for notice in $required_notices; do
  if [[ ! -s "$prefix/$notice" ]]; then
    print -u2 "Bundled attribution or license file is missing: $notice"
    exit 1
  fi
done

while IFS= read -r file_path; do
  if /usr/bin/file -b "$file_path" | /usr/bin/grep -q 'Mach-O'; then
    dependencies=$(/usr/bin/otool -L "$file_path")
    if print -r -- "$dependencies" | /usr/bin/grep -Eq '/opt/homebrew|/usr/local'; then
      print -u2 "Bundled binary has a package-manager dependency: $file_path"
      print -u2 -- "$dependencies"
      exit 1
    fi
  fi
done < <(/usr/bin/find "$prefix/bin" "$prefix/lib" -type f -print)

isolated_env=(
  "PATH=$prefix/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  "LANG=en_US.UTF-8"
  "LC_ALL=en_US.UTF-8"
  "TMPDIR=$scratch"
  "DYLD_LIBRARY_PATH=$prefix/lib"
  "YOSYS_DATDIR=$prefix/share/yosys"
  "VERILATOR_ROOT=$prefix/share/verilator"
  "GHDL_PREFIX=$prefix/lib/ghdl"
)

run_isolated() {
  /usr/bin/env -i $isolated_env "$@"
}

print "==> Loading every bundled tool with Homebrew absent from PATH..."
run_isolated "$prefix/bin/ghdl" --version >/dev/null
run_isolated "$prefix/bin/iverilog" -B "$prefix/lib/ivl" -V >/dev/null 2>&1
run_isolated "$prefix/bin/vvp" -V >/dev/null 2>&1
run_isolated "$prefix/bin/verilator" --version >/dev/null
run_isolated "$prefix/bin/yosys" -m ghdl -p 'help ghdl' >/dev/null
run_isolated "$prefix/bin/nextpnr-mistral" --help >/dev/null 2>&1
run_isolated "$prefix/bin/openFPGALoader" --help >/dev/null 2>&1

print "==> Running isolated Verilog simulation and lint..."
run_isolated "$prefix/bin/iverilog" \
  -B "$prefix/lib/ivl" -g2012 -s top_tb -o "$work/verilog-simulation" \
  "$work/fixtures/top.v" "$work/fixtures/top_tb.v"
simulation_output=$(run_isolated "$prefix/bin/vvp" -M "$prefix/lib/ivl" "$work/verilog-simulation")
if [[ "$simulation_output" != *"iverilog-smoke-ok"* ]]; then
  print -u2 "Icarus Verilog did not produce the expected smoke-test result."
  exit 1
fi
run_isolated "$prefix/bin/verilator" --lint-only --top-module top "$work/fixtures/top.v"

print "==> Running isolated VHDL analysis, elaboration, and simulation..."
(
  cd "$work"
  run_isolated "$prefix/bin/ghdl" -a --std=08 "$work/fixtures/vhdl_smoke.vhd"
  run_isolated "$prefix/bin/ghdl" -e --std=08 vhdl_smoke
  run_isolated "$prefix/bin/ghdl" -r --std=08 vhdl_smoke --stop-time=1ns
)

print "==> Running isolated Verilog and VHDL synthesis..."
run_isolated "$prefix/bin/yosys" -p \
  "read_verilog $work/fixtures/top.v; hierarchy -check -top top; synth_intel_alm -top top; write_json $work/design.json" \
  >/dev/null
run_isolated "$prefix/bin/yosys" -m ghdl -p \
  "ghdl --std=08 $work/fixtures/vhdl_smoke.vhd -e vhdl_smoke; hierarchy -check -top vhdl_smoke; synth_intel_alm -top vhdl_smoke; write_json $work/vhdl-design.json" \
  >/dev/null

print "==> Running isolated Cyclone V place-and-route..."
run_isolated "$prefix/bin/nextpnr-mistral" \
  --device 5CGXFC5C6F27C7 \
  --json "$work/design.json" \
  --qsf "$work/fixtures/c5g.qsf" \
  --seed 1 \
  --report "$work/report.json" \
  --rbf "$work/design.rbf" \
  >/dev/null

if [[ ! -s "$work/design.rbf" || ! -s "$work/report.json" ]]; then
  print -u2 "Place-and-route did not produce the expected RBF and report artifacts."
  exit 1
fi

print "Bundled toolchain verification passed with Homebrew absent from PATH."
