// menu.h - the menu on the TV: the games on the card, listed over the HDMI picture
// (the console image's osd.v, written through esp_bus.v), picked with the pad, and
// loaded straight from the card -- the console switched first when the game is for
// another one (back to the shell, the core installed from /cores, booted).
//
// Included by console.ino after everything it uses (fpga, the card, installFrom,
// job, prefs).
//
//   START + SELECT together   open the menu (it is open at power-up)
//   UP / DOWN                 move; LEFT / RIGHT a page at a time
//   A or START                open a console's games / load the game
//   B                         back to the consoles / back to the game (the menu
//                             pauses the NES and Master System while it is up)
//
// The pad is read back from the board (NES+0x08), wherever it is written from: the
// PC's pad bridge today, a Bluetooth pad on this chip later.

#pragma once
#include <vector>
#include <algorithm>

namespace menu {

// --- the board's registers (as pc/server.py) ------------------------------------
static const uint32_t SYN_CTRL = 0x00030004, VID_CTRL = 0x00060004;
static const uint32_t OSD = 0x00070000, OSD_CTRL = OSD + 0x04, OSD_CELLS = OSD + 0x2000;
static const uint32_t NES = 0x00080000, NES_CTRL = NES + 0x04, NES_JOY1 = NES + 0x08,
                      NES_MAPPER = NES + 0x1C, NES_CONSOLE = NES + 0x20,
                      NES_CART_BANK = NES + 0x30, NES_FILL_END = NES + 0x34;
static const uint32_t NES_PRG = 0x00090000, NES_CHR = 0x000D0000;
static const uint32_t CART_BANK = 256 * 1024;

// --- the consoles -----------------------------------------------------------------
struct Machine { const char *name, *core; uint8_t id; uint32_t limit; };
static const Machine MACHINES[] = {
  { "NES",           "nes", 'N', 256 * 1024 + 128 * 1024 + 16 },
  { "Master System", "sms", 'S', 256 * 1024 },
  { "Mega Drive",    "md",  'M', 4 * 1024 * 1024 },
  { "Nintendo 64",   "n64", '6', 16 * 1024 * 1024 },
};
static const int NMACH = 4;

static int machineOfName(const String &n) {
  String l = n; l.toLowerCase();
  if (l.endsWith(".nes")) return 0;
  if (l.endsWith(".sms")) return 1;
  if (l.endsWith(".md") || l.endsWith(".gen") || l.endsWith(".smd")) return 2;
  if (l.endsWith(".z64") || l.endsWith(".n64") || l.endsWith(".v64")) return 3;
  return -1;
}
static int machineOfCore(uint8_t id) {
  for (int i = 0; i < NMACH; i++) if (MACHINES[i].id == id) return i;
  return -1;
}

struct Game { String path, name; int8_t m; uint32_t size; };

// --- the screen: 40 x 30 cells -------------------------------------------------
static const int COLS = 40, ROWS = 30;
static uint32_t cells[COLS * ROWS];
enum { WHITE = 0, YELLOW = 1, GREY = 2, GREEN = 3 };

static void clear() { for (auto &c : cells) c = ' '; }
static void put(int col, int row, const String &s, int colour = WHITE, bool hl = false, int width = -1) {
  if (row < 0 || row >= ROWS) return;
  int n = width < 0 ? s.length() : width;
  for (int i = 0; i < n && col + i < COLS; i++) {
    char ch = i < (int)s.length() ? s[i] : ' ';
    if ((uint8_t)ch < 0x20 && ch != 0x10 && ch != 0x1E && ch != 0x1F) ch = ' ';
    if ((uint8_t)ch > 0x7E) ch = '?';
    cells[row * COLS + col + i] = (uint8_t)ch | (hl ? 0x100 : 0) | (colour << 9);
  }
}
static void centre(int row, const String &s, int colour = WHITE) { put((COLS - (int)s.length()) / 2, row, s, colour); }
static void show() { fpga.busWrite(OSD_CELLS, cells, COLS * ROWS); }
static void osd(uint32_t ctrl) { fpga.busWrite(OSD_CTRL, ctrl); }

// A message alone on the screen (loading, switching, an error).
static void message(const String &a, const String &b = "", int colour = WHITE) {
  clear();
  centre(13, a, colour);
  if (b.length()) centre(15, b, GREY);
  show(); osd(1);
}

// --- the card: a folder in /roms for each console ------------------------------------
// /roms/nes, /roms/sms, /roms/md (or genesis, megadrive), /roms/n64. A game loose in
// /roms itself is moved into its console's folder, by its extension, the first time
// the card is seen; anything not recognised (a BIOS, a .bin) stays where it is.
static std::vector<Game> lists[NMACH];
static std::vector<int> consoles;          // the machines with a folder, in order

static int machineOfFolder(String n) {
  n.toLowerCase();
  if (n == "nes") return 0;
  if (n == "sms" || n == "mastersystem" || n == "master system") return 1;
  if (n == "md" || n == "genesis" || n == "megadrive" || n == "mega drive") return 2;
  if (n == "n64") return 3;
  return -1;
}
static String baseName(File &e) {
  String n = String(e.name());
  int slash = n.lastIndexOf('/');
  return slash >= 0 ? n.substring(slash + 1) : n;
}
static void tidy() {
  File d = SD.open("/roms");
  if (!d) return;
  std::vector<String> loose;
  while (true) {
    File e = d.openNextFile();
    if (!e) break;
    String n = baseName(e);
    if (!e.isDirectory() && n.length() && n[0] != '.' && machineOfName(n) >= 0) loose.push_back(n);
    e.close();
  }
  d.close();
  for (auto &n : loose) {
    String dir = String("/roms/") + MACHINES[machineOfName(n)].core;
    SD.mkdir(dir);
    if (SD.rename("/roms/" + n, dir + "/" + n)) Serial.println("menu: moved " + n + " into " + dir);
  }
}
static void scan() {
  for (auto &l : lists) l.clear();
  consoles.clear();
  if (!haveCard) return;
  tidy();
  File d = SD.open("/roms");
  while (d) {
    File e = d.openNextFile();
    if (!e) break;
    int m = e.isDirectory() ? machineOfFolder(baseName(e)) : -1;
    if (m >= 0) {
      String dir = "/roms/" + baseName(e);
      File g = SD.open(dir);
      while (g) {
        File f = g.openNextFile();
        if (!f) break;
        String n = baseName(f);
        if (!f.isDirectory() && n.length() && n[0] != '.') {
          int dot = n.lastIndexOf('.');
          lists[m].push_back({ dir + "/" + n, dot > 0 ? n.substring(0, dot) : n, (int8_t)m, (uint32_t)f.size() });
        }
        f.close();
      }
      if (g) g.close();
    }
    e.close();
  }
  if (d) d.close();
  for (int m = 0; m < NMACH; m++) {
    std::sort(lists[m].begin(), lists[m].end(), [](const Game &a, const Game &b) {
      String x = a.name, y = b.name; x.toLowerCase(); y.toLowerCase(); return x < y;
    });
    if (!lists[m].empty()) consoles.push_back(m);
  }
}

static int level = 0;                       // 0 the consoles, 1 a console's games
static int cur = 0;                         // the console whose games are shown
static int sel = 0, top = 0, consSel = 0;
static bool open_ = false, gameIn = false;
static String note;                         // one line at the bottom: what just happened
static const int LIST_TOP = 4, LIST_ROWS = 22;

static int count() { return level == 0 ? (int)consoles.size() : (int)lists[cur].size(); }

static void draw() {
  clear();
  Status st = fpga.status();
  int cm = machineOfCore(st.core);
  if (level == 0) {
    centre(0, "FPGA CONSOLE", YELLOW);
    put(1, 2, String("running: ") + (cm >= 0 ? MACHINES[cm].name : "?"), GREY);
    if (consoles.empty()) {
      centre(12, haveCard ? "no games on the card" : "no SD card", YELLOW);
      centre(14, "/roms/nes  /roms/sms  /roms/md  /roms/n64", GREY);
    }
  } else {
    centre(0, MACHINES[cur].name, YELLOW);
    put(1, 2, String(lists[cur].size()) + " games", GREY);
  }
  if (sel < top) top = sel;
  if (sel >= top + LIST_ROWS) top = sel - LIST_ROWS + 1;
  int n = count();
  for (int r = 0; r < LIST_ROWS && top + r < n; r++) {
    int i = top + r;
    bool here = i == sel;
    put(1, LIST_TOP + r, here ? String((char)0x10) : String(" "), YELLOW);
    if (level == 0) {
      int m = consoles[i];
      put(3, LIST_TOP + r, MACHINES[m].name, m == cm ? GREEN : WHITE, here, 24);
      put(28, LIST_TOP + r, String(lists[m].size()), GREY, here, 6);
    } else {
      put(3, LIST_TOP + r, lists[cur][i].name, WHITE, here, COLS - 5);
    }
  }
  if (top > 0) put(COLS - 2, LIST_TOP, String((char)0x1E), GREY);
  if (top + LIST_ROWS < n) put(COLS - 2, LIST_TOP + LIST_ROWS - 1, String((char)0x1F), GREY);
  put(1, ROWS - 3, note, YELLOW, false, COLS - 2);
  put(1, ROWS - 2, level == 0 ? (gameIn ? "A open  B back to the game" : "A open")
                              : "A load  B consoles", GREY);
  show();
}

// --- the pad ----------------------------------------------------------------------
enum { B_A = 1, B_B = 2, B_SEL = 4, B_START = 8, B_UP = 16, B_DOWN = 32, B_LEFT = 64, B_RIGHT = 128 };
// The register holds the pad in the running machine's order (the server re-lays it);
// back to the NES order the menu thinks in.
static uint8_t pad() {
  uint32_t v = fpga.busRead(NES_JOY1);
  uint8_t c = fpga.busRead(NES_CONSOLE) & 0xF;
  if (c == 2) {          // Mega Drive: up 0, down 1, left 2, right 3, B 4, C 5, A 6, start 7
    uint8_t o = 0;
    if (v & 1) o |= B_UP;   if (v & 2) o |= B_DOWN; if (v & 4) o |= B_LEFT; if (v & 8) o |= B_RIGHT;
    if (v & 16) o |= B_B;   if (v & 32) o |= B_SEL; if (v & 64) o |= B_A;   if (v & 128) o |= B_START;
    return o;
  }
  if (c == 4) {          // the N64's order (pc/server.py _N64_BITS): the pad's a 15, b 2, select 1, start 12, up 11, down 10, left 9, right 8
    uint8_t o = 0;
    if (v & 0x8000) o |= B_A; if (v & 0x0004) o |= B_B; if (v & 0x0002) o |= B_SEL; if (v & 0x1000) o |= B_START;
    if (v & 0x0800) o |= B_UP; if (v & 0x0400) o |= B_DOWN; if (v & 0x0200) o |= B_LEFT; if (v & 0x0100) o |= B_RIGHT;
    return o;
  }
  return v & 0xFF;
}

// --- loading ------------------------------------------------------------------------
static uint8_t *buf = nullptr;              // 16 kB staging, words in the board's order
static const size_t BUF = 16384;

// Copy n bytes of the file from where it stands to the bus at addr (and up), padded
// with fill to whole words; swap = the N64's byte orders.
static bool stream(File &f, uint32_t addr, uint32_t n, int swap = 0) {
  while (n) {
    size_t want = n > BUF ? BUF : n;
    size_t got = f.read(buf, want);
    if (got != want) return false;
    size_t words = (want + 3) / 4;
    for (size_t k = want; k < words * 4; k++) buf[k] = 0;
    if (swap == 1) for (size_t k = 0; k + 1 < want; k += 2) std::swap(buf[k], buf[k + 1]);                 // .v64
    if (swap == 2) for (size_t k = 0; k + 3 < want; k += 4) { std::swap(buf[k], buf[k + 3]); std::swap(buf[k + 1], buf[k + 2]); }   // .n64
    fpga.busWrite(addr, (uint32_t *)buf, words);
    addr += words * 4; n -= want;
  }
  return true;
}
// A big cartridge through the 256 kB window: bank by bank, then the end strobe.
static bool streamBanks(File &f, uint32_t n, int swap = 0) {
  for (uint32_t bank = 0; bank * CART_BANK < n; bank++) {
    fpga.busWrite(NES_CART_BANK, bank);
    uint32_t len = min(CART_BANK, n - bank * CART_BANK);
    if (!stream(f, NES_PRG, len, swap)) return false;
    message("loading", String(min(n, (bank + 1) * CART_BANK) / 1024) + " of " + String(n / 1024) + " kB");
  }
  fpga.busWrite(NES_FILL_END, 1);
  return true;
}

static String load(const Game &g) {
  File f = SD.open(g.path);
  if (!f) return "cannot open " + g.path;
  uint32_t size = f.size();
  if (size > MACHINES[g.m].limit) { f.close(); return "too big for the " + String(MACHINES[g.m].name); }
  message("loading", g.name);
  fpga.busWrite(NES_CTRL, 0);                       // held while the cartridge changes
  String err;
  if (g.m == 0) {                                    // NES: iNES
    uint8_t h[16];
    if (f.read(h, 16) != 16 || memcmp(h, "NES\x1a", 4)) err = "not an iNES file";
    else {
      uint32_t prg = h[4] * 16384u, chr = h[5] * 8192u;
      bool mirrorV = h[6] & 1;
      uint8_t mapper = (h[6] >> 4) | (h[7] & 0xF0);
      if (h[6] & 4) f.seek(16 + 512);               // a trainer: skipped
      if (prg > 256 * 1024 || chr > 128 * 1024) err = "the cartridge is too big";
      else if (!stream(f, NES_PRG, prg)) err = "the file ended early";
      else {
        if (h[4] == 1) { f.seek(f.position() - prg); stream(f, NES_PRG + prg, prg); }   // 16 kB shows in both halves
        if (chr) { if (!stream(f, NES_CHR, chr)) err = "the file ended early"; }
        else { memset(buf, 0, 8192); fpga.busWrite(NES_CHR, (uint32_t *)buf, 2048); }
        uint32_t prgAll = h[4] == 1 ? 2 * prg : prg;
        uint32_t prgLast = prgAll / 8192 ? prgAll / 8192 - 1 : 0;
        fpga.busWrite(NES_MAPPER, (mapper & 0xF) | (prgLast << 8) | (chr ? 0 : 0x4000));
        fpga.busWrite(NES_CONSOLE, 0);
        fpga.busWrite(VID_CTRL, 3); fpga.busWrite(SYN_CTRL, 3);
        if (!err.length()) fpga.busWrite(NES_CTRL, 1 | (mirrorV ? 2 : 0));
      }
    }
  } else if (g.m == 1) {                             // Master System: the ROM, nothing else
    if (!stream(f, NES_PRG, size)) err = "the file ended early";
    fpga.busWrite(NES_CONSOLE, 1);
    fpga.busWrite(VID_CTRL, 3); fpga.busWrite(SYN_CTRL, 3);
    if (!err.length()) fpga.busWrite(NES_CTRL, 1);
  } else if (g.m == 2) {                             // Mega Drive: into DDR3, bank by bank
    fpga.busWrite(NES_CONSOLE, 2);
    if (!streamBanks(f, size)) err = "the file ended early";
    fpga.busWrite(VID_CTRL, 3); fpga.busWrite(SYN_CTRL, 3);
    if (!err.length()) fpga.busWrite(NES_CTRL, 1);
  } else {                                           // N64: big-endian (.z64) whatever the file
    uint8_t m4[4]; f.read(m4, 4); f.seek(0);
    int swap = (m4[0] == 0x37 && m4[1] == 0x80) ? 1 : (m4[0] == 0x40 && m4[1] == 0x12) ? 2 : 0;
    fpga.busWrite(NES_CONSOLE, 4);
    if (!streamBanks(f, size, swap)) err = "the file ended early";
    if (!err.length()) fpga.busWrite(NES_CTRL, 1);
  }
  f.close();
  return err;
}

// --- switching the board to another console ---------------------------------------
static String switchTo(int m) {
  const Machine &M = MACHINES[m];
  String path = String("/cores/") + M.core + ".bin";
  File f = SD.open(path);
  if (!f) return String("no ") + path + " on the card";
  message(String("switching to the ") + M.name, "the screen goes dark for a few seconds");
  delay(300);
  // Back to the shell: the console image's own reboot register (SYS 0x0014), and
  // PROGRAM_B if that did not take. The shell has no picture: dark from here.
  fpga.busWrite(0x00000014, 0xB0070000);
  uint32_t t0 = millis();
  while (millis() - t0 < 2000 && fpga.status().core != 0) delay(50);
  if (fpga.status().core != 0) {
    fpga.forceShell();
    t0 = millis();
    while (millis() - t0 < 3000 && fpga.status().core != 0) delay(50);
  }
  if (fpga.status().core != 0) { f.close(); return "the board would not go back to the shell"; }
  prefs.begin("menu", true); String inSlot = prefs.getString("slot", ""); uint32_t inSize = prefs.getUInt("size", 0); prefs.end();
  if (inSlot != M.core || inSize != (uint32_t)f.size()) {
    // (twice if the read-back disagrees: the board is in the shell with no picture,
    // and a second try beats leaving the screen dark)
    bool ok = false;
    for (int tries = 0; tries < 2 && !ok; tries++) {
      job.busy = true; job.error = "";
      f.seek(0);
      ok = installCard(f);
      job.busy = false;
    }
    if (!ok) { f.close(); return "install failed: " + job.error; }
    prefs.begin("menu", false); prefs.putString("slot", M.core); prefs.putUInt("size", f.size()); prefs.end();
  }
  f.close();
  // (boot asked twice if the first did not take: once, it did not)
  for (int tries = 0; tries < 2; tries++) {
    fpga.boot(true);
    t0 = millis();
    while (millis() - t0 < 5000) {
      delay(100);
      Status s = fpga.status();
      if (s.alive && s.core == M.id) return "";
    }
  }
  return String("the ") + M.name + " core did not come up";
}

static void pick() {
  if (level == 0) {                         // a console: its games
    if (consoles.empty()) return;
    consSel = sel; cur = consoles[sel]; level = 1; sel = 0; top = 0; note = "";
    draw();
    return;
  }
  if (lists[cur].empty()) return;
  const Game &g = lists[cur][sel];
  Status st = fpga.status();
  if (machineOfCore(st.core) != g.m) {
    String e = switchTo(g.m);
    if (e.length()) { note = e; open_ = true; osd(1); draw(); return; }
  }
  String e = load(g);
  if (e.length()) { note = e; draw(); return; }
  note = "";
  gameIn = true; open_ = false;
  osd(0);
  Serial.println("menu: loaded " + g.path);
}

static void openMenu() {
  open_ = true;
  uint32_t c = fpga.busRead(NES_CTRL);
  if (c & 1) fpga.busWrite(NES_CTRL, c | 4);       // pause
  draw();
  osd(gameIn ? 3 : 1);
}
static void closeMenu() {
  open_ = false;
  osd(0);
  uint32_t c = fpga.busRead(NES_CTRL);
  fpga.busWrite(NES_CTRL, c & ~4u);
}

// --- the task -------------------------------------------------------------------
static void task(void *) {
  uint8_t was = 0; uint32_t held = 0, lastCheck = 0; bool up = false;
  for (;;) {
    delay(16);
    // is a console image there to draw on?
    if (millis() - lastCheck > 1000 || !up) {
      lastCheck = millis();
      Status s = fpga.status();
      bool console = s.alive && machineOfCore(s.core) >= 0;
      if (console && !up) {                          // it came up (power-up, or a core booted by hand)
        up = true;
        if (!gameIn) { open_ = true; draw(); osd(1); }
      }
      if (!console) { up = false; continue; }
    }
    uint8_t p = pad();
    uint8_t edge = p & ~was;
    if (p != was) held = millis();
    bool rep = (p & (B_UP | B_DOWN)) && millis() - held > 350;
    if (rep) held = millis() - 270;                  // ~12 a second once it repeats
    was = p;
    if (!open_) {
      if ((p & (B_START | B_SEL)) == (B_START | B_SEL) && (edge & (B_START | B_SEL))) openMenu();
      continue;
    }
    int n = count();
    if ((edge | (rep ? p : 0)) & B_UP)   { if (sel > 0) sel--; draw(); }
    if ((edge | (rep ? p : 0)) & B_DOWN) { if (sel + 1 < n) sel++; draw(); }
    if (edge & B_LEFT)  { sel = max(0, sel - LIST_ROWS); draw(); }
    if (edge & B_RIGHT) { sel = max(0, min(n - 1, sel + LIST_ROWS)); draw(); }
    if ((edge & B_A) || ((edge & B_START) && !(p & B_SEL))) pick();
    if (edge & B_B) {
      if (level == 1) { level = 0; sel = consSel; top = 0; note = ""; draw(); }
      else if (gameIn) closeMenu();
    }
  }
}

static void begin() {
  buf = (uint8_t *)malloc(BUF);
  // The board starts in the shell (power-up, or this chip's own reset pulsing
  // PROGRAM_B): start whatever core the slot holds, so the menu has a screen.
  Status s0 = fpga.status();
  if (s0.alive && s0.core == 0 && !s0.busy) {
    for (int tries = 0; tries < 2; tries++) {
      fpga.boot(true);
      uint32_t t0 = millis();
      while (millis() - t0 < 4000 && fpga.status().core == 0) delay(100);
      if (fpga.status().core != 0) break;
    }
    Serial.printf("menu: booted the slot's core (%u)\n", fpga.status().core);
  }
  scan();
  for (int m : consoles) Serial.printf("menu: %s, %u games\n", MACHINES[m].name, (unsigned)lists[m].size());
  xTaskCreatePinnedToCore(task, "menu", 8192, nullptr, 1, nullptr, 1);
}

}  // namespace menu
