# Contributing to FPGA Studio

Thanks for helping test and improve FPGA Studio. The project currently targets Apple silicon and macOS 15 or newer.

## Get started

1. Ask the repository owner for private-repository collaborator access.
2. Clone the repository and open a Terminal in the checkout.
3. Run `swift test`.
4. Run `swift run FPGAStudio`, or build a signed development bundle with `./scripts/package-app.sh`.

Icarus Verilog and Verilator enable the integration tests and development simulation flow. Yosys, GHDL with the Yosys plugin, nextpnr-mistral/Mistral, and openFPGALoader are required to exercise the complete Cyclone V build and programming flow.

End-user releases must be packaged with the signed bootstrap described in the README. Never commit or share `Toolchains/toolchain-signing.key`. A release app containing `Toolchains/bootstrap.zip` without the matching signed manifest is intentionally rejected by the packaging script.

Keep `THIRD_PARTY_NOTICES.md`, `ThirdPartyLicenses/`, and `ToolchainPatches/` current whenever a bundled dependency, version, or local source modification changes. Upstream copyright and license notices must never be removed from release artifacts.

## Proposing a change

- Create a focused branch from `main`.
- Keep generated `.build`, `dist`, `.fpga`, toolchain archives, signing materials, and local environment files out of Git.
- Add or update tests for behavior changes.
- Run `./scripts/check-secrets.sh` and `swift test` before opening a pull request.
- Explain whether the change was software-tested, simulator-tested, or tested on physical C5G hardware.

Do not mark a hardware path validated without recording the board, device, programmer, artifact hash, and observed result.

## Reporting problems

Use a GitHub issue for reproducible bugs and feature requests. For vulnerabilities or accidental credential exposure, follow [SECURITY.md](SECURITY.md) instead of opening a public issue.
