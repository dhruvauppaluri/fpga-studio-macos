# Third-Party Software Notices

FPGA Studio distributes unmodified or minimally patched open-source tools and runtime libraries so end users can simulate and build FPGA designs without installing a separate package manager. These projects remain the work of their respective authors and copyright holders. FPGA Studio does not claim ownership of them, and their inclusion does not imply endorsement.

The corresponding license texts are in [`ThirdPartyLicenses/`](ThirdPartyLicenses/). The same notice and license directory are included in the application, toolchain archive, and DMG. Source links below identify the upstream versions used to build toolchain release `2026.09.1`; FPGA Studio's small macOS compatibility changes are recorded in [`ToolchainPatches/`](ToolchainPatches/README.md).

## FPGA tools

| Component | Bundled version or revision | Copyright/project credit | License |
| --- | --- | --- | --- |
| [Yosys](https://github.com/YosysHQ/yosys/tree/v0.68) and `yosys-abc` launcher | 0.68+post, Yosys `c12172fbae8af5e20f6fb52e3d4e92d56ed587b6` | YosysHQ and Yosys contributors | ISC |
| [Berkeley ABC](https://github.com/berkeley-abc/abc) | ABC 1.01, bundled through Yosys | The Regents of the University of California and ABC contributors | Berkeley permissive license |
| [nextpnr](https://github.com/YosysHQ/nextpnr/tree/8dbcee5c3c4415770b6fd06d5ccb2db89545b8ec), Mistral architecture | `8dbcee5c3c4415770b6fd06d5ccb2db89545b8ec` plus documented portability patch | YosysHQ and nextpnr contributors | ISC |
| [Mistral](https://github.com/Ravenslofty/mistral/tree/d509238a203aadbb76291ab06543a401df91cf54) | `d509238a203aadbb76291ab06543a401df91cf54` plus documented Mach-O build patch | Mistral authors and contributors | BSD-3-Clause |
| [openFPGALoader](https://github.com/trabucayre/openFPGALoader/tree/v1.1.1) | 1.1.1 | openFPGALoader authors and contributors | Apache-2.0 |
| [Icarus Verilog](https://github.com/steveicarus/iverilog/tree/v13_0) | 13.0 | Stephen Williams and Icarus Verilog contributors | GPL-2.0-or-later and LGPL-2.1-or-later components |
| [Verilator](https://github.com/verilator/verilator/tree/v5.050) | 5.050 | Wilson Snyder and Verilator contributors | LGPL-3.0-only OR Artistic-2.0 |
| [GHDL](https://github.com/ghdl/ghdl/tree/v6.0.0) | 6.0.0, `e589c698c` | Tristan Gingold and GHDL contributors | GPL-2.0-or-later; some runtime and IEEE library files have their own notices |
| [GHDL-Yosys plugin](https://github.com/ghdl/ghdl-yosys-plugin/tree/50420290404d392f1cdabb80c86a312907e995c3) | `50420290404d392f1cdabb80c86a312907e995c3` plus documented GHDL 6 compatibility patch | GHDL-Yosys plugin contributors | GPL-3.0-only |

## Bundled runtime libraries

| Component | Bundled version | Copyright/project credit | License |
| --- | --- | --- | --- |
| [Boost](https://www.boost.org/) | 1.92.0 | Boost authors and contributors | BSL-1.0 |
| [libftdi1](https://www.intra2net.com/en/developer/libftdi/) | 1.5 | Intra2net and libftdi contributors | LGPL-2.1-only for the bundled C library |
| [libusb](https://libusb.info/) | 1.0.30 | libusb authors and contributors | LGPL-2.1-or-later |
| [GNU Compiler Collection runtime libraries](https://gcc.gnu.org/gcc-14/) (`libgcc_s`, `libgnat`) | GNAT/GCC 14.2 runtime | Free Software Foundation and GCC contributors | GPL-3.0-or-later WITH GCC Runtime Library Exception 3.1 |
| [XZ Utils/liblzma](https://tukaani.org/xz/) | 5.8.3 | The Tukaani Project and XZ Utils contributors | 0BSD for the bundled `liblzma`; the distribution contains other separately licensed files |
| [GNU Readline](https://tiswww.case.edu/php/chet/readline/rltop.html) | 8.3.3 | Free Software Foundation and Readline contributors | GPL-3.0-or-later |
| [Tcl](https://www.tcl-lang.org/) | 9.0.4 | Regents of the University of California, Sun Microsystems, Scriptics, ActiveState, and contributors | Tcl license |
| [LibTomMath](https://www.libtom.net/LibTomMath/) | 1.3.0 | LibTomMath authors and contributors | Unlicense/public-domain dedication |
| [Zstandard](https://github.com/facebook/zstd/tree/v1.5.7) | 1.5.7 | Meta Platforms and Zstandard contributors | BSD-3-Clause for the bundled library |

Apple frameworks and system libraries supplied by macOS are not redistributed in the toolchain archive.

## Source availability

Exact upstream source is available from the versioned links above. The repository preserves every local source modification as a reviewable patch in `ToolchainPatches/`. Recipients may rebuild, replace, or redistribute the third-party components under their respective licenses. For a copy of any corresponding source used for an FPGA Studio release, open a repository issue or contact the repository owner.

This notice is informational and is not a substitute for the complete license texts or legal advice.
