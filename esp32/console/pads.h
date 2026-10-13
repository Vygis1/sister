// pads.h - the consoles' joypads, from wherever a pad is: Bluetooth pads (PS4, PS5, Xbox,
// Switch...) through Bluepad32 on a classic ESP32 (the LilyGO T8: the S3 has no Bluetooth
// Classic, which the PlayStation pads need), or a pad on the PC, whose state pc/pad.py
// sends over this chip's USB serial port as a line
//
//     P <buttons, hex> <left x> <left y> <right x> <right y>      (axes -128..127, up negative)
//
// buttons: 0 cross, 1 circle, 2 square, 3 triangle, 4 select/create, 5 start/options,
// 6-9 the D-pad up/down/left/right, 10 L1, 11 R1, 12 L2, 13 R2, 14 PS/home.
//
// Two players: the connected pads in order -- Bluetooth slot 1, slot 2, then the PC's --
// the first two of them, swapped if the menu says so. Each player's pad goes to the board's
// joypad registers (NES+0x08 / 0x0C) in the running machine's own order, through that
// machine's button mapping (two pad buttons per console button, kept in flash; the menu
// edits them), and the N64's sticks to its stick registers. The menu reads the pads from
// here too (menuButtons, view).
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
                      CONSOLE = NES + 0x20, N64_STICK1 = NES + 0x164, N64_CFG = NES + 0x168,
                      N64_STICK2 = NES + 0x18C;

// --- a pad, whoever's ------------------------------------------------------------------
struct In {
  bool a, b, x, y, sel, start, du, dd, dl, dr, l1, r1, l2, r2, home;   // cross, circle, square, triangle
  int lx, ly, rx, ry;                                                  // -128..127, up negative
};
static const int DIG = 48;                  // an axis past this is a direction (of 128)

// --- the pad's buttons, as the mappings name them -----------------------------------------
enum : uint8_t { PB_CROSS, PB_CIRCLE, PB_SQUARE, PB_TRIANGLE, PB_L1, PB_R1, PB_L2, PB_R2, PB_SELECT, PB_START,
                 PB_UP, PB_DOWN, PB_LEFT, PB_RIGHT, PB_LS_UP, PB_LS_DOWN, PB_LS_LEFT, PB_LS_RIGHT,
                 PB_RS_UP, PB_RS_DOWN, PB_RS_LEFT, PB_RS_RIGHT, PB_HOME, PB_N, PB_NONE = 0xFF };
static const char *const PB_NAME[PB_N] = {
  "cross", "circle", "square", "triangle", "L1", "R1", "L2", "R2", "select", "start",
  "up", "down", "left", "right", "left stick up", "left stick down", "left stick left", "left stick right",
  "right stick up", "right stick down", "right stick left", "right stick right", "PS / home" };
static bool pressed(const In &p, uint8_t b) {
  switch (b) {
  case PB_CROSS: return p.a;   case PB_CIRCLE: return p.b;   case PB_SQUARE: return p.x;  case PB_TRIANGLE: return p.y;
  case PB_L1: return p.l1;     case PB_R1: return p.r1;      case PB_L2: return p.l2;     case PB_R2: return p.r2;
  case PB_SELECT: return p.sel; case PB_START: return p.start;
  case PB_UP: return p.du;     case PB_DOWN: return p.dd;    case PB_LEFT: return p.dl;   case PB_RIGHT: return p.dr;
  case PB_LS_UP: return p.ly < -DIG;  case PB_LS_DOWN: return p.ly > DIG;  case PB_LS_LEFT: return p.lx < -DIG;  case PB_LS_RIGHT: return p.lx > DIG;
  case PB_RS_UP: return p.ry < -DIG;  case PB_RS_DOWN: return p.ry > DIG;  case PB_RS_LEFT: return p.rx < -DIG;  case PB_RS_RIGHT: return p.rx > DIG;
  case PB_HOME: return p.home;
  default: return false;
  }
}
// the first pad button down now (the menu's "press the button for ..."), PB_NONE if none
static uint8_t firstPressed(const In &p) {
  for (uint8_t b = 0; b < PB_N; b++) if (pressed(p, b)) return b;
  return PB_NONE;
}

