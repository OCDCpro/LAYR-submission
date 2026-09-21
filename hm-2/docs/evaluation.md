# Evaluation, limitations, outlook

## 1. Practical assessment

For the scenario the challenge describes — one authorised card, one
door, reader and EEPROM on a shared SPI bus — the design works on the
FPGA prototype with the kit hardware, and the RF exchange was recorded
against the real card ([verification.md](verification.md) §3.4).

| Aspect | Assessment |
|---|---|
| False accept | requires the PSK; 2⁻⁶⁴ chance per attempt without it |
| False reject | card mis-reads at the edge of the field lead to a FAULT hold |
| Recovery | soft reset after `MAX_FAILURES` failures; no power cycle needed |
| Integration | 3 status lines, 1 lock line, SPI; no firmware; 32 EEPROM bytes of configuration |
| Timing | 100 MHz at nominal conditions; slow-corner timing not closed ([physical.md](physical.md) §4) |
| Power | ≈ 23 mW at 100 MHz, typ corner (post-route STA estimate) |
| Silicon | pad-limited: die 2699 × 2699 µm, 11 % core utilisation |

## 2. Known limitations

File/line references are to `src/rtl/`.

### Functional

| # | Limitation | Where | Note |
|---|---|---|---|
| L1 | Exactly one authorised ID; no access list | `main_fsm.v` `S_CHECK_ID` | |
| L2 | `poll_fail_count` is checked but never incremented | `main_fsm.v` | that reset trigger is unreachable; the other counters cover it |
| L3 | Failure counters are cumulative, not consecutive | `main_fsm.v` | clearing them in `S_TIMEOUT_SUCCESS` would change this |
| L4 | `rc_init_done` asserts even if no MFRC522 answers; `VersionReg` unchecked | `rc_controller.v` `I_EVAL`, `I_VER*` | no "reader absent" diagnostic |
| L5 | Software transceive watchdog counts poll iterations, not cycles | `rc_controller.v` `TMO`, `T_PCHK` | the MFRC522 hardware timer terminates stalled frames |
| L6 | `S_AES_ENC2` performs no AES; state name and header comment are outdated | `main_fsm.v` | matches the applet spec |
| L7 | `aes128.v` banner quotes outdated cycle counts | `aes128.v` | |
| L8 | `heartbeat.v`, `out_fsm.v`, `spi_selector.v` are compiled but not instantiated; `out_fsm.v` encodes an obsolete FSM | `config.yaml` `VERILOG_FILES` | |
| L9 | `IG_CP` state unreachable | `rc_controller.v` | |
| L10 | EEPROM byte 31 written twice at `eidx == 32` | `eeprom_controller.v` | harmless |
| L11 | Only `output_controller` has an in-tree testbench | `src/tb/` | [verification.md](verification.md) §4 |
| L12 | `user_io_0..4` carry FPGA bring-up taps; `main_fsm.state_out` is not wired to any pad | `chip.v` 48, 165–170, 216–219 | [integration.md](integration.md) §7 |
| L13 | Slow-corner setup violations: 307 paths, WNS −2.88 ns at 1.08 V / 125 °C, AES state-register fanout; typ and fast corners clean; no fix attempted | `aes128.v` `fsm`; [physical.md](physical.md) §4 | ≈ 77 MHz all-corner |

### Security ([security.md](security.md))

- PSK in the external EEPROM in the clear — out of scope per the
  challenge.
- LFSR nonces from a fixed seed.
- No side-channel or fault-injection countermeasures.
- `k_eph` is a concatenation, not a derivation (per spec).

### Integration

- `rst` active high; UART pads are dummy outputs; EEPROM must accept a
  single address byte.

## 3. Future improvements

1. On-die key and ID storage (OTP/eFuse or an authenticated EEPROM).
2. TRNG for `r_t`, or an LFSR state persisted across resets.
3. Access list of *n* IDs with a constant-time scan; provisioning over
   a simple command interface (the unused UART pads).
4. Masked AES for level 2; redundant FSM with illegal-state detection
   for level 3.
5. Reader-presence check via `VersionReg` and a fourth status code.
6. Tests: AES KAT, FSM bench on the tapeout RTL, Python card emulator.
7. Remove the orphan source files, fix outdated headers, clear
   counters on success.
8. Slow-corner timing: duplicate or one-hot encode the AES `fsm`
   state register; tighten `SYNTH_MAX_FANOUT`.
9. Anti-tearing: a card removed mid-`GET_ID` currently costs a full
   FAULT hold.

## 4. Sustainability

- Reproducible: `nix develop` pins LibreLane (`e73adbd`), Yosys,
  OpenROAD, Magic, KLayout, Netgen, cocotb and Icarus;
  `librelane --pdk ihp-sg13g2 config.yaml` regenerates the layout from the sources in
  this repository.
- Open PDK, open flow, Apache-2.0 license.
- Pad-limited die; additional logic fits without changing the die.
- No firmware; the behaviour is the RTL in this repository.

## 5. Feedback for LAYR

We liked the challenge and enjoyed working on it; it gave us a full
path from specification to silicon and a lot of practical learning.
The two-week time frame and the problems with our demonstrator setup
(no reference for our FPGA board, a defective reader module) made it
harder than it needed to be.

One suggestion: a more level playing field for all participants —
straightening out the small things in the kit and the provided
materials so that every team starts from the same point.
