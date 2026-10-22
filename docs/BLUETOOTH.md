# Bluetooth controllers without BTstack

The ESP32 firmware (`esp32/console`) reads Bluetooth pads through Bluepad32, and Bluepad32 runs
on BTstack. BTstack's licence allows use "for personal benefit and not for any commercial
purpose". This project is GPL-3 and the consoles are meant to be sold, so BTstack has to go
before any are sold. This page covers what replaces it, why, what it costs, and what is still
to be checked on a board.

**Status (2026-10-22): works on the board with a DualShock 4; still opt-in.** The Bluedroid
backend covers DualShock 4, DualSense, Switch Pro and Xbox (BLE and old Classic firmware):
pairing, reconnecting, two players, PS/Home and rumble. On the board (T8, 2026-10-21):

- the whole firmware on IDF 5 works: the fast link (0 errors at 10 MHz), cartridges, a PS1 disc
  with XA audio, a DOS game from the card;
- a DualShock 4 pairs (SHARE + PS), comes back with PS alone, and drives the games;
- internal RAM: about 10.5 kB free at the lowest with Doom running and the pad connected
  (16 kB with no pad), steady.

Open: Doom felt "sticky" with the pad. The loop that turns the pad into keys runs every ~30 us
(2 ms at worst), so the suspect is the link going into sniff mode (reports in bursts). The
firmware now keeps the links active (`btactive on|off` switches it live; `pads` shows the report
spacing and the link mode) -- to be measured with the pad. DualSense, Switch Pro and Xbox are
untried. Bluepad32 stays the default build until these are done.

## 1. Assessment

### Which stack

| Option | Licence | Classic (DS4/DS5/Switch) | BLE (Xbox) | Builds with arduino-cli as is |
|---|---|---|---|---|
| Bluepad32 on BTstack (today) | Apache-2.0 on **non-commercial** BTstack | yes | yes | yes (esp32-bluepad32 fork) |
| ESP-IDF Bluedroid + `esp_bt_hid_host` (the public Classic HID host) | Apache-2.0 | yes | - | **no**: compiled out of every stock arduino-esp32 build |
| **ESP-IDF Bluedroid + our HID host on Bluedroid's L2CAP + `esp_hidh` for BLE** | Apache-2.0 (+ ours, GPL-3) | yes | yes | **yes**: stock `esp32:esp32` 3.3.11 |
| NimBLE | Apache-2.0 | no Classic at all | yes | - |
| Our own host over VHCI (HCI, L2CAP, SSP, bonding) | ours | yes, but a whole stack to write and keep working | yes | yes |

What is actually in the libraries (checked in the installed packages and with `nm`):

