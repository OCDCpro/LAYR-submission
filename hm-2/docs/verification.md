# Verification

What was verified, how, and where the evidence is. The tapeout tree
contains one automated cocotb bench; protocol-level confidence comes
from hardware: an MFRC522, a LAYR keycard, and an RF trace recorded
with a Proxmark3 (team equipment, not part of the challenge kit).

## 1. Verification plan

| # | Feature | Method | Evidence | Status |
|---|---|---|---|---|
| V1 | SPI master bit-level behaviour (mode 0, MSB first) | cocotb loopback bench; ESP32 "ping-pong" probe | development bench (§3.2); §3.3 | sim + HW |
| V2 | EEPROM provisioning read (0x03 READ, 32 bytes, byte packing) | cocotb with SPI-slave emulator; FPGA bring-up with ID nibble on `user_io_1..4` | development bench (§3.2); [integration.md](integration.md) §7 | sim + HW |
| V3 | Chip-level boot → EEPROM cache → reader init | cocotb chip bench with EEPROM and RC522 behavioural models | development bench (§3.2) | sim (earlier module layout) |
| V4 | `main_fsm` boot sequence and happy path with stubbed peripherals | cocotb FSM bench | development bench (§3.2) | sim (level-0 FSM) |
| V5 | Status-pin decoding incl. undefined codes | cocotb, RTL and post-synthesis netlist | [`src/tb/test_output_controller.py`](../src/tb/test_output_controller.py) | sim, in tree |
| V6 | ISO/IEC 14443-A activation (REQA, anticollision, SELECT, RATS) | RF trace of the FPGA-driven MFRC522 with the LAYR card | [`img/proxmark_verification.html`](img/proxmark_verification.html) | HW |
| V7 | `SELECT AID`, `AUTH_INIT`, `AUTH`, `GET_ID` exchange | RF trace: card answers `90 00` to `AUTH` | same trace | HW |
| V8 | End-to-end on the FPGA with kit reader and card: UNLOCK for the provisioned card, FAULT otherwise | FPGA bring-up | observed on the board, §3.5 | HW |
| V9 | Corrupted / short RF frames | `ErrorReg` mask and length checks on every response | RTL review | not directly tested |
| V10 | AES-128 known-answer (FIPS-197) | — | — | missing |
| V11 | Gate-level simulation of the full chip | — | only `output_controller` (V5) | missing |
| V12 | Physical sign-off (STA 3 corners, IR, antenna, XOR) | LibreLane checkers | [physical.md](physical.md) §4 | flow |

## 2. Rationale

- A C++ reference on an XMC4700 microcontroller established the SPI
  byte sequences and timing the MFRC522 and the card need before any
  RTL was written.
- Leaf modules that are cheap to simulate (SPI master, EEPROM
  controller, output decoder) were unit-tested in cocotb with Python
  emulators for the peripherals.
- The protocol was checked on real RF rather than against a card
  model, which would have required re-implementing the applet.
- `test_output_controller.py` runs against both RTL and the mapped
  netlist; this was used to confirm that the `unknown command 'abc'`
  message in synthesis ([physical.md](physical.md) §4) has no
  functional effect.

## 3. Evidence

### 3.1 cocotb bench in the tapeout tree

`src/tb/test_output_controller.py`:

- `test_all_state_transitions` — all 25 ordered pairs of the five
  defined status codes; asserts `busy`/`fault`/`unlock` after each.
- `test_outputs_off_in_undef_state` — codes `101` and `110` drive all
  outputs low.

The netlist variant (`test_output_controller_netlist`) expects a Yosys
output under `ll_configs/runs/` and the PDK's `stdcells.v`, which are
not part of the submission.

### 3.2 cocotb benches used during development

Not part of the submission: they target the module layout as it was in
February 2026 (level-0 FSM without the `S_AUTH_*` states) and are not
claimed to pass against the tapeout RTL.