// --- each machine's buttons: its name for it, its bit, the pad buttons it takes by default ---
struct CBtn { const char *name; uint8_t bit; uint8_t def[2]; };
struct Layout { const char *key, *name; const CBtn *b; uint8_t n; };
static const CBtn L_NES[] = {
  { "A", 0, { PB_CROSS, PB_SQUARE } }, { "B", 1, { PB_CIRCLE, PB_TRIANGLE } },
  { "Select", 2, { PB_SELECT, PB_NONE } }, { "Start", 3, { PB_START, PB_NONE } },
  { "Up", 4, { PB_UP, PB_LS_UP } }, { "Down", 5, { PB_DOWN, PB_LS_DOWN } },
  { "Left", 6, { PB_LEFT, PB_LS_LEFT } }, { "Right", 7, { PB_RIGHT, PB_LS_RIGHT } } };
static const CBtn L_SMS[] = {
  { "Button 1", 0, { PB_CROSS, PB_SQUARE } }, { "Button 2", 1, { PB_CIRCLE, PB_TRIANGLE } },
  { "Pause", 3, { PB_START, PB_NONE } },
  { "Up", 4, { PB_UP, PB_LS_UP } }, { "Down", 5, { PB_DOWN, PB_LS_DOWN } },
  { "Left", 6, { PB_LEFT, PB_LS_LEFT } }, { "Right", 7, { PB_RIGHT, PB_LS_RIGHT } } };
// the Game Gear, in sms.v's own order (port DCh: up, down, left, right, button 1, button 2), START on bit 6
static const CBtn L_GG[] = {
  { "Button 1", 4, { PB_CROSS, PB_SQUARE } }, { "Button 2", 5, { PB_CIRCLE, PB_TRIANGLE } },
  { "Start", 6, { PB_START, PB_NONE } },
  { "Up", 0, { PB_UP, PB_LS_UP } }, { "Down", 1, { PB_DOWN, PB_LS_DOWN } },
  { "Left", 2, { PB_LEFT, PB_LS_LEFT } }, { "Right", 3, { PB_RIGHT, PB_LS_RIGHT } } };
static const CBtn L_MD[] = {
  { "A", 6, { PB_SQUARE, PB_NONE } }, { "B", 4, { PB_CROSS, PB_NONE } }, { "C", 5, { PB_CIRCLE, PB_NONE } },
  { "Start", 7, { PB_START, PB_NONE } },
  { "Up", 0, { PB_UP, PB_LS_UP } }, { "Down", 1, { PB_DOWN, PB_LS_DOWN } },
  { "Left", 2, { PB_LEFT, PB_LS_LEFT } }, { "Right", 3, { PB_RIGHT, PB_LS_RIGHT } } };
static const CBtn L_PS1[] = {
  { "Cross", 14, { PB_CROSS, PB_NONE } }, { "Circle", 13, { PB_CIRCLE, PB_NONE } },
  { "Square", 15, { PB_SQUARE, PB_NONE } }, { "Triangle", 12, { PB_TRIANGLE, PB_NONE } },
  { "L1", 10, { PB_L1, PB_NONE } }, { "R1", 11, { PB_R1, PB_NONE } }, { "L2", 8, { PB_L2, PB_NONE } }, { "R2", 9, { PB_R2, PB_NONE } },
  { "Select", 0, { PB_SELECT, PB_NONE } }, { "Start", 3, { PB_START, PB_NONE } },
  { "Up", 4, { PB_UP, PB_LS_UP } }, { "Down", 6, { PB_DOWN, PB_LS_DOWN } },
  { "Left", 7, { PB_LEFT, PB_LS_LEFT } }, { "Right", 5, { PB_RIGHT, PB_LS_RIGHT } } };
