# FPGA Studio

FPGA Studio is a native Apple-silicon macOS IDE for portable VHDL, Verilog, and SystemVerilog projects. Its initial hardware profile targets the Terasic Cyclone V GX Starter Kit (`5CGXFC5C6F27C7`) through Yosys, nextpnr-mistral/Mistral, and openFPGALoader.

The app uses Swift 6, SwiftUI, and a TextKit/AppKit source editor. Projects remain ordinary folders with a versioned `fpga-project.json`, QSF constraints, HDL sources, tests, and deterministic artifacts under `.fpga/build`.

## Download

Go to **[Releases](../../releases/latest)** and download **FPGA Studio.dmg**. Open the DMG and drag FPGA Studio into Applications — that's it.

The complete FPGA synthesis toolchain (Yosys, nextpnr-mistral, openFPGALoader, Icarus Verilog, Verilator, GHDL, and the GHDL-Yosys plugin) is bundled inside the app. **No Homebrew, no manual tool installation, no terminal commands required.** On first launch the app silently unpacks and activates the toolchain into `~/Library/Application Support/FPGA Studio/`.

FPGA Studio is built on excellent open-source FPGA tools. Their authors, exact source revisions, licenses, and the small macOS compatibility patches used for this build are documented in [Third-Party Software Notices](THIRD_PARTY_NOTICES.md). Complete license texts ship in the repository, app, toolchain archive, and DMG.

> **First launch (ad-hoc signed):** Since this build is not yet notarized with Apple, macOS will show a warning. Right-click the app → **Open** → click **Open** in the dialog. You only need to do this once.

Requires Apple Silicon (M1 or later) and macOS 15 Sequoia or newer.

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
- Adaptive Beginner, Hobbyist, and Professional workspace profiles over one complete feature set. Profiles tune guidance, project recommendations, and technical detail without gating capabilities.
- A two-minute welcome tour, progressive next-step guide, capability-based toolchain setup, and a searchable plain-language Learn Center.

## Your first project

1. Choose **Create a Project** and keep the recommended **C5G Blinky** template.
2. Follow the guide through **Check Project** and **Run Simulation**. No FPGA board is required yet.
3. Open the Waveform panel and inspect the clock, counter, and LED signal.
4. Set up the signed build toolchain, then choose **Build Bitstream**.
5. Connect the C5G, choose **Detect Board**, and use **Program SRAM Safely**.

Persistent flash and experimental synthesis resources stay under advanced controls. The learning guide can be hidden or restored without changing project files or capabilities. The experience rules are documented in [Documentation/DesignSystem.md](Documentation/DesignSystem.md).

Hobbyists can use the balanced workspace for direct simulation, build, pin editing, and programming. Professionals can apply the Professional profile to expose backend status and advanced synthesis detail by default while retaining the same safety checks and portable project format.

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

During development, executables are discovered in the active managed toolchain, `/opt/homebrew/bin`, `/usr/local/bin`, and system paths. Distribution builds carry one signed bootstrap archive inside the app, so customers receive the complete FPGA toolchain with the app and do not need Homebrew. On first launch, FPGA Studio verifies the archive and atomically installs it into Application Support.

Create the release signing key once and keep it outside version control (the `Toolchains` directory is ignored):

```sh
swift scripts/toolchain-signing.swift generate Toolchains/toolchain-signing.key
```

On the arm64 release machine, install/build every pinned backend, including `ghdl-yosys-plugin`, then package and sign the complete bootstrap:

```sh
TOOLCHAIN_SIGNING_PRIVATE_KEY_FILE=Toolchains/toolchain-signing.key \
  ./scripts/package-toolchain.sh
./scripts/package-app.sh
```

The packager refuses to produce a release if a declared executable, Icarus `vvp`, Verilator's native runtime, GHDL's LLVM driver, the Yosys GHDL plugin, a relocatable resource directory, the archive signature, or a bundle smoke check is missing. It writes `Toolchains/bootstrap.zip` and its signed `Toolchains/ToolchainManifest.json`; `package-app.sh` verifies that pair before embedding it. The private key is never placed in the archive or app.

Create a distribution DMG and publish a release:

```sh
./scripts/make-dmg.sh
./scripts/publish-release.sh 2026.09.1
```

`publish-release.sh` runs the full pipeline (toolchain → app → DMG), tags the commit, and creates a GitHub Release with the DMG attached.
Before creating the DMG, it extracts the app's embedded archive into an isolated temporary prefix and runs Verilog/VHDL simulation, synthesis, and Cyclone V place-and-route with Homebrew absent from `PATH`.

The release gate also verifies that the complete third-party notice and license set is present. Do not distribute a toolchain build after removing those materials.

For development-only imports, use **Settings → Toolchain → Install Toolchain Archive…** with an archive signed by the manifest packaged in that build.

## Backend boundary

[OpenFPGA](https://openfpga.readthedocs.io/en/stable/) is an architecture-generation project and is used here as educational/reference material. It is not presented as the Cyclone V implementation backend. The deploy flow is Yosys → [nextpnr-mistral](https://github.com/YosysHQ/nextpnr) / [Mistral](https://github.com/Ravenslofty/mistral) → [openFPGALoader](https://github.com/trabucayre/openFPGALoader).

Cyclone V support remains experimental upstream. The default synthesis path maps inferred memories and multiplication to logic before ALM mapping; M10K, LUT RAM, DSPs, LPDDR2, transceivers, PCIe, advanced PLLs, and other hard blocks are outside the validated v1 path.

## Verification and hardware status

The automated suite covers manifest round trips, safe paths, QSF validation, port directions, diagnostics, VCD parsing, template integrity, shell-injection resistance, real Icarus simulation, and RV32I scaffold compilation.

Software build and simulation are verified on arm64 macOS. No physical C5G was available in this workspace, so USB-Blaster detection, SRAM volatility, EPCQ persistence, and a user-authored RV32I hardware deployment are intentionally **not claimed as accepted**. Run those four acceptance steps on the target board before labeling a release hardware-validated.
