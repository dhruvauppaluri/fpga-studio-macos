# FPGA Studio

FPGA Studio is a native Apple-silicon macOS IDE for portable VHDL, Verilog, and SystemVerilog projects. Its initial hardware profile targets the Terasic Cyclone V GX Starter Kit (`5CGXFC5C6F27C7`) through Yosys, nextpnr-mistral/Mistral, and openFPGALoader.

The app uses Swift 6, SwiftUI, and a TextKit/AppKit source editor. Projects remain ordinary folders with a versioned `fpga-project.json`, QSF constraints, HDL sources, tests, and deterministic artifacts under `.fpga/build`.

## Included experience

- Native welcome window, unified toolbar, project navigator, source tabs, inspector, issues, logs, simulation, waveform, and programmer panels.
- TextKit editing with line numbers, SF Mono, syntax coloring, search, bracket matching, undo, autosave, and clickable diagnostics.
- Blank HDL, C5G Blinky, and RV32I Lab templates. The RV32I template deliberately contains interfaces, a wrapper, ROM image, and failing directed-test scaffold—not a completed processor.
- Verilog/SystemVerilog simulation with Icarus, lint with Verilator, VHDL simulation with GHDL, and native VCD parsing/viewing.
- Mixed-language synthesis through the GHDL-Yosys plugin; mixed-language simulation is not offered in v1.
- Argument-array-only subprocess execution, sanitized environments, streamed logs, cancellation, and per-project build-directory locking.
- Searchable C5G assignments with duplicate, unknown-pin, missing-port, I/O-standard, and port-direction validation.
- Safe SRAM programming and a guarded EPCQ flash flow with artifact hash, operating instructions, sleep/termination protection, and post-write JTAG detection.
- Managed archive import, SHA-256 and optional Ed25519 verification, atomic activation, installed-version activation for rollback, and Homebrew lookup while developing.

## Build and run

Requirements are an Apple-silicon Mac on macOS 15 or newer and Xcode 16 or newer.

```sh
swift run FPGAStudio
swift test
./scripts/package-app.sh
open "dist/FPGA Studio.app"
```

The packaging script creates an ad-hoc signed development app. Set `DEVELOPER_ID_APPLICATION` to a Developer ID Application identity for hardened distribution signing, then use `scripts/notarize-app.sh` with a configured `NOTARY_PROFILE`.

## Collaborating

The repository is intended to stay private during early hardware validation. Add testers as GitHub collaborators so they can clone it, open issues, and submit pull requests without making the project public. See [CONTRIBUTING.md](CONTRIBUTING.md) for setup and verification steps and [SECURITY.md](SECURITY.md) for private vulnerability reporting and credential hygiene.

## Toolchain archive

During development, executables are discovered in the active managed toolchain, `/opt/homebrew/bin`, `/usr/local/bin`, and system paths. To package installed arm64 tools and their relocatable libraries/resources:

```sh
./scripts/package-toolchain.sh dist/fpga-studio-toolchain-arm64.zip
```

Import the archive from **Settings → Toolchain → Install Toolchain Archive**. A production release can place a verified archive at `Toolchains/bootstrap.zip` before app packaging; it will then be copied into the application resources for first-launch bootstrap installation. Release metadata should replace the development manifest’s null checksum/signature fields.

## Backend boundary

[OpenFPGA](https://openfpga.readthedocs.io/en/stable/) is an architecture-generation project and is used here as educational/reference material. It is not presented as the Cyclone V implementation backend. The deploy flow is Yosys → [nextpnr-mistral](https://github.com/YosysHQ/nextpnr) / [Mistral](https://github.com/Ravenslofty/mistral) → [openFPGALoader](https://github.com/trabucayre/openFPGALoader).

Cyclone V support remains experimental upstream. The default synthesis path maps inferred memories and multiplication to logic before ALM mapping; M10K, LUT RAM, DSPs, LPDDR2, transceivers, PCIe, advanced PLLs, and other hard blocks are outside the validated v1 path.

## Verification and hardware status

The automated suite covers manifest round trips, safe paths, QSF validation, port directions, diagnostics, VCD parsing, template integrity, shell-injection resistance, real Icarus simulation, and RV32I scaffold compilation.

Software build and simulation are verified on arm64 macOS. No physical C5G was available in this workspace, so USB-Blaster detection, SRAM volatility, EPCQ persistence, and a user-authored RV32I hardware deployment are intentionally **not claimed as accepted**. Run those four acceptance steps on the target board before labeling a release hardware-validated.