| Bench | What it does |
|---|---|
| `test_sbi_master.py` | Python SPI slave coroutine; full-duplex byte transfer, checks `done` is one cycle |
| `test_eeprom_ctrl.py` + `spi_emulator.py` | Emulated 25-series EEPROM answering `0x03` READ; checks key/ID land in the right registers |
| `test_chip.py` + `eeprom_model.v` + `rc522_model.v` | Whole-chip boot with behavioural MFRC522 (register file, FIFO, card-present) and EEPROM models; monitors lock/LED outputs |
| `test_main_fsm.py` | Enum-mirrored FSM states; `test_boot` walks BOOT→CACHE_EEPROM→INIT_RC→IDLE; `test_successful_card` drives the handshakes to TIMEOUT_SUCCESS with card A's ID |

### 3.3 ESP32 SPI "ping-pong" probe

Before connecting the MFRC522, an ESP32-C3 running a DMA SPI slave was
wired to the Arty A7's PMOD. Fixed 16-byte frames: the FPGA sends a
string, the ESP32 answers with a random printable string, the FPGA
copies RX→TX and sends it back on the next round. A correct echo
exercises MOSI, MISO, clock generation and the copy path at real edge
rates. Not part of the submission.

### 3.4 Proxmark RF trace

Recorded with a Proxmark3 RDV4 (Iceman firmware; team equipment)
between the FPGA-driven MFRC522 and LAYR card D:
[`img/proxmark_verification.html`](img/proxmark_verification.html).
Excerpt:

```
Rdr | 26(7)                                   | REQA
Tag | 08 00                                   | ATQA
Rdr | 93 20                                   | ANTICOLL
Tag | AF 8B EF 79 B2                          | UID + BCC
Rdr | 93 70 AF 8B EF 79 B2  FC 46             | SELECT (CRC ok)
Tag | 20  FC 70                               | SAK
Rdr | E0 50  BC A5                            | RATS FSDI=5 CID=0
Tag | 0A 78 80 91 02 80 73 C8 21 10  C3 92    | ATS
Rdr | 02 00 A4 04 00 06 F0 00 00 0C DC 01     | SELECT AID
Tag | 02 90 00                                | ok
Rdr | 03 80 10 00 00 10                       | AUTH_INIT
Tag | 03 A2 DC 05 … 5B B2 90 00               | C₁
Rdr | 02 80 11 00 00 10 18 B8 2B … 6A 5F      | AUTH, C₂
Tag | 02 05 1F 68 … 45 90 00                  | 90 00
Rdr | 03 80 12 00 00 10                       | GET_ID
Tag | 03 CF 0C F6 … D7 92 90 00               | C₃
```

`90 00` after `AUTH` indicates the card accepted `C₂`, i.e. the chip
decrypted `C₁` and encrypted `r_t ‖ r_c` under the correct PSK. The
level-0 predecessor trace (cleartext `GET_ID`, card D's ID visible on
the air) is in [`img/proxmark_level0.png`](img/proxmark_level0.png).

### 3.5 FPGA bring-up

Arty A7-100T, `chip` module (everything below the pad frame), 100 MHz
board clock, LEDs on `user_io_0`, `user_io_1..4` and the status pins,
kit reader and card. The provisioned card produced UNLOCK, other cards
FAULT, as expected. The RTL that
taped out is the RTL that ran on this board; `top.v` (pad frame) is
the only addition.

## 4. Gaps

1. AES-128 known-answer test (FIPS-197 App. B/C), both directions.
2. `main_fsm` bench against the tapeout RTL with stubbed peripherals:
   happy path, each failure exit, five-failure soft reset.
3. Card emulator in Python driven through the existing `rc522_model.v`
   for an automated end-to-end simulation, including wrong-PSK and
   wrong-ID cards.
4. Gate-level run of that test on the LibreLane netlist.
5. Directed corrupted-frame tests (bad CRC, short ATS, missing
   `90 00`).