static const CBtn L_N64[] = {
  { "A", 15, { PB_CROSS, PB_NONE } }, { "B", 14, { PB_SQUARE, PB_NONE } }, { "Z", 13, { PB_L2, PB_NONE } },
  { "Start", 12, { PB_START, PB_NONE } }, { "L", 5, { PB_L1, PB_NONE } }, { "R", 4, { PB_R1, PB_NONE } },
  { "C up", 3, { PB_RS_UP, PB_TRIANGLE } }, { "C down", 2, { PB_RS_DOWN, PB_CIRCLE } },
  { "C left", 1, { PB_RS_LEFT, PB_SELECT } }, { "C right", 0, { PB_RS_RIGHT, PB_R2 } },
  { "D-pad up", 11, { PB_UP, PB_NONE } }, { "D-pad down", 10, { PB_DOWN, PB_NONE } },
  { "D-pad left", 9, { PB_LEFT, PB_NONE } }, { "D-pad right", 8, { PB_RIGHT, PB_NONE } } };
static const CBtn L_SNES[] = {
  { "A", 7, { PB_CIRCLE, PB_NONE } }, { "B", 15, { PB_CROSS, PB_NONE } },
  { "X", 6, { PB_TRIANGLE, PB_NONE } }, { "Y", 14, { PB_SQUARE, PB_NONE } },
  { "L", 5, { PB_L1, PB_NONE } }, { "R", 4, { PB_R1, PB_NONE } },
  { "Select", 13, { PB_SELECT, PB_NONE } }, { "Start", 12, { PB_START, PB_NONE } },
  { "Up", 11, { PB_UP, PB_LS_UP } }, { "Down", 10, { PB_DOWN, PB_LS_DOWN } },
  { "Left", 9, { PB_LEFT, PB_LS_LEFT } }, { "Right", 8, { PB_RIGHT, PB_LS_RIGHT } } };
#define NB(x) (uint8_t)(sizeof(x) / sizeof(x[0]))
// by the board's console number (NES+0x20): 0 NES, 1 SMS, 2 MD, 3 PS1, 4 N64, 5 SNES, 6 GG
static const Layout LAYOUTS[7] = {
  { "nes", "NES", L_NES, NB(L_NES) }, { "sms", "Master System", L_SMS, NB(L_SMS) },
  { "md", "Mega Drive", L_MD, NB(L_MD) }, { "ps1", "PlayStation", L_PS1, NB(L_PS1) },
  { "n64", "Nintendo 64", L_N64, NB(L_N64) }, { "snes", "Super NES", L_SNES, NB(L_SNES) },
  { "gg", "Game Gear", L_GG, NB(L_GG) } };
static const int NLAYOUTS = 7;
static const int MAXB = 16;
static uint8_t bind[NLAYOUTS][MAXB][2];

static void loadBinds() {
  prefs.begin("binds", true);
  for (int l = 0; l < NLAYOUTS; l++) {
    const Layout &L = LAYOUTS[l];
    for (int i = 0; i < L.n; i++) { bind[l][i][0] = L.b[i].def[0]; bind[l][i][1] = L.b[i].def[1]; }
    uint8_t buf[MAXB * 2];
    if (prefs.getBytesLength(L.key) == (size_t)L.n * 2 && prefs.getBytes(L.key, buf, L.n * 2) == (size_t)L.n * 2)
      for (int i = 0; i < L.n; i++) { bind[l][i][0] = buf[i * 2]; bind[l][i][1] = buf[i * 2 + 1]; }
  }
  prefs.end();
}
static void saveBinds(int l) {
  const Layout &L = LAYOUTS[l];
  uint8_t buf[MAXB * 2];
  for (int i = 0; i < L.n; i++) { buf[i * 2] = bind[l][i][0]; buf[i * 2 + 1] = bind[l][i][1]; }
  prefs.begin("binds", false); prefs.putBytes(L.key, buf, L.n * 2); prefs.end();
}
static void defaultBinds(int l) {
  const Layout &L = LAYOUTS[l];
  for (int i = 0; i < L.n; i++) { bind[l][i][0] = L.b[i].def[0]; bind[l][i][1] = L.b[i].def[1]; }
  prefs.begin("binds", false); prefs.remove(L.key); prefs.end();
}

