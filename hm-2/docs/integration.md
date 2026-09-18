# Integration guide

For board designers and the LAYR demonstrator team: pinout and
deviations from the LAYR pad frame, hardware used, clock, behaviour on
reset/power-on/init, status pins, `user_io` pads, error handling.

## 1. Package and pinout

QFN-24, LAYR pad frame v2.0. Pin numbers follow the challenge table;
the pad-instance column is what `config.yaml` places.

| Pin | LAYR name | Our signal | Dir | Pad cell | Notes |
|---:|---|---|:-:|---|---|
| 1 | `rst` | `rst_in_PAD` | I | `IOPadIn` | active high, synchronised on-chip |
| 2 | `sys_clk` | `sys_clk_PAD` | I | `IOPadIn` | 100 MHz nominal |
| 3 | `uart_clk` | `uart_clk_PAD` | O | `IOPadOut30mA` | unused — driven constant 0 |
| 4 | `user_io_0` | `user_io_0_PAD` | O | `IOPadOut30mA` | heartbeat tap (§7) |
| 5 | `uart_rx` | `uart_rx_PAD` | O | `IOPadOut30mA` | unused — driven constant 0 |
| 6 | `uart_tx` | `uart_tx_PAD` | O | `IOPadOut30mA` | unused — driven constant 0 |
| 7 | `user_io_1` | `user_io_1_PAD` | O | `IOPadOut30mA` | EEPROM ID bit 127 (§7) |
| 8 | `user_io_2` | `user_io_2_PAD` | O | `IOPadOut30mA` | ID bit 126 |
| 9 | `user_io_3` | `user_io_3_PAD` | O | `IOPadOut30mA` | ID bit 125 |
| 10 | `user_io_4` | `user_io_4_PAD` | O | `IOPadOut30mA` | ID bit 124 |
| 11 | `Vdd` | `vdd_pads[1]` | P | `IOPadVdd` | core 1.2 V |
| 12 | `Vss` | `vss_pads[1]` | P | `IOPadVss` | |
| 13 | `cs_1` | `rfid_ss_n_PAD` | O | `IOPadOut30mA` | MFRC522 chip select, active low |
| 14 | `cs_2` | `eeprom_ss_n_PAD` | O | `IOPadOut30mA` | EEPROM chip select, active low |
| 15 | `spi_miso` | `spi_miso_PAD` | I | `IOPadIn` | shared |
| 16 | `spi_mosi` | `spi_mosi_PAD` | O | `IOPadOut30mA` | shared |
| 17 | `spi_sclk` | `spi_sclk_PAD` | O | `IOPadOut30mA` | shared |
| 18 | `Vss` | `vss_pads[0]` | P | `IOPadVss` | |
| 19 | `Vdd` | `vdd_pads[0]` | P | `IOPadVdd` | |
| 20 | `status_unlock` | `s_unlock_PAD` | O | `IOPadOut30mA` | lock output |
| 21 | `status_fault` | `s_fault_PAD` | O | `IOPadOut30mA` | |
| 22 | `status_busy` | `s_busy_PAD` | O | `IOPadOut30mA` | |
| 23 | `IO_Vss` | `iovss_pads[0]` | P | `IOPadIOVss` | |
| 24 | `IO_Vdd` | `iovdd_pads[0]` | P | `IOPadIOVdd` | I/O 3.3 V |

`config.yaml` places `PAD_WEST` bottom→top (pins 6→1), `PAD_SOUTH`
and `PAD_NORTH` left→right (7→12, 24→19), `PAD_EAST` bottom→top
(13→18); the layout matches the LAYR table pin for pin. The pin map in
the `chip.v` header comment is outdated; `config.yaml` is
authoritative.

Deviations from the LAYR pad frame:

1. None on the signal pads.
2. UART pins 3/5/6 are outputs driven to 0, not a UART. The challenge
   lists `uart_rx` and `uart_clk` as inputs; do not drive them from the
   board.
3. Pads 4, 7–10 carry bring-up taps (§7), not general I/O.

## 2. Hardware

From the LAYR hardware kit:

| Part | Role | Interface |
|---|---|---|
| NFC reader RC522 (NXP MFRC522) | 13.56 MHz PCD | SPI mode 0, `cs_1` |
| EEPROM AT25010B (1 kbit) on pin-header board | provisioning: ID + PSK | SPI mode 0, `cs_2` |
| LAYR JavaCard (card D used in the recorded traces) | keycard | 14443-A via reader |
| 3 × LED + resistor | `status_busy` / `status_fault` / `status_unlock` | pin high = on |
| 12 V lock, relay, DC-DC step-down, USB-C supply | actuator chain on `status_unlock` | pin high = open |

Development equipment (team-owned, not part of the kit): Digilent Arty
A7-100T (FPGA prototype), Infineon XMC4700 (C++ reference), ESP32-C3
(SPI probe), Proxmark3 RDV4 (RF sniffer).

