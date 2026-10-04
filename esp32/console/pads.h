// pads.h - Bluetooth pads (PS4, PS5, Xbox, Switch...) as the consoles' joypads, through
// Bluepad32 on a classic ESP32 (the LilyGO T8: the S3 has no Bluetooth Classic, which
// the PlayStation pads need). Built only on the esp32-bluepad32 board platform; on any
// other the pads stay on the PC (pc/pad.py) and this is empty.
//
// Each pad's buttons go to the board's joypad registers (NES+0x08 / 0x0C) in the
// running machine's own order, as the PC server lays them (pc/server.py
// pad_for_console), and the N64's left stick to its stick register. The menu reads
// them back from there, wherever they came from.
//
// Pairing: hold SHARE (or CREATE) and the PS button until the light flashes; the ESP32
// remembers the pad after that.
//
// Bluepad32 is Apache-2.0 and runs on BTstack, which is free for non-commercial use
// only -- to be settled before anything here is sold.

#pragma once

#if __has_include(<Bluepad32.h>)
#include <Bluepad32.h>

namespace pads {

static const uint32_t NES = 0x00080000, JOY1 = NES + 0x08, JOY2 = NES + 0x0C,
                      CONSOLE = NES + 0x20, N64_STICK1 = NES + 0x164;
static ControllerPtr slot[2];

static void onConnected(ControllerPtr c) {
  for (auto &s : slot) if (!s) { s = c; Serial.printf("pads: %s in\n", c->getModelName().c_str()); return; }
  Serial.println("pads: a third pad -- ignored");
}
static void onDisconnected(ControllerPtr c) {
  for (auto &s : slot) if (s == c) { s = nullptr; Serial.println("pads: a pad left"); }
}

// one pad, in the running machine's order
static uint32_t word(ControllerPtr c, uint8_t which) {
  uint16_t b = c->buttons(), m = c->miscButtons();
  uint8_t d = c->dpad();
  int ax = c->axisX(), ay = c->axisY();
  bool up = (d & DPAD_UP) || ay < -300, down = (d & DPAD_DOWN) || ay > 300;
  bool left = (d & DPAD_LEFT) || ax < -300, right = (d & DPAD_RIGHT) || ax > 300;
  bool A = b & BUTTON_A, B = b & BUTTON_B, X = b & BUTTON_X, Y = b & BUTTON_Y;   // cross, circle, square, triangle
  bool sel = m & MISC_BUTTON_SELECT, start = m & MISC_BUTTON_START;
  bool l1 = b & BUTTON_SHOULDER_L, r1 = b & BUTTON_SHOULDER_R, l2 = b & BUTTON_TRIGGER_L, r2 = b & BUTTON_TRIGGER_R;
  uint32_t o = 0;
  switch (which) {
  case 2:   // Mega Drive: up 0, down 1, left 2, right 3, B 4, C 5, A 6, start 7 (square A, cross B, circle C)
    o = up | down << 1 | left << 2 | right << 3 | A << 4 | B << 5 | X << 6 | start << 7;
    break;
  case 3:   // PlayStation (pc/server.py _PS1_BITS)
    o = sel | start << 3 | up << 4 | right << 5 | down << 6 | left << 7 | l2 << 8 | r2 << 9 | l1 << 10 | r1 << 11
      | Y << 12 | B << 13 | A << 14 | X << 15;
    break;
  case 4: { // N64: A 15, B 14, Z 13, start 12, D-pad 11-8, L 5, R 4, C up/down/left/right 3-0 (the right stick)
    int rx = c->axisRX(), ry = c->axisRY();
    o = A << 15 | X << 14 | l2 << 13 | start << 12 | (d & DPAD_UP ? 1 : 0) << 11 | (d & DPAD_DOWN ? 1 : 0) << 10
      | (d & DPAD_LEFT ? 1 : 0) << 9 | (d & DPAD_RIGHT ? 1 : 0) << 8 | l1 << 5 | r1 << 4
      | (ry < -300 || Y) << 3 | (ry > 300 || B) << 2 | (rx < -300) << 1 | (rx > 300);
    break; }
  default:  // NES and Master System: A, B, select, start, up, down, left, right (as pc/pad.py)
    o = (A || X) | (B || Y) << 1 | sel << 2 | start << 3 | up << 4 | down << 5 | left << 6 | right << 7;
  }
  return o;
}

static uint32_t last[2] = { 0xFFFFFFFF, 0xFFFFFFFF }, lastStick = 0xFFFFFFFF;
static uint8_t which = 0; static bool console = false; static uint32_t lastLook = 0;

// From loop(): Bluepad32 wants its update() called there.
static void poll() {
  BP32.update();
  if (millis() - lastLook > 500) {             // what the board is, now and then
    lastLook = millis();
    Status s = fpga.status();
    console = s.alive && s.core != 0 && s.core != 255;
    if (console) which = fpga.busRead(CONSOLE) & 0xF;
    else last[0] = last[1] = lastStick = 0xFFFFFFFF;
  }
  if (!console) return;
  for (int i = 0; i < 2; i++) {
    ControllerPtr c = slot[i];
    uint32_t v = (c && c->isConnected() && c->isGamepad()) ? word(c, which) : 0;
    if (v != last[i]) { fpga.busWrite(i ? JOY2 : JOY1, v); last[i] = v; }
  }
  if (which == 4 && slot[0] && slot[0]->isConnected()) {
    int x = slot[0]->axisX() / 4, y = -slot[0]->axisY() / 4;      // up is positive
    x = x < -128 ? -128 : x > 127 ? 127 : x; y = y < -128 ? -128 : y > 127 ? 127 : y;
    uint32_t st = ((uint32_t)(x & 0xFF) << 8) | (uint32_t)(y & 0xFF);
    if (st != lastStick) { fpga.busWrite(N64_STICK1, st); lastStick = st; }
  }
}

static void begin() {
  BP32.setup(&onConnected, &onDisconnected);
  BP32.enableNewBluetoothConnections(true);
  Serial.println("pads: Bluetooth up -- pair a pad with SHARE + PS");
}

}  // namespace pads

#else
namespace pads { static void begin() {} static void poll() {} }
#endif
