# LAYR Guardian — HM team 2 (`hmteam2`)

An RFID access-control ASIC for the LAYR Open Chip Challenge 25/26,
taped out on the IHP SG13G2 open PDK with LibreLane. The chip drives an
MFRC522 contactless reader and a serial EEPROM over one shared SPI bus,
runs the LAYR Authenticated Identification Protocol (security level 1:
mutual challenge–response with an on-die AES-128 core) against an
ISO/IEC 14443-A keycard, compares the recovered card identity with the
one provisioned in the EEPROM, and drives three status pins for a door
controller. Developed in a two-week block course at Hochschule München;
see [docs/process.md](docs/process.md).

The submission is split into [docs/](docs/) for the documentation,
[src/](src/) for the RTL and the testbench, and [tapeout/](tapeout/)
for the physical-implementation inputs. The RTL is kept in one place;
the LibreLane configuration references `src/rtl/` directly.

## docs/

| File | Content |
|---|---|
| [architecture.md](docs/architecture.md) | Block diagram, module table, `start`/`done` control style, clock and reset, SPI bus sharing, per-module notes, timing summary |
| [protocol.md](docs/protocol.md) | `main_fsm` state diagram and table, EEPROM memory map, MFRC522 initialisation registers, 14443-A activation, failure counters. Card-protocol details are referenced to the challenge specification |
| [integration.md](docs/integration.md) | QFN-24 pinout in LAYR numbering, hardware used, clock limits from STA, reset/power-on/init behaviour, status-pin encoding, `user_io` bring-up taps, error handling |
| [security.md](docs/security.md) | Trust boundaries, assets, threat table with mitigations and residual risks, design choices, level claim |
| [verification.md](docs/verification.md) | Verification plan, in-tree cocotb bench, development benches, SPI physical-layer probe, Proxmark RF trace of the full exchange, FPGA bring-up, gaps |
| [physical.md](docs/physical.md) | LibreLane flow and configuration, floorplan and pad ring, sign-off results (STA at three corners, IR drop, power, cell count, antenna, XOR, density) |
| [evaluation.md](docs/evaluation.md) | Practical assessment, known limitations with file references, future improvements, sustainability, feedback for LAYR |
| [process.md](docs/process.md) | Team and supervisor, project context, approach, development environment |
| [img/](docs/img/) | Whiteboard sketch, layout screenshot, Proxmark traces (`proxmark_verification.html` is the annotated level-1 capture), FPGA flow diagram |

## src/

[src/rtl/](src/rtl/) — the Verilog as taped out. Top module `hmteam2`
in [top.v](src/rtl/top.v) is the pad frame; all logic is in
[chip.v](src/rtl/chip.v) and the modules it instantiates:
`main_fsm.v` (protocol sequencer), `rc_controller.v` (MFRC522 driver),
`eeprom_controller.v`, `aes128.v`, `spi_master.v`, `lfsr64.v`,
`output_controller.v`. `heartbeat.v`, `out_fsm.v` and `spi_selector.v`
are listed in the flow configuration but not instantiated
([docs/architecture.md §3](docs/architecture.md#3-modules)).

[src/tb/](src/tb/) — [test_output_controller.py](src/tb/test_output_controller.py),
the cocotb bench for `output_controller` (RTL and mapped-netlist
variants; the netlist variant expects flow outputs that are not part
of this submission).

## tapeout/

[tapeout/librelane/config.yaml](tapeout/librelane/config.yaml) — the
LibreLane configuration used for the tapeout: design name, source list
(pointing to `src/rtl/`), clock (`CLOCK_PERIOD = 10 ns` on
`sys_clk_PAD`), die and core area, PDN core ring, pad-ring assignment
(`PAD_NORTH/EAST/SOUTH/WEST`), bondpad macros and disabled checker
steps. The PDK is selected on the command line:
`librelane --pdk ihp-sg13g2 config.yaml`, run from this directory
inside the Nix dev shell.

[tapeout/ip/bondpad/](tapeout/ip/bondpad/) — `bondpad_70x70` and
`bondpad_70x70_novias` GDS + LEF, merged via `EXTRA_GDS` /
`EXTRA_LEFS`.

Sign-off numbers from this configuration are in
[docs/physical.md §4](docs/physical.md#4-sign-off-results).

## Supplementary

- [flake.nix](flake.nix) / [flake.lock](flake.lock) — Nix dev shell
  that pins LibreLane (commit `e73adbd`) and the simulation tools used
  for the bench.
- [LICENSE](LICENSE) — Apache-2.0. Bondpad cells and PDK-derived files
  carry their own licenses (IHP Open PDK, Apache-2.0).

## Summary

| | |
|---|---|
| Security level | 1 — LAYR Authenticated Identification Protocol, AES-128 on die |
| Process / flow | IHP SG13G2, LibreLane (Nix-pinned) |
| Die / core | 2699 × 2699 µm / 1943 × 1943 µm, 24 pads, LAYR QFN-24 pad frame v2.0, no signal-pad deviations |
| Clock | `CLOCK_PERIOD = 10 ns`, single domain, no PLL |
| Timing | typ/fast corners clean; slow corner (1.08 V, 125 °C) WNS −2.88 ns |
| Power / cells | ≈ 23 mW (typ, STA estimate), 29.6 k standard cells, 11 % utilisation |
| Verification | cocotb (`output_controller`, RTL + netlist), FPGA bring-up with kit reader and card, RF trace of the full level-1 exchange |
| Known gaps | one authorised ID; LFSR nonces with fixed seed; no SCA/FI countermeasures; slow-corner timing; `rc_init_done` without a reader — [docs/evaluation.md §2](docs/evaluation.md#2-known-limitations) |

## Team

Valentin Buttner, Florian Herrnberger, Emilia Jaser, Felix Kreil,
Julian Rapp — Hochschule München.
Supervisor: [Prof. Dr. Stefan Wallentowitz](https://hm.edu/kontakte_de/contact_detail_38978.de.html).