- **esp32-bluepad32 4.1.0** (today's platform) is arduino-esp32 2.0.x on ESP-IDF 4.4, with
  BTstack built in and `CONFIG_BT_BLUEDROID_ENABLED` **off**. Bluedroid is not available on it.
- **Stock `esp32:esp32` 3.3.11** (already installed in this setup) is ESP-IDF **v5.5.5**
  (b774170ff46). Bluedroid is on, and so are Classic, BLE and the GATT client. But
  `CONFIG_BT_HID_ENABLED` and `CONFIG_BT_L2CAP_ENABLED` are **off**, so `libbt.a` has neither the
  public Classic HID host (`esp_bt_hid_host_*`) nor the public L2CAP API (`esp_bt_l2cap_*`).
- Stock **2.0.17** (ESP-IDF 4.4) is the same: `# CONFIG_BT_HID_ENABLED is not set`.
- What **is** in 3.3.11's `libbt.a`: Bluedroid's internal L2CAP (`L2CA_Register`, `L2CA_ConnectReq`,
  `L2CA_ConfigReq`, `L2CA_DataWrite`, ...), the security manager (`BTM_SetSecurityLevel`),
  `BTA_DmBond`, and the BTA message system (`bta_sys_register`, `bta_sys_sendmsg`). These are what
  Bluedroid's own HID host (`stack/hid/hidh_conn.c`) is built on. `libesp_hid.a` has `esp_hidh`
  with its **BLE** host (`esp_ble_hidh_*`).

**Chosen:** stock arduino-esp32 **3.3.11**, Bluedroid, and:

- **Classic** (DS4, DualSense, Switch Pro, Xbox on old firmware): our own small HID host in
  `esp32/console/pads_bluedroid.h`, on Bluedroid's internal L2CAP, done the way `hidh_conn.c`
  does it:
  - PSMs 0x11/0x13 are registered with L2CAP.
  - `BTM_SetSecurityLevel` makes L2CAP do SSP pairing, authentication and encryption before
    it hands us a channel.
  - Every L2CAP call runs on Bluedroid's BTU task. We register as BTA subsystem 23, the HID
    host's slot, which is free because the HID host is compiled out, and post to it with
    `bta_sys_sendmsg`.
  - Discovery, pairing replies and bond removal use the public `esp_bt_gap_*` API.
  - A newly found pad is bonded with `BTA_DmBond` before its channels are opened, as BlueZ's
    "pair" then "connect" does.
  - Bluedroid stores link keys in NVS itself.
- **BLE** (Xbox Wireless Controller, firmware 5.x and later, which is BLE-only): ESP-IDF's
  public `esp_hidh` (HID over GATT), with our own BLE scan to find the pad.

Rejected: rebuilding the arduino libraries with `CONFIG_BT_HID_HOST_ENABLED`
(esp32-arduino-lib-builder) would give the public HID host API. But every build would then need
a custom platform package of a few hundred MB. Bluedroid's HID host would also still need
per-pad handling on top: it neither switches a DS4 to 0x11 reports nor a Switch Pro to 0x30.
That handling is most of the work here anyway. The L2CAP part is a few hundred lines.

### Each controller

Report layouts were checked offset by offset against Linux `hid-playstation.c`,
`hid-nintendo.c`, and SDL's `SDL_hidapi_ps4.c` and `SDL_hidapi_xboxone.c`, fetched into
`build/dl/refs` (read, not copied).

| Pad | Transport | What it needs | Code path |
|---|---|---|---|
| DualShock 4 (054C:05C4/09CC) | Classic | Starts with the 10-byte 0x01 report; GET_REPORT of feature 0x05 (Linux) or 0x02 (SDL) switches it to 0x11. Output 0x11: hw_control 0xC0 + poll interval (we ask for 8 ms), motors, lightbar, CRC-32 seeded with 0xA2. | yes |
| DualSense / Edge (054C:0CE6/0DF2) | Classic | The same 10-byte 0x01 report; feature 0x05 switches it to 0x31. Output 0x31: sequence tag, tag 0x10, lightbar + player dots, lightbar_setup "light out" to drop the start-up blue, CRC-32. | yes |
| Switch Pro (057E:2009) | Classic | Starts in 0x3F mode. Subcommands go in output 0x01, each waits for its 0x21 reply and they are spaced 70 ms apart (hid-nintendo keeps them at least 60 ms apart over Bluetooth): 0x10 SPI read of 0x603D (18 bytes: factory stick calibration), 0x03 0x30 (full reports), 0x48 0x01 (vibration), 0x30 (player light). The 12-bit sticks go through the calibration. | yes |
| Xbox Wireless (045E; One S 1708 fw 5.x, Series, Elite 2) | **BLE** | HID over GATT, bonded. Report 1: 16-bit sticks, 10-bit triggers, hat, buttons (SDL's layout). Rumble: report 3. | yes (`esp_hidh`) |
| Xbox One S on firmware 3.x/4.x | Classic | Report 0x01 of 16 or 17 bytes; Xbox button in report 0x02. | yes |
| Other pads (generic HID) | - | Not supported: there is no SDP and no HID-descriptor parser. Bluepad32 has both. | no |

Buttons are mapped by position, as Bluepad32 does: the bottom face button is "cross" on every
pad (Switch B, Xbox A), and so on.

Two players: two pad slots, any mix of Classic and BLE. A third pad is refused. The controller
allows two Classic links (`CONFIG_BTDM_CTRL_BR_EDR_MAX_ACL_CONN=2`).

A Classic pad is identified without SDP:

- **By its first input report.** A 10-byte 0x01 is Sony, which is then asked for feature 0x05;
  the reply id says DS4 (0x11) or DualSense (0x31). 0x3F/0x30/0x21 is Nintendo. A 16-20 byte
  0x01 is an old Xbox.
- **By its name.** "Pro Controller", "Wireless Controller", "Xbox Wireless Controller". The
  name comes from the inquiry while pairing, and from a remote-name request on every
  connection, because a Switch Pro sends nothing until a button is pressed.

### Features

| Feature | How |
|---|---|
| Pair a new pad | While pairing is on: Classic inquiry (6.4 s) and an active BLE scan (4 s), in turns. Pairing is on for 120 s from power-up and from the menu's "Pair a new controller", and stays on while no pad is connected. The first gamepad found is taken: Class of Device peripheral/gamepad or joystick, a known name, or a BLE advertisement with the gamepad appearance, "Xbox" in the name, or the HID service and "Controller". **Classic:** `BTA_DmBond` (SSP "just works", IO capability none; a legacy PIN request gets 0000), then the HID channels within the 3 s Bluedroid keeps the bonding link. **BLE:** `esp_hidh_dev_open`, which bonds on its first encrypted read. |
| Reconnect a paired pad | Classic: page scan is on all the time, so a bonded pad that pages us comes in on 0x11/0x13. BLE: while a bonded BLE pad is away and a slot is free, a passive scan runs at about 10% duty (30 ms every 320 ms). The bonded pad's advertisement is then connected. |
| Forget | The menu's "forget": every Classic and BLE bond removed, connected pads dropped. |
| Two players | Two slots, the same as Bluepad32's `slot[2]`. `pads::poll()`, the swap and the N64's two-pad flag are unchanged above them. |
| PS / Home | Every parser sets the home bit (PS, Home, Xbox). `poll()` turns the press into `menuPressed`, as before. |
| Rumble | `pads::rumble(player, strong, weak)` drives DS4, DualSense and Xbox. Switch HD rumble is not done. Nothing in the firmware calls it yet: no core sends rumble. |
| Battery | DS4, DualSense and Switch from their reports; Xbox from the BLE battery service. |
| Player LEDs | DS4 lightbar blue (player 1) / red (2); DualSense player dots + lightbar; Switch player light 1/2. |
| Debugging | The serial `pads` command adds Bluedroid's state, both slots (address, kind, name, L2CAP channels, report count, last report id/length, battery), the last 12 events and the free internal RAM. Events also go to the log after `log on`. |

### Licences of every piece in the Bluedroid build

| Piece | Licence |
|---|---|
| Bluedroid host (ESP-IDF `components/bt/host/bluedroid`, from Android/Broadcom) | Apache-2.0 |
| Bluetooth controller (`libbtdm_app.a`, Espressif's `esp32-bt-lib`) | Apache-2.0 (binary). It is the same controller BTstack used, over VHCI. |
| `esp_hid` (the BLE HID host) | Apache-2.0 |
| tinycrypt (in ESP-IDF's bt component) | BSD-3-Clause |
| ESP-IDF | Apache-2.0 |
| arduino-esp32 core | LGPL-2.1 |
| `pads_bluedroid.h` (ours) | GPL-3 with the project. It re-declares a few Bluedroid types and constants (Apache-2.0, credited in the file) and follows `hidh_conn.c`'s channel handling. Report formats are facts taken from Linux/SDL/dekuNukem's notes; no code from them. |

No BTstack and no Bluepad32 code is in the Bluedroid build (checked: `nm` of the ELF has no
`btstack_`/`uni_` symbols).

### RAM and flash (measured in section 3)

- Flash: **1,470,542 B** against Bluepad32's 1,111,509 B. Bluedroid with Classic + BLE + GATT is
  bigger, but `huge_app` gives 3 MB.
- Static DRAM: the Bluedroid build's heap starts **44,688 B lower** than the Bluepad32 build's
  (0x3FFD1048 vs 0x3FFDBED8). BTstack's memory pools were static. Both reserve the same 56 kB for
  the controller (`CONFIG_BTDM_RESERVE_DRAM=0xdb5c`).
- At run time Bluedroid takes some of that back in task stacks, all internal RAM pinned to
  core 0: BTU 8 kB, BTC 8 kB, HCI 2 kB, our finder task 6 kB (`esp_hidh_dev_open` runs the GATT
  discovery on it; ESP-IDF's example uses 6 kB) and esp_hidh's event task 4 kB. That is
  **28 kB of stacks**, against one BTstack task before. Bluedroid's heap allocations go through
  plain `malloc()` on IDF 5 (`osi_malloc_base`). The firmware's
  `heap_caps_malloc_extmem_enable(64)` runs before Bluetooth starts, so everything over 64 bytes
  goes to PSRAM. ESP-IDF itself offers this as `CONFIG_BT_ALLOCATION_FROM_SPIRAM_FIRST`.
  **Expected: about as much free internal RAM as today, possibly more. Not measured.** The boot
  log line `pads: Bluetooth (Bluedroid) up, internal free N` and the `pads` command show it.
- IRAM: 126,507 B of about 128 kB (Bluepad32: 119,723). It links, but there is little room left.

### Risks

1. **Internal ABI.** Bluedroid's L2CAP/BTM/BTA declarations are not in the arduino libraries'
   headers, so `pads_bluedroid.h` re-declares them. **This is checked, not assumed:**
   `tools/bt_abi/check.sh` compiles ESP-IDF v5.5.5's own headers, with the platform's
   sdkconfig, next to our copies. It fails on any difference in size, offset or constant (it
   passes; a planted mismatch fails). The header refuses to build on any ESP-IDF but 5.5.x. On a
   platform upgrade, run the check before anything else.
2. **The whole firmware moves to arduino-esp32 3.x / ESP-IDF 5.5**, not just the pads. It
   compiles with one change: the task-watchdog call, under `#if ESP_IDF_VERSION_MAJOR >= 5`. But
   none of these have run on IDF 5 on the board: the SD card, the FPGA link (`link.h` drives the
   SPI peripheral's registers), PSRAM, the 2 Mbaud serial port, the CD/XA tasks, the menu. **This
   is the biggest risk, and it has nothing to do with Bluetooth.**
3. **Pad behaviour this code has not seen**:
   - whether a pad accepts the HID channels without an SDP query (BlueZ and Bluepad32 query SDP
     first; Bluedroid's own HID host does too);
   - the Switch Pro's 0x3F stick direction (taken as HID's down-positive);
   - how an Xbox reconnects (directed advertising or not, public address or not);
   - the Xbox BLE pairing over `esp_hidh`.
4. **Radio sharing.** While pairing is on, inquiry and BLE scanning take airtime from a pad that
   is already connected: for 120 s after power-up, and after "Pair". Bluepad32 also scans while
   it accepts new pads. The low-duty reconnect scan runs only while a bonded BLE pad is away.
5. **Role.** We ask to be master of every Classic link (`L2CA_SetDesireRole`), as Bluepad32 does,
   so that two pads don't put the ESP32 in a scatternet.

## 2. Implementation

Files:

- `esp32/console/pads_bluedroid.h` (namespace `padbt`; about 1,000 lines). It holds:
  - the Bluedroid internal declarations;
  - the Classic HID host: L2CAP callbacks and the BTU-task message handler;
  - report parsers and output builders for each pad;
  - GAP/BLE-GAP callbacks;
  - the `esp_hidh` event handler;
  - the finder task (inquiry, BLE scan, bonding, BLE opens);
  - `begin/read/forget/setPairing/rumble/debug`.
- `esp32/console/pads.h`: picks the backend. The interface to the rest of the firmware is
  unchanged (`pads::Player`, `In`, `view`, `menuButtons`, `menuPressed`, `cmd`, `poll`, `begin`).
  Bluedroid pads arrive as the same button bits as the PC pad's "P" line (`fromBits`, factored
  out of `usbLine`). The serial `pads` command's Bluetooth lines moved into `pads::btDebug()`.
  `pads::rumble()` is new (Bluedroid only).
- `esp32/console/console.ino`: the IDF 5 watchdog call, and `pads::btDebug()`.
- `tools/bt_abi/`: the ABI check (above).

Threads: the BTU task runs the Classic channels and all L2CAP calls. The BTC task runs the GAP
callbacks. esp_hidh's task runs BLE reports. The finder task (core 0, priority 2) runs
discovery and BLE opens. A 50 ms `esp_timer` ticks the setup state machines (Sony feature
retries, Switch subcommands) into the BTU task while a pad is being set up. `poll()` (loop, core
1) copies the two slots under a spinlock, as before.

Selecting the backend (compile time, in `pads.h`):

| Macro | Backend |
|---|---|
| (none), building on esp32-bluepad32 | Bluepad32 (the default, unchanged) |
| (none), building on stock esp32:esp32 3.3.x | Bluedroid (the only Bluetooth stack there) |
| `PADS_BACKEND_BLUEDROID` | Bluedroid; a clear `#error` on the Bluepad32 platform (checked) |
| `PADS_BACKEND_BLUEPAD32` | Bluepad32 |
| `PADS_BACKEND_NONE` | no Bluetooth, the PC pad over USB only; the controller's memory is released |

A macro is passed with `--build-property "compiler.cpp.extra_flags=-DPADS_BACKEND_NONE"`.

Builds. Leave out `--config-file`: `tools/arduino/arduino-cli.yaml`, named in
`docs/DEVELOPMENT.md`, does not exist, and the default configuration already has the esp32
board-manager URL.

    # Bluepad32 (the default, as before)
    tools/arduino/arduino-cli.exe compile --fqbn "esp32-bluepad32:esp32:esp32:PSRAM=enabled,PartitionScheme=huge_app" --build-path build/fw-t8d esp32/console

    # Bluedroid
    tools/arduino/arduino-cli.exe compile --fqbn "esp32:esp32:esp32:PSRAM=enabled,PartitionScheme=huge_app" --build-path build/fw-t8d-bluedroid esp32/console

    # the Bluedroid declarations against the installed platform
    sh tools/bt_abi/check.sh

Pin the platform: `arduino-cli core install esp32:esp32@3.3.11` (3.3.12 is out; its ESP-IDF
must pass `check.sh` first).

## 3. Sizes (arduino-cli, 2026-10-20)

| Build | Platform (ESP-IDF) | Flash (sketch) | "Global variables" | .dram0.bss | .iram0.text | DRAM heap starts at |
|---|---|---|---|---|---|---|
| Bluepad32 (default) | esp32-bluepad32 4.1.0 (4.4) | 1,111,509 B | 123,768 B | 101,296 | 119,723 | 0x3FFDBED8 |
| **Bluedroid** | esp32:esp32 3.3.11 (5.5.5) | **1,470,542 B** | **79,080 B** | 55,992 | 126,507 | **0x3FFD1048** (44,688 B more heap) |
| no Bluetooth (`PADS_BACKEND_NONE`) | esp32:esp32 3.3.11 (5.5.5) | 681,482 B | 58,896 B | 41,344 | 75,051 | 0x3FFCC170 |

Both Bluetooth builds compile without errors. The Bluedroid one with `--warnings all` warns only
about pre-existing `%u`/`uint32_t` format mismatches in console.ino (harmless: the same width on
this chip) and one format-truncation note.

## 4. To verify on the board

Flash the Bluedroid image (`build/fw-t8d-bluedroid`), type `log on`, then reset, or just use
`pads` at any time.

1. **The firmware as a whole on IDF 5** (before any pad): menu on HDMI, the SD card read, a
   core installed and booted, a PS1 disc game (disc + XA), the PC pad over USB, `state`. All
   of this is new ground for the IDF 5 build.
2. **Boot log / `pads`:** `HID host registered`; `Bluedroid: up`; note `internal free` and compare
   it with the Bluepad32 build's `state` line. The menu task must still start.
3. **DualShock 4:** hold SHARE + PS. Expect `bonding with ...`, `pairing ok`, `calling ...`,
   `... up (we called)`, `is a PlayStation pad`, then `is a DualShock 4` (0x11 reports;
   `last 0x11/78`). The lightbar turns blue (player 1). Then check: buttons, sticks, L2/R2, PS
   opening the menu, battery in the menu. Power it off, then press PS: `up (it called)` without
   pairing.
4. **DualSense:** the same. Expect `is a DualSense` and `last 0x31/78`. The player-1 dot is lit,
   the start-up blue fades out, the lightbar is blue.
5. **Switch Pro:** hold sync. Expect `is a Switch Pro`, `switch calibration read`, the player-1
   light, `last 0x30`. Stick directions and centring (up must read up). Reconnect by pressing a
   button.
6. **Xbox (BLE firmware):** hold the pair button. Expect `opening BLE ...`, `BLE pairing ok`,
   `up (BLE, vid 045e)`, report 1 of 16 bytes. Then buttons, triggers, the Xbox button opening the
   menu. Power it off and on: it must come back (the low-duty reconnect scan).
7. **Two players:** two pads at once (e.g. DS4 + Xbox): both in the menu's pad test, and the
   swap. A third pad is refused (`no free slot`).
8. **Forget** in the menu, then re-pair.
9. Latency with two pads, during and after the 120 s pairing window.

If a step fails, the `pads` output (the last 12 events, the slot's state/step, the last report
id/length) says where it stopped.

## Progress notes

- 2026-10-21: on the board (section 4 steps 1-3 for the DS4). One pairing attempt failed with
  status 9 and the retry succeeded at once. `looptime` and `xd` serial commands added to the
  firmware; `pads` prints the report spacing and the link's power mode.

- 2026-10-20: platforms surveyed (section 1). The firmware builds on 3.3.11 with Bluetooth off
  once the watchdog call is fixed. The ESP-IDF v5.5.5 Bluetooth sources were fetched (sparse)
  into `build/dl/esp-idf-v5.5.5` for the internal declarations and to read Bluedroid's
  behaviour.
- 2026-10-20: `pads_bluedroid.h` written; both variants compile. Review against the Bluedroid
  source and the reference drivers changed:
  - **Bonding first:** a pad paired from an L2CAP connection is paired as "no bonding" by
    Bluedroid (`BTM_AUTH_SP_NO`). We keep the key either way, but the pad might not, and then it
    would not reconnect. Now `BTA_DmBond` first, then the channels within the 3 s post-bond
    window.
  - Switch subcommands spaced at least 70 ms apart (hid-nintendo).
  - DS4 retries alternate features 0x05 and 0x02 (Linux and SDL).
  - Xbox fw 4.8's 17-byte Classic report and its separate Xbox-button report.
  - SDL's exact Xbox rumble packet.
  - No `snprintf` inside spinlock sections.
  - Finder/esp_hidh stacks raised to ESP-IDF's example values.
  - The BLE reconnect scan runs only while a bonded BLE pad is away.
- 2026-10-20: `tools/bt_abi/check.sh` added. It passes; a negative control fails as it should.
