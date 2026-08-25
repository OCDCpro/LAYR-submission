# System Architecture

## Overview

This chip (top module `hsrmteam3`, `tapeout/src/chip_top.sv`) is a hardware-based cryptographic authentication system for a symmetric-key keycard. Rather than a general-purpose processor, it is a single authentication finite-state machine (`cmac_handshake` in `CMAC_DEA.v`) that drives an external keycard over SPI using a fixed pre-shared key, an iterative AES-128 core, and an Alternating-Step-Generator PRNG, and exposes a single `lock_state` output that unlocks once the keycard has proven its identity.

This document describes how `cmac_handshake` and its submodules work; the theoretical background and RTL-to-GDS flow are covered in `docu/`.

## Top-Level Interface (chip pins)

`hsrmteam3` is the top module; its ports are the chip's external interface (`chip_top.sv`):

| Signal | Dir | Description |
|---|---|---|
| `clk_PAD` | in | System clock, feeds `cmac_handshake.clk` |
| `rst_n_PAD` | in | Reset pad, feeds `cmac_handshake.rst` directly — see the reset-polarity note below |
| `input_PAD[0]` | in | `in` — external trigger that starts an authentication attempt (`cmac_handshake.in`) |
| `input_PAD[1]` | in | `i_SPI_MISO` — SPI data in from the keycard |
| `input_PAD[7:2]` | in | Unused; only referenced by a `(* keep *)` linting wire, not connected to any logic |
| `output_PAD[0]` | out | `lock_state` — 0 = locked, 1 = unlocked |
| `output_PAD[1]` | out | `o_SPI_Clk` — SPI clock to the keycard |
| `output_PAD[2]` | out | `o_SPI_MOSI` — SPI data out to the keycard |
| `output_PAD[3]` | out | `o_SPI_CS_n` — SPI chip select (active low) |
| `output_PAD[9:4]` | out | Unused, tied to `0` |
| `VDD` / `VSS` | pwr | Core power / ground |
| `IOVDD` / `IOVSS` | pwr | IO-ring power / ground |

Only 2 of the 8 input pads and 4 of the 10 output pads are used (`AES_INPUTS_USED = 2`, `AES_OUTPUTS_USED = 4` in `chip_top.sv`); the rest are reserved padring capacity from the chip template and are tied off.

## Design Model: a single FSM driving three shared engines

The core idea: `cmac_handshake` is one finite-state machine that walks through a fixed authentication protocol, delegating cryptography and randomness to three engines it owns:

- an **AES-128 core** for all encrypt/decrypt operations (with a pre-shared key, then with a session key derived from both sides' challenges),
- a **SPI master** for the keycard link,
- an **Alternating Step Generator** for the chip's own 8-byte challenge.

There is no instruction memory or general datapath — every step of the protocol is a hand-coded state in the FSM below.

## Module hierarchy

```
hsrmteam3 (chip_top.sv, top)                 ── IHP IO pads + wiring
└── cmac_handshake            (CMAC_DEA.v)   ── authentication FSM (core design)
    ├── SPI_Master_With_Single_CS (spi_inst) ── SPI link to the keycard
    │   └── SPI_Master
    ├── AesIterative               (AES1)    ── AES-128 core (encrypt/decrypt)
    └── ASG                        (asg1)    ── Alternating Step Generator
        ├── LSFR    (R1)                     ── 31-bit control register
        ├── LSFR_1  (R2)                     ── 127-bit generator register
        └── LSFR_2  (R3)                     ── 89-bit generator register
```

## The Authentication FSM (`cmac_handshake`)

### States

| State | # | Role |
|---|---|---|
| `S0` IDLE | 0 | Waits for `in`; `lock_state` held low (locked). On `in`, loads the `AUTH_INIT` APDU header and moves to `S1`. |
| `S1` REC_CHALLENGE | 1 | Sends `CLA=0x80 INS=0x10 (AUTH_INIT) 00 00` over SPI; captures the 16-byte encrypted response (`cAuthInit`) into `rx_buf`. |
| `S2` GEN_CHALLENGE | 2 | Decrypts `cAuthInit` with the pre-shared key (`preSharedKey`) on the AES core; the upper 8 bytes of the plaintext become `rec_Challenge`, the card's challenge. |
| `S3` STORE_EPH_KEY | 3 | Samples 64 bits from the ASG into `own_Challenge`, builds `cAuthCmd_dec = {rec_Challenge, own_Challenge}`, and encrypts it with `preSharedKey` to get `cAuthCmd_enc`. |
| `S4` REQUEST_AUTH | 4 | Sends `CLA=0x80 INS=0x11 (AUTH)` followed by the 16-byte `cAuthCmd_enc`; captures the 16-byte encrypted response (`cAuthRes`). |
| `S5` KEYCARD_AUTHENTICATED | 5 | Derives the session key `ephKey = {own_Challenge, rec_Challenge}`, decrypts `cAuthRes` with it, and compares the plaintext against the fixed `auth_success` marker. Match → `S6`; mismatch → back to `S0`. |
| `S6` VALID_ID | 6 | Sends `CLA=0x80 INS=0x12 (GET_ID) 00 00`, decrypts the 16-byte response with `ephKey` into `rec_ID`, and compares it against the fixed `KeycardAvalidID` constant. Match → `S7`; mismatch → back to `S0`. |
| `S7` UNLOCKED | 7 | `lock_state` driven high (unlocked). A free-running 16-bit timer (`unlocked_timer`) counts up; once it wraps at `0xFFFF` the FSM auto-relocks by returning to `S0`. |

Every state transition is gated by one-cycle "flag" registers (`state2_flag0`, `state4_flag1`, …) that debounce the AES `io_done` and SPI `w_RX_DV`/CS handshakes so the FSM only advances once a sub-operation has fully completed — the same purpose the WAIT_* states serve in a more classical CPU-plus-peripheral design, just inlined per protocol step instead of being a shared set of states.

### APDU protocol constants

| Name | Value | Meaning |
|---|---|---|
| `CLA_PROPRIETARY` | `0x80` | APDU class byte used for every command |
| `INS_AUTH_INIT` | `0x10` | Request the card's encrypted challenge (`S1`) |
| `INS_AUTH` | `0x11` | Submit the combined challenge, request the auth response (`S4`) |
| `INS_GET_ID` | `0x12` | Request the card's encrypted ID once authenticated (`S6`) |

### Fixed cryptographic material

`preSharedKey`, `auth_success` (the ASCII marker `"AUTH_SUCCESS\0\0\0\0"`) and `KeycardAvalidID` are all hardcoded 128-bit constants in `CMAC_DEA.v` rather than loaded from configuration or an EEPROM. This matches the "PSK" from the protocol description in `docu/`, but means the key material is fixed in the netlist for this revision — see *Reserved Details* below.

## Peripheral & Crypto Subsystems

### AES-128 core

`AesIterative.v` is a single, unmasked iterative AES-128 core (`io_start`/`io_decrypt`/`io_key`/`io_dataIn` in, `io_dataOut`/`io_busy`/`io_done` out), generated with SpinalHDL. `cmac_handshake` instantiates exactly one instance (`AES1`) and time-multiplexes it across the whole protocol: first with `preSharedKey` to decrypt `cAuthInit` (`S2`) and encrypt `cAuthCmd_dec` (`S3`), then with the derived `ephKey` to decrypt `cAuthRes` (`S5`) and `rec_ID` (`S6`). There is no masking or fault-protection layer around this core.

### SPI subsystem

`SPI_Master_With_Single_CS.v` wraps `SPI_Master.v` and is instantiated once (`spi_inst`), configured for SPI mode 3, 5 clocks per half-bit, a 2-byte-per-chip-select limit and 10 idle clocks between transfers. `cmac_handshake` drives it directly — there is no shared-bus arbitration since the keycard is the only SPI peripheral.

### Alternating Step Generator (ASG)

`ASG.v` implements a classical Alternating Step Generator from three LFSRs:

- **R1** (`LSFR.v`, 31-bit, taps 0/28) is the control register — it is clocked every cycle and its output bit decides which of the other two registers advances.
- **R2** (`LSFR_1.v`, 127-bit, taps 0/126) is clocked whenever `R1_newBit = 1`.
- **R3** (`LSFR_2.v`, 89-bit, taps 0/51) is clocked whenever `R1_newBit = 0`.
- The generator's output bit is `R2_newBit ^ R3_newBit`.

On reset, a dedicated init sequence (`ASG_state` in `CMAC_DEA.v`) shifts fixed seed constants (`R1_SEED`, `R2_SEED`, `R3_SEED`) into R1/R2/R3 one bit per cycle before `init_done` is asserted. Once initialized, `cmac_handshake` samples 64 output bits in `S3` to form `own_Challenge` — this is the chip's only source of randomness, and like the fixed keys above, it is seeded deterministically rather than from a physical entropy source.

## Clocking & Reset

- `clk` — single system clock for the FSM and all three engines; no separate peripheral or debug clock domain exists in this design.
- `rst` — driven from `rst_n_PAD` (see the top-level table). Internally, `cmac_handshake` treats `rst` as an **active-high**, asynchronous-assert reset (`always @(posedge clk or posedge rst) if (rst) …`); the pad's `_n` suffix follows the chip template's naming convention for that pad position and does not by itself indicate the polarity actually driven into the core — double-check board-level reset polarity against this before bring-up.

## Reserved Details / Known Limitations

- **Fixed key material.** `preSharedKey`, `auth_success` and `KeycardAvalidID` are hardcoded constants in `CMAC_DEA.v`, not provisioned per device.
- **Deterministic randomness.** The ASG is seeded with fixed constants (`R1_SEED`/`R2_SEED`/`R3_SEED`); there is no physical entropy source feeding it in this revision.
- **No masking or fault protection on the AES core.** `AesIterative.v` is a plain iterative implementation; side-channel and fault countermeasures are out of scope for this design.
- **Reset polarity naming.** `rst_n_PAD` is wired straight into an active-high `rst` port — see *Clocking & Reset* above.
- **Auto-relock timer is fixed.** The `S7` unlock window is a hardcoded 2^16-cycle count (`unlocked_timer == 16'hFFFF`), not configurable at runtime.

## Module Reference

| Module | File | Role | Instantiated in |
|---|---|---|---|
| `hsrmteam3` | `tapeout/src/chip_top.sv` | Top module: IHP IO pads + wiring | (top) |
| `cmac_handshake` | `src/verilog/CMAC_DEA.v` | Authentication FSM, owns the APDU protocol and all keys | `hsrmteam3` |
| `SPI_Master_With_Single_CS` | `src/verilog/SPI_Master_With_Single_CS.v` | Single-CS SPI master wrapper | `cmac_handshake` |
| `SPI_Master` | `src/verilog/SPI_Master.v` | Bit-level SPI master (mode 0–3) | `SPI_Master_With_Single_CS` |
| `AesIterative` | `src/verilog/AesIterative.v` | Iterative AES-128 core (encrypt/decrypt) | `cmac_handshake` |
| `ASG` | `src/verilog/ASG.v` | Alternating Step Generator (challenge randomness) | `cmac_handshake` |
| `LSFR` | `src/verilog/LSFR.v` | 31-bit LFSR — ASG control register (R1) | `ASG` |
| `LSFR_1` | `src/verilog/LSFR_1.v` | 127-bit LFSR — ASG generator register (R2) | `ASG` |
| `LSFR_2` | `src/verilog/LSFR_2.v` | 89-bit LFSR — ASG generator register (R3) | `ASG` |