// in the running machine's order
static uint32_t word(const In &p, uint8_t which) {
  if (which >= NLAYOUTS) which = 0;           // (the shell: the NES order)
  const Layout &L = LAYOUTS[which];
  uint32_t o = 0;
  for (int i = 0; i < L.n; i++)
    if (pressed(p, bind[which][i][0]) || pressed(p, bind[which][i][1])) o |= 1u << L.b[i].bit;
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
  for (auto &s : slot) if (!s) { s = c; Log.printf("pads: %s in\n", c->getModelName().c_str()); return; }
  Log.println("pads: a third pad -- ignored");
}
static void onDisconnected(ControllerPtr c) {
  for (auto &s : slot) if (s == c) { s = nullptr; Log.println("pads: a pad left"); }
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
static bool sysWas[2] = { false, false };
#else
static bool btOn(int) { return false; }
#endif

// --- the two players, as the menu sees them ------------------------------------------------
struct Player { bool on; In in; char name[32]; int battery; bool bt; };
static Player players[2];                     // (written by poll(), read by the menu: copy under mux)
static portMUX_TYPE mux = portMUX_INITIALIZER_UNLOCKED;
static bool swapPlayers = false;
static void view(Player out[2]) { portENTER_CRITICAL(&mux); out[0] = players[0]; out[1] = players[1]; portEXIT_CRITICAL(&mux); }

// the menu's buttons: both players' together (either drives it)
enum : uint16_t { M_A = 1, M_B = 2, M_X = 4, M_Y = 8, M_SEL = 16, M_START = 32, M_UP = 64, M_DOWN = 128,
                  M_LEFT = 256, M_RIGHT = 512, M_L1 = 1024, M_R1 = 2048, M_HOME = 4096 };
static uint16_t menuButtons() {
  Player p[2]; view(p);
  uint16_t o = 0;
  for (auto &q : p) {
    if (!q.on) continue;
    const In &i = q.in;
    if (i.a) o |= M_A; if (i.b) o |= M_B; if (i.x) o |= M_X; if (i.y) o |= M_Y;
    if (i.sel) o |= M_SEL; if (i.start) o |= M_START; if (i.l1) o |= M_L1; if (i.r1) o |= M_R1; if (i.home) o |= M_HOME;
    if (i.du || i.ly < -DIG) o |= M_UP; if (i.dd || i.ly > DIG) o |= M_DOWN;
    if (i.dl || i.lx < -DIG) o |= M_LEFT; if (i.dr || i.lx > DIG) o |= M_RIGHT;
  }
  return o;
}

// what the menu asks of Bluetooth, done here (Bluepad32 wants its own task's calls)
enum { CMD_NONE, CMD_FORGET, CMD_PAIR_ON, CMD_PAIR_OFF };
static volatile int cmd = CMD_NONE;
static volatile bool pairing = true;          // new pads are let in (from power-up, as before)

// --- to the board ------------------------------------------------------------------------
static uint32_t last[2] = { 0xFFFFFFFF, 0xFFFFFFFF }, lastStick[2] = { 0xFFFFFFFF, 0xFFFFFFFF };
static uint8_t which = 0; static bool there = false; static uint32_t lastLook = 0, lastSend = 0;
static int n64Pads = -1;
static volatile bool busBusy = false;         // (the menu sending a lot: wait)

// From loop()
static void poll() {
#if PADS_BT
  BP32.update();
  if (cmd != CMD_NONE) {
    int c = cmd; cmd = CMD_NONE;
    if (c == CMD_FORGET) {
      BP32.forgetBluetoothKeys();
      for (auto &s : slot) if (s) s->disconnect();
      Log.println("pads: paired pads forgotten");
    } else if (c == CMD_PAIR_ON) { BP32.enableNewBluetoothConnections(true); pairing = true; }
    else if (c == CMD_PAIR_OFF) { BP32.enableNewBluetoothConnections(false); pairing = false; }
  }
  for (int i = 0; i < 2; i++) {
    bool sys = btOn(i) && slot[i]->miscSystem();
    if (sys && !sysWas[i]) menuPressed = true;
    sysWas[i] = sys;
  }
#endif
  if (usbOn && millis() - usbT > 1000) { usb = In{}; usbOn = false; }   // the PC has let go
  // the players: the connected pads in order, the first two
  Player np[2] = {};
  int k = 0;
#if PADS_BT
  for (int i = 0; i < 2 && k < 2; i++)
    if (btOn(i)) {
      Player &q = np[k++];
      q.on = true; q.bt = true; q.in = fromBt(slot[i]);
      snprintf(q.name, sizeof q.name, "%s", slot[i]->getModelName().c_str());
      int bat = slot[i]->battery();
      q.battery = bat ? bat * 100 / 255 : -1;
    }
#endif
  if (k < 2 && usbOn) { Player &q = np[k++]; q.on = true; q.bt = false; q.in = usb; snprintf(q.name, sizeof q.name, "PC pad"); q.battery = -1; }
  if (swapPlayers) std::swap(np[0], np[1]);
  portENTER_CRITICAL(&mux); players[0] = np[0]; players[1] = np[1]; portEXIT_CRITICAL(&mux);

  if (job.busy || busBusy) return;              // (nothing on the link while a core goes in)
  if (millis() - lastLook > 500) {             // what the board is, now and then
    lastLook = millis();
    Status s = fpga.status();
    there = s.alive && s.core != 255;           // a console, or the shell (its menu)
    if (there) which = s.core == 0 ? 0 : (fpga.busRead(CONSOLE) & 0xF);
    else { last[0] = last[1] = lastStick[0] = lastStick[1] = 0xFFFFFFFF; n64Pads = -1; }
  }
  if (!there) return;
  // (written again now and then, whatever changed: a register a core reset cleared)
  bool again = millis() - lastSend > 250;
  if (again) lastSend = millis();
  for (int i = 0; i < 2; i++) {
    const In &p = np[i].in;
    uint32_t v = np[i].on ? word(p, which) : 0;
    if (v != last[i] || again) { fpga.padWrite(i ? JOY2 : JOY1, v); last[i] = v; }
    if (which == 4) {
      uint32_t st = np[i].on ? stickWord(p) : 0;
      if (st != lastStick[i] || again) { fpga.padWrite(i ? N64_STICK2 : N64_STICK1, st); lastStick[i] = st; }
    }
  }
  // the N64: which controllers are plugged in (pad 1 always; pad 2 when there is one)
  if (which == 4) {
    int want = np[1].on ? 0b0011 : 0b0001;
    if (want != n64Pads) {
      uint32_t c = fpga.busRead(N64_CFG);
      fpga.busWrite(N64_CFG, (c & ~0xF0u) | (uint32_t)want << 4);
      n64Pads = want;
    }
  }
}

static void begin() {
  loadBinds();
  prefs.begin("menu", true); swapPlayers = prefs.getBool("swap", false); prefs.end();
#if PADS_BT
  BP32.setup(&onConnected, &onDisconnected);
  BP32.enableNewBluetoothConnections(true);
  Log.println("pads: Bluetooth up -- pair a pad with SHARE + PS; or a pad on the PC (pc/pad.py)");
#else
  Log.println("pads: a pad on the PC (pc/pad.py, over this USB port)");
#endif
}

}  // namespace pads
