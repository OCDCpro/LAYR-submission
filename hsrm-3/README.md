# hsrmteam3 — Iterative AES ASIC with CMAC Authentication and SPI Interface

This submission implements a hardware-based cryptographic system realized as an ASIC on the IHP SG13G2 open PDK. At its core is an iterative AES-128 core (one round function reused across multiple clock cycles) that is extended by a CMAC-based authentication module implementing the hardware side of a Java Smartcard authentication protocol, and a SPI master used to talk to the external keycard/peripheral. A pseudo-random Alternating Step Generator supplies the challenges used during authentication. Details on the architecture, the design flow and the verification results are documented in the accompanying paper.

The submission is split into three directories: `docu/` for the written report, `src/verilog/` for the RTL sources, and `tapeout/` for the physical implementation outputs.

## docu/

`LAYR_25-26_chip_Design_hsrmteam3.pdf` is the project report. It covers the theoretical background of AES and CMAC, the overall system architecture, the design and implementation of each module (AES core, CMAC/authentication FSM, ASG, SPI), the LibreLane-based RTL-to-GDS flow, the verification approach, and the achieved timing/latency results, including the errors encountered during development (e.g. the key-schedule and final-round MixColumns bugs) and how they were resolved.

## src/verilog/

Synthesizable Verilog sources for the design. There is no separate top-level wrapper file in this directory; the modules below are integrated according to the architecture described in the report.

- **`AesIterative.v`** — the AES-128 core. Generated with SpinalHDL and translated to synthesizable Verilog, it implements an iterative architecture that reuses a single round function (SubBytes, ShiftRows, MixColumns, AddRoundKey) across multiple clock cycles, supporting both encryption and decryption via `io_decrypt`.
- **`CMAC_DEA.v`** — contains the `cmac_handshake` module, the authentication FSM that drives the CMAC-based Java Smartcard authentication protocol (challenge reception, AES-based decrypt/encrypt of the challenge, response generation, and the resulting `lock_state`). It owns the SPI interface used to communicate with the keycard.
- **`ASG.v`** — the Alternating Step Generator. Combines the three LFSRs below to produce the pseudo-random bytes used as authentication challenges; register initialization is done via dedicated load/seed control signals.
- **`LSFR.v`**, **`LSFR_1.v`**, **`LSFR_2.v`** — the three individual LFSR building blocks instantiated by `ASG.v`. They share the same interface and differ only in register width (31, 127, and 89 bits respectively) and tap positions.
- **`SPI_Master.v`** — a parameterizable, mode-configurable (SPI mode 0–3) SPI master that shifts bytes out on MOSI and in on MISO; it does not manage chip-select itself.
- **`SPI_Master_With_Single_CS.v`** — wraps `SPI_Master.v` and adds single chip-select handling for arbitrary-length byte transfers. This is the instance used by `CMAC_DEA.v` to communicate with the external peripheral.

## tapeout/

The LibreLane flow that produced the layout for IHP SG13G2, together with its inputs and outputs. It is split into three subdirectories: `src/` for the RTL that was actually hardened, `librelane/` for the flow configuration, and `klayout/` for the resulting layout artifacts.

**`gdsfill_config.yaml`** — configuration for the metal-fill step run on Metal4/Metal5 (Track/Square algorithm, 55% target density) to satisfy the PDK's density rules; this sits alongside `librelane/` because it is consumed by a separate fill pass rather than by the LibreLane flow itself.

### tapeout/src/

The RTL actually used for synthesis, plus the chip-level wrapper. `ASG.v`, `AesIterative.v`, `CMAC_DEA.v`, `LSFR.v`, `LSFR_1.v`, `LSFR_2.v`, `SPI_Master.v` and `SPI_Master_With_Single_CS.v` are identical copies of the modules from `src/verilog/`, kept here so the tapeout directory is self-contained and pinned to the exact sources that were hardened.

- **`chip_top.sv`** — the pad-ring top level (module `hsrmteam3`, referenced by `DESIGN_NAME` in `librelane/config.yaml`). It instantiates the IHP SG13G2 IO pad cells (power/ground, clock, reset, 8 input and 10 output pads) and wires `cmac_handshake` (from `CMAC_DEA.v`) directly to them — `input_PAD[0]` and `[1]` carry `in` and `i_SPI_MISO`, `output_PAD[0..3]` carry `lock_state`, `o_SPI_Clk`, `o_SPI_MOSI` and `o_SPI_CS_n`; the remaining, unused input/output pads are tied off.
- **`chip_top.sdc`** — the timing constraints for `hsrmteam3`, driven by the `CLOCK_PORT`/`CLOCK_PERIOD` etc. environment variables set in `librelane/config.yaml` (identical to `librelane/chip_top.sdc`; this is the copy actually picked up by the flow via `PNR_SDC_FILE`/`SIGNOFF_SDC_FILE`).
- **`chip_core.sv`** and **`otop.v`** — leftover files from the LibreLane project template (a placeholder counter design and an unrelated padframe example). Neither is listed in `VERILOG_FILES` in `librelane/config.yaml`, so neither is part of the hardened design; they are kept only for reference.

### tapeout/librelane/

- **`config.yaml`** — the LibreLane flow configuration: design name and source file list, the padring assignment (`PAD_SOUTH`/`PAD_EAST`/`PAD_NORTH`/`PAD_WEST`), clock port/period (45 ns), die/core area, placement density, power-distribution-network (PDN) settings including the core ring, and the bondpad overrides/extra GDS-LEF inputs.
- **`chip_top.sdc`** — same timing-constraints file as `tapeout/src/chip_top.sdc` (see above).
- **`pdn_cfg.tcl`** — the OpenROAD PDN script referenced by the flow; defines the stdcell power grid, stripes and core ring, and adds the dedicated power-grid connections for the two SRAM macros instantiated in the design.
- **`erase_m2m3_fill.py`** — a standalone KLayout script (`klayout -zz -r erase_m2m3_fill.py <gds>`) used to strip metal-fill shapes from the GDS after the fact, independent of the main flow.

### tapeout/klayout/

- **`klayout_gds.zip`** — contains `klayout_gds/hsrmteam3.klayout.gds`, the final GDSII layout of the chip produced by the flow.
- **`drc.magic.lyrdb`** — the Magic DRC report/database generated while checking the layout against the PDK design rules.
- **`sg13g2.lyp`** — the KLayout layer properties file for the IHP SG13G2 PDK, needed to inspect `hsrmteam3.klayout.gds` with the correct layer names and colors in KLayout.
