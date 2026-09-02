# Toolchain source modifications

FPGA Studio preserves its small third-party source changes as ordinary patches so release binaries are reproducible and upstream authors receive clear attribution. Apply each patch to the exact base revision listed below with `git apply`.

| Patch | Upstream and base revision | Purpose |
| --- | --- | --- |
| `nextpnr-mistral-apple-clang.patch` | `YosysHQ/nextpnr@8dbcee5c3c4415770b6fd06d5ccb2db89545b8ec` | Resolve Apple Clang integer-template type mismatches in the Mistral packer. |
| `mistral-macho-data.patch` | `Ravenslofty/mistral@d509238a203aadbb76291ab06543a401df91cf54` | Embed generated device data in Mach-O objects on macOS instead of relying on GNU `ld -b binary`. The accompanying helper is `bin_to_macho_asm.py`. |
| `ghdl-yosys-plugin-ghdl6.patch` | `ghdl/ghdl-yosys-plugin@50420290404d392f1cdabb80c86a312907e995c3` | Remove the obsolete `Sname_Index` branch for the GHDL 6 API. |

The patches do not change the upstream licenses. See [`../THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md).
