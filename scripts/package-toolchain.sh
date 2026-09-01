#!/bin/zsh
set -euo pipefail

project_root=${0:A:h:h}
destination=${1:-"$project_root/dist/fpga-studio-toolchain-arm64.zip"}
staging=$(mktemp -d "${TMPDIR:-/tmp}/fpga-studio-toolchain.XXXXXX")
trap 'rm -rf "$staging"' EXIT

mkdir -p "$staging/bin" "$staging/lib" "$staging/share" "$staging/licenses"
tools=(yosys nextpnr-mistral openFPGALoader iverilog vvp verilator ghdl)
for tool in $tools; do
  source_path=$(command -v "$tool" || true)
  if [[ -z "$source_path" ]]; then
    print -u2 "Missing required tool: $tool"
    exit 2
  fi
  cp "$source_path" "$staging/bin/$tool"
done

if command -v brew >/dev/null; then
  for resource in yosys verilator ghdl; do
    formula_prefix=$(brew --prefix "$resource" 2>/dev/null || true)
    [[ -d "$formula_prefix/share/$resource" ]] && cp -R "$formula_prefix/share/$resource" "$staging/share/$resource"
    [[ -d "$formula_prefix/lib/$resource" ]] && cp -R "$formula_prefix/lib/$resource" "$staging/lib/$resource"
  done
fi

# Make Homebrew-linked Mach-O dependencies private to the archive.
queue=("$staging/bin"/*)
seen=()
while (( ${#queue} )); do
  item=$queue[1]
  queue=($queue[2,-1])
  [[ -f "$item" ]] || continue
  dependencies=(${(f)"$(otool -L "$item" 2>/dev/null | tail -n +2 | awk '{print $1}')"})
  for dependency in $dependencies; do
    case "$dependency" in
      /System/*|/usr/lib/*|@*) continue ;;
    esac
    [[ -f "$dependency" ]] || continue
    copied="$staging/lib/${dependency:t}"
    if [[ ! -f "$copied" ]]; then
      cp "$dependency" "$copied"
      chmod u+w "$copied"
      install_name_tool -id "@rpath/${dependency:t}" "$copied" 2>/dev/null || true
      queue+=("$copied")
    fi
    install_name_tool -change "$dependency" "@executable_path/../lib/${dependency:t}" "$item" 2>/dev/null || true
  done
done

for item in "$staging/bin"/* "$staging/lib"/*; do
  codesign --force --sign - "$item" 2>/dev/null || true
done

cp "$project_root/Sources/FPGAStudioCore/Resources/ToolchainManifest.json" "$staging/ToolchainManifest.json"
print "This archive contains independently licensed open-source tools. See each upstream project for complete license text." > "$staging/licenses/README.txt"

mkdir -p "${destination:h}"
rm -f "$destination"
ditto -c -k --sequesterRsrc "$staging" "$destination"
shasum -a 256 "$destination"
print "Packaged $destination"
