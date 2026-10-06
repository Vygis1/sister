// pads.h - the consoles' joypads, from wherever a pad is: a Bluetooth pad (PS4, PS5,
// Xbox, Switch...) through Bluepad32 on a classic ESP32 (the LilyGO T8: the S3 has no
// Bluetooth Classic, which the PlayStation pads need), or a pad on the PC, whose state
// pc/pad.py sends over this chip's USB serial port as a line
//
//     P <buttons, hex> <left x> <left y> <right x> <right y>      (axes -128..127, up negative)
//
// buttons: 0 cross, 1 circle, 2 square, 3 triangle, 4 select/create, 5 start/options,
// 6-9 the D-pad up/down/left/right, 10 L1, 11 R1, 12 L2, 13 R2, 14 PS/home.
//
// Each pad's buttons go to the board's joypad registers (NES+0x08 / 0x0C) in the
// running machine's own order, and the N64's left stick to its stick register -- in the
// shell too, whose menu reads them from there. Pad 1 is a Bluetooth pad if one is
// connected, else the PC's; a PC that has said nothing for a second has let go.
//
// Pairing a Bluetooth pad: hold SHARE (or CREATE) and the PS button until the light
// flashes; the ESP32 remembers the pad after that.
//
// Bluepad32 is Apache-2.0 and runs on BTstack, which is free for non-commercial use
// only -- to be settled before anything here is sold.

#pragma once

#if __has_include(<Bluepad32.h>)
#include <Bluepad32.h>
#define PADS_BT 1
#else
#define PADS_BT 0
#endif