Datasheets: [MFRC522](https://www.nxp.com/docs/en/data-sheet/MFRC522.pdf),
[AT25010B](https://ww1.microchip.com/downloads/en/devicedoc/atmel-8707-seeprom-at25010b-020b-040b-datasheet.pdf),
[LAYR JavaCard applet](https://github.com/OCDCpro/javacard-applet).

## 3. Clock

| | |
|---|---|
| Design target | `CLOCK_PERIOD = 10 ns` (100 MHz), single domain, no PLL, no derived clocks |
| Max | 100 MHz at typical/fast corners (setup slack +1.86 ns typ). Across all corners including slow (1.08 V, 125 °C) only ≈ 77 MHz closes — [physical.md](physical.md) §4 |
| Min | no hard minimum (fully static design); all timing constants are cycle counts, so verdict hold, reader-reset wait and SPI clock scale with `sys_clk` |
| Recommended | 100 MHz for the demonstrator (room temperature, nominal supply); SPI and MFRC522 timer settings were validated there. ≤ 75 MHz for all-corner operation, accepting the scaled timings |

## 4. Reset, power-on and initialisation

- `rst` is active high, sampled through a two-flop synchroniser. A
  floating-high reset line holds the chip in reset.
- Internal power-on reset: `rst_int` is held for the first 128 cycles
  after the flops leave their initial state.
- After reset release (status = RESET, `busy`+`fault`, throughout):
  1. `S_SOFT_RESET` → `S_BOOT`: clear flags and counters
  2. `S_CACHE_EEPROM`: read 32 bytes from EEPROM address 0
  3. `S_INIT_RC`: MFRC522 soft reset, `DLY50M` wait, PowerDown-bit
     poll (up to 3 retries), 9 configuration writes, antenna on
  4. `S_IDLE`: status = IDLE (all low); heartbeat on `user_io_0`;
     `user_io_1..4` show the top nibble of EEPROM byte 0

## 5. EEPROM provisioning

One `0x03 READ` with a single address byte from `0x00`, 32 bytes:

| Bytes | Content |
|---|---|
| 0–15 | authorised card ID (MSB first; byte 0 → `eeprom_id_data[127:120]`) |
| 16–31 | AES-128 pre-shared key (MSB first) |

Kit card D: ID `aa46f7689a200a24327aefdcf3a03a40`, key
`0614e9e59a36d7d9d43b80ed04b84001`. Exactly one ID is supported. The
single-byte address suits 25-series parts ≤ 256 bytes; AT25010B works.
The EEPROM is read only at boot and after a soft reset.

## 6. Status pins

| State | `busy` | `fault` | `unlock` | Meaning |
|---|:-:|:-:|:-:|---|
| RESET | 1 | 1 | 0 | boot, EEPROM read, reader init |
| IDLE | 0 | 0 | 0 | polling, waiting for a card |
| BUSY | 1 | 0 | 0 | card transaction running |
| UNLOCK | 0 | 0 | 1 | authenticated and ID matches — held `TIMEOUT_SUCCESS` cycles, then IDLE |
| FAULT | 0 | 1 | 0 | any failure after a card was detected — held `TIMEOUT_DENY` cycles, then IDLE |

`status_unlock` is a level output and drives the relay/lock via the
kit's relay board. It is never asserted together with `fault`.

## 7. `user_io` pads — bring-up taps

The five `user_io` pads carry two taps from the FPGA phase, kept in
the silicon because they are useful on a test PCB. They are not a
general debug interface; `main_fsm.state_out` is wired inside `chip.v`
but not to any pad ([evaluation.md](evaluation.md) L12).

| Pin | Pad | Source (`chip.v`) | Behaviour |
|---:|---|---|---|
| 4 | `user_io_0` | `hb_cnt[26]` | free-running toggle, period 2²⁷ cycles; held low in reset |
| 7 | `user_io_1` | `eeprom_id_data[127]` | EEPROM byte 0, bit 7 |
| 8 | `user_io_2` | `eeprom_id_data[126]` | bit 6 |
| 9 | `user_io_3` | `eeprom_id_data[125]` | bit 5 |
| 10 | `user_io_4` | `eeprom_id_data[124]` | bit 4 |

Plain CMOS outputs (`sg13g2_IOPadOut30mA`); an LED with a resistor or
a scope probe suffices. Nothing on the board may drive them.

Test-PCB use:

- Pin 4 → LED: blinking means the chip is clocked and out of reset;
  stuck low means no clock, `rst` held high, or no core power.
- Pins 7–10 → LEDs or test points: show the upper nibble of EEPROM
  byte 0, MSB on pin 7; `0000` until `S_CACHE_EEPROM` completes.
  Card D (`0xAA`) → `1010`. All zero with a non-zero nibble expected:
  EEPROM not answering (`cs_2`, MISO, part/address width). Wrong
  pattern: MOSI/MISO swapped or byte order. The chip does not
  otherwise report an EEPROM read failure.
- Bring-up order: heartbeat → nibble → status pins leave RESET →
  `status_busy` on a card → UNLOCK / FAULT.
- Deployment: pins 7–10 expose four bits of the authorised ID; keep
  them on-board. Do not build board logic on these pins. Leaving all
  five unconnected is fine.

## 8. Error handling

| Condition | Behaviour |
|---|---|
| No card | IDLE, REQA every poll |
| Card leaves the field mid-transaction | MFRC522 timer IRQ → frame error → FAULT, `auth_fail_count`++ |
| Activation fails (anticollision/SELECT/RATS) | back to IDLE, `card_init_fail_count`++ (no FAULT hold) |
| Wrong PSK on card (`C₁` padding check fails) | FAULT |
| Card rejects `AUTH` (no `90 00`) | FAULT |
| ID mismatch | FAULT |
| `MAX_FAILURES` cumulative failures in any counter since boot | soft reset: RESET pattern, EEPROM re-read, reader re-init |
| Reader absent | init reports success anyway (known gap); polls fail; chip stays IDLE, never unlocks |
| `rst` held high | RESET pattern, lock closed |