namespace pads {

static const uint32_t NES = 0x00080000, JOY1 = NES + 0x08, JOY2 = NES + 0x0C,
                      CONSOLE = NES + 0x20, N64_STICK1 = NES + 0x164;

// --- a pad, whoever's ------------------------------------------------------------------
struct In {
  bool a, b, x, y, sel, start, du, dd, dl, dr, l1, r1, l2, r2, home;   // cross, circle, square, triangle
  int lx, ly, rx, ry;                                                  // -128..127, up negative
};
static const int DIG = 48;                  // an axis past this is a direction (of 128)

// in the running machine's order
static uint32_t word(const In &p, uint8_t which) {
  bool up = p.du || p.ly < -DIG, down = p.dd || p.ly > DIG, left = p.dl || p.lx < -DIG, right = p.dr || p.lx > DIG;
  uint32_t o = 0;
  switch (which) {
  case 2:   // Mega Drive: up 0, down 1, left 2, right 3, B 4, C 5, A 6, start 7 (square A, cross B, circle C)
    o = up | down << 1 | left << 2 | right << 3 | p.a << 4 | p.b << 5 | p.x << 6 | p.start << 7;
    break;
  case 3:   // PlayStation (pc/server.py _PS1_BITS)
    o = p.sel | p.start << 3 | up << 4 | right << 5 | down << 6 | left << 7 | p.l2 << 8 | p.r2 << 9 | p.l1 << 10 | p.r1 << 11
      | p.y << 12 | p.b << 13 | p.a << 14 | p.x << 15;
    break;
  case 4:   // N64: A 15, B 14, Z 13, start 12, D-pad 11-8, L 5, R 4, C up/down/left/right 3-0 (the right stick)
    o = p.a << 15 | p.x << 14 | p.l2 << 13 | p.start << 12 | p.du << 11 | p.dd << 10 | p.dl << 9 | p.dr << 8
      | p.l1 << 5 | p.r1 << 4
      | (p.ry < -DIG || p.y) << 3 | (p.ry > DIG || p.b) << 2 | (p.rx < -DIG || p.sel) << 1 | (p.rx > DIG || p.r2);
    break;
  case 5:   // SNES ($4218): B 15, Y 14, select 13, start 12, up 11, down 10, left 9, right 8, A 7, X 6, L 5, R 4
            // (by position: cross B, circle A, square Y, triangle X)
    o = p.a << 15 | p.x << 14 | p.sel << 13 | p.start << 12 | up << 11 | down << 10 | left << 9 | right << 8
      | p.b << 7 | p.y << 6 | p.l1 << 5 | p.r1 << 4;
    break;
  default:  // NES, Master System, and the shell's menu: A, B, select, start, up, down, left, right
    o = (p.a || p.x) | (p.b || p.y) << 1 | p.sel << 2 | p.start << 3 | up << 4 | down << 5 | left << 6 | right << 7;
  }
  return o;
}

// the N64's stick: a dead zone, then +-80 at the rim (a real stick's reach); up positive
static int n64axis(int v) {
  const int dead = 15;
  int m = v < 0 ? -v : v;
  if (m <= dead) return 0;
  int r = (m - dead) * 80 / (128 - dead);
  if (r > 80) r = 80;
  return v < 0 ? -r : r;
}
static uint32_t stickWord(const In &p) {
  int x = n64axis(p.lx), y = -n64axis(p.ly);
  return ((uint32_t)(x & 0xFF) << 8) | (uint32_t)(y & 0xFF);
}

// --- the PC's pad, over USB serial -------------------------------------------------------
static In usb{};
static bool usbOn = false;
static uint32_t usbT = 0;
static volatile bool menuPressed = false;
static bool usbHome = false;
// a "P ..." line (console.ino's serialCommand hands it over)
static void usbLine(const String &l) {
  unsigned bits = 0; int lx = 0, ly = 0, rx = 0, ry = 0;
  if (sscanf(l.c_str() + 1, "%x %d %d %d %d", &bits, &lx, &ly, &rx, &ry) < 1) return;
  In p{};
  p.a = bits & 1; p.b = bits >> 1 & 1; p.x = bits >> 2 & 1; p.y = bits >> 3 & 1; p.sel = bits >> 4 & 1; p.start = bits >> 5 & 1;
  p.du = bits >> 6 & 1; p.dd = bits >> 7 & 1; p.dl = bits >> 8 & 1; p.dr = bits >> 9 & 1;
  p.l1 = bits >> 10 & 1; p.r1 = bits >> 11 & 1; p.l2 = bits >> 12 & 1; p.r2 = bits >> 13 & 1; p.home = bits >> 14 & 1;
  p.lx = lx; p.ly = ly; p.rx = rx; p.ry = ry;
  if (p.home && !usbHome) menuPressed = true;
  usbHome = p.home;
  usb = p; usbOn = true; usbT = millis();
}

#if PADS_BT
// --- Bluetooth pads ------------------------------------------------------------------------
static ControllerPtr slot[2];
static void onConnected(ControllerPtr c) {
  for (auto &s : slot) if (!s) { s = c; Serial.printf("pads: %s in\n", c->getModelName().c_str()); return; }
  Serial.println("pads: a third pad -- ignored");
}
static void onDisconnected(ControllerPtr c) {
  for (auto &s : slot) if (s == c) { s = nullptr; Serial.println("pads: a pad left"); }
}
static bool btOn(int i) { return slot[i] && slot[i]->isConnected() && slot[i]->isGamepad(); }
static In fromBt(ControllerPtr c) {
  In p{};
  uint16_t b = c->buttons(), m = c->miscButtons();
  uint8_t d = c->dpad();
  p.a = b & BUTTON_A; p.b = b & BUTTON_B; p.x = b & BUTTON_X; p.y = b & BUTTON_Y;
  p.sel = m & MISC_BUTTON_SELECT; p.start = m & MISC_BUTTON_START; p.home = c->miscSystem();
  p.l1 = b & BUTTON_SHOULDER_L; p.r1 = b & BUTTON_SHOULDER_R; p.l2 = b & BUTTON_TRIGGER_L; p.r2 = b & BUTTON_TRIGGER_R;
  p.du = d & DPAD_UP; p.dd = d & DPAD_DOWN; p.dl = d & DPAD_LEFT; p.dr = d & DPAD_RIGHT;
  auto ax = [](int v) { v /= 4; return v < -128 ? -128 : v > 127 ? 127 : v; };     // (Bluepad32: +-512)
  p.lx = ax(c->axisX()); p.ly = ax(c->axisY()); p.rx = ax(c->axisRX()); p.ry = ax(c->axisRY());
  return p;
}
static bool sysWas = false;
#else
static bool btOn(int) { return false; }
#endif

// --- to the board ------------------------------------------------------------------------
static uint32_t last[2] = { 0xFFFFFFFF, 0xFFFFFFFF }, lastStick = 0xFFFFFFFF;
static uint8_t which = 0; static bool there = false; static uint32_t lastLook = 0, lastSend = 0;

// From loop()
static void poll() {
#if PADS_BT
  BP32.update();
  bool sys = slot[0] && slot[0]->isConnected() && slot[0]->miscSystem();
  if (sys && !sysWas) menuPressed = true;
  sysWas = sys;
#endif
  if (job.busy) return;                         // (nothing on the link while a core goes in)
  if (millis() - lastLook > 500) {             // what the board is, now and then
    lastLook = millis();
    Status s = fpga.status();
    there = s.alive && s.core != 255;           // a console, or the shell (its menu)
    if (there) which = s.core == 0 ? 0 : (fpga.busRead(CONSOLE) & 0xF);
    else last[0] = last[1] = lastStick = 0xFFFFFFFF;
  }
  if (!there) return;
  if (usbOn && millis() - usbT > 1000) { usb = In{}; usbOn = false; }   // the PC has let go
  // (written again now and then, whatever changed: a register a core reset cleared)
  bool again = millis() - lastSend > 250;
  if (again) lastSend = millis();
  for (int i = 0; i < 2; i++) {
    In p{};
#if PADS_BT
    if (btOn(i)) p = fromBt(slot[i]);
    else
#endif
    if (i == 0 && usbOn) p = usb;
    uint32_t v = word(p, which);
    if (v != last[i] || again) { fpga.busWrite(i ? JOY2 : JOY1, v); last[i] = v; }
    if (i == 0 && which == 4) {
      uint32_t st = stickWord(p);
      if (st != lastStick || again) { fpga.busWrite(N64_STICK1, st); lastStick = st; }
    }
  }
}

static void begin() {
#if PADS_BT
  BP32.setup(&onConnected, &onDisconnected);
  BP32.enableNewBluetoothConnections(true);
  Serial.println("pads: Bluetooth up -- pair a pad with SHARE + PS; or a pad on the PC (pc/pad.py)");
#else
  Serial.println("pads: a pad on the PC (pc/pad.py, over this USB port)");
#endif
}

}  // namespace pads
