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
  { "PlayStation",   "ps1", 'P', 0xFFFFFFFF },          // a disc image: any size
};
static const int NMACH = 5;
static const uint32_t CARD_CTL = NES + 0x134;

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

// --- the screen: 40 x 30 cells ----------------------------------------------------
// osd.v draws them: a cell is [6:0] the character, [8] the selection bar behind it,
// [10:9] the colour, [11] the header's / footer's lighter background. The font's
// codes 0x01-0x07 are a frame's corners and lines and a block, 0x0F a diamond.
static const int COLS = 40, ROWS = 30;
static uint32_t *cells = (uint32_t *)calloc(COLS * ROWS, 4);   // (heap: static RAM is short beside Bluetooth)
enum { WHITE = 0, YELLOW = 1, GREY = 2, GREEN = 3 };
enum : char { G_TL = 0x01, G_TR = 0x02, G_BL = 0x03, G_BR = 0x04, G_HL = 0x05, G_VL = 0x06, G_BLOCK = 0x07, G_DIAMOND = 0x0F,
              G_CURSOR = 0x10, G_UP = 0x1E, G_DOWN = 0x1F };
static bool barRow[ROWS];

static bool drawable(char c) { return (uint8_t)c >= 0x20 || (c >= G_TL && c <= G_BLOCK) || c == G_DIAMOND || c == G_CURSOR || c == G_UP || c == G_DOWN; }
static void put(int col, int row, const String &s, int colour = WHITE, bool hl = false, int width = -1) {
  if (row < 0 || row >= ROWS) return;
  int n = width < 0 ? s.length() : width;
  for (int i = 0; i < n && col + i < COLS; i++) {
    if (col + i < 0) continue;
    char ch = i < (int)s.length() ? s[i] : ' ';
    if (!drawable(ch)) ch = ' ';
    if ((uint8_t)ch > 0x7E) ch = '?';
    cells[row * COLS + col + i] = (uint8_t)ch | (hl ? 0x100 : 0) | (colour << 9) | (barRow[row] ? 0x800 : 0);
  }
}
static void putc_(int col, int row, char c, int colour = WHITE, bool hl = false) { put(col, row, String(c), colour, hl); }
static void centre(int row, const String &s, int colour = WHITE) { put((COLS - (int)s.length()) / 2, row, s, colour); }
static void right(int endCol, int row, const String &s, int colour = WHITE, bool hl = false) { put(endCol - (int)s.length() + 1, row, s, colour, hl); }
// a name cut to fit, with an ellipsis
static String fit(const String &s, int w) { return (int)s.length() <= w ? s : s.substring(0, w - 3) + "..."; }
// a game's name as shown: without the dump's tags -- "(USA, Europe)", "[!]", "(Rev-A)"
static String shown(const String &n) {
  int cut = -1;
  for (int i = 1; i < (int)n.length(); i++)
    if ((n[i] == '(' || n[i] == '[') && n[i - 1] == ' ') { cut = i - 1; break; }
  return cut > 0 ? n.substring(0, cut) : n;
}

// an empty screen: the header bar (rows 0-2) and the footer bar (27-29) lighter
static void clear() {
  for (int r = 0; r < ROWS; r++) barRow[r] = r <= 2 || r >= 27;
  for (int r = 0; r < ROWS; r++) for (int c = 0; c < COLS; c++) cells[r * COLS + c] = ' ' | (barRow[r] ? 0x800 : 0);
}
// a frame from (c0, r0) to (c1, r1), a title set into its top edge
static void frame(int c0, int r0, int c1, int r1, const String &title = "") {
  putc_(c0, r0, G_TL, GREY); putc_(c1, r0, G_TR, GREY); putc_(c0, r1, G_BL, GREY); putc_(c1, r1, G_BR, GREY);
  for (int c = c0 + 1; c < c1; c++) { putc_(c, r0, G_HL, GREY); putc_(c, r1, G_HL, GREY); }
  for (int r = r0 + 1; r < r1; r++) { putc_(c0, r, G_VL, GREY); putc_(c1, r, G_VL, GREY); }
  if (title.length()) put(c0 + 2, r0, " " + title + " ", WHITE);
}
// the header: the name, and what the board is now
static void header(const String &what) {
  putc_(2, 1, G_DIAMOND, YELLOW);
  put(4, 1, "FPGA CONSOLE", YELLOW);
  right(COLS - 3, 1, what, GREY);
}
static void footer(const String &hints) { centre(28, hints, GREY); }
static void show() { fpga.busWrite(OSD_CELLS, cells, COLS * ROWS); }
static void osd(uint32_t ctrl) { fpga.busWrite(OSD_CTRL, ctrl); }

// A message in a box (loading, switching, an error).
static void message(const String &a, const String &b = "", int colour = WHITE) {
  clear();
  header("");
  frame(2, 10, 37, 18);
  centre(13, fit(a, 32), colour);
  if (b.length()) centre(15, fit(b, 32), GREY);
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
  if (n == "ps1" || n == "psx" || n == "playstation" || n == "discs") return 4;
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
  // every console folder in /roms, and /discs (the PlayStation's, where the disc
  // feed has always taken its images from)
  std::vector<String> dirs;
  File d = SD.open("/roms");
  while (d) {
    File e = d.openNextFile();
    if (!e) break;
    if (e.isDirectory() && machineOfFolder(baseName(e)) >= 0) dirs.push_back("/roms/" + baseName(e));
    e.close();
  }
  if (d) d.close();
  if (SD.exists("/discs")) dirs.push_back("/discs");
  for (auto &dir : dirs) {
    int m = machineOfFolder(dir.substring(dir.lastIndexOf('/') + 1));
    {
      File g = SD.open(dir);
      while (g) {
        File f = g.openNextFile();
        if (!f) break;
        String n = baseName(f);
        String lo = n; lo.toLowerCase();
        // (a PlayStation's are its raw 2352-byte .bin images; its BIOS is not a game)
        bool ok = m != 4 || (lo.endsWith(".bin") && !lo.startsWith("scph"));
        if (!f.isDirectory() && n.length() && n[0] != '.' && ok) {
          int dot = n.lastIndexOf('.');
          lists[m].push_back({ dir + "/" + n, dot > 0 ? n.substring(0, dot) : n, (int8_t)m, (uint32_t)f.size() });
        }
        f.close();
      }
      if (g) g.close();
    }
  }
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
static bool (*menuButton)() = nullptr;      // a Bluetooth pad's PS / Home button (pads.h sets it)
static bool open_ = false, gameIn = false;
static String note;                         // one line under the list: what just happened
static const int LIST_TOP = 5, LIST_ROWS = 20;   // inside the frame (rows 4-25)

static int count() { return level == 0 ? (int)consoles.size() : (int)lists[cur].size(); }
// how many fit (a row free under the frame's title and above its bottom)
static int pageRows() { return level == 0 ? (LIST_ROWS - 2) / 2 + 1 : LIST_ROWS - 2; }

static void draw() {
  clear();
  Status st = fpga.status();
  int cm = machineOfCore(st.core);
  header(cm >= 0 ? String(MACHINES[cm].name) : String(""));
  int n = count();
  if (level == 0) frame(1, 4, 38, 25, "CONSOLES");
  else frame(1, 4, 38, 25, String(MACHINES[cur].name) + "  " + n + (n == 1 ? " game" : " games"));
  if (level == 0 && consoles.empty()) {
    centre(13, haveCard ? "no games on the card" : "no SD card", YELLOW);
    centre(15, "roms/nes  sms  md  n64   discs", GREY);
  }
  // (the consoles a line apart -- there are few -- the games one under another)
  int step = level == 0 ? 2 : 1, rows = pageRows();
  if (sel < top) top = sel;
  if (sel >= top + rows) top = sel - rows + 1;
  for (int r = 0; r < rows && top + r < n; r++) {
    int i = top + r, row = LIST_TOP + 1 + r * step;
    bool here = i == sel;
    put(2, row, "", WHITE, here, 36);                                  // the bar, frame to frame
    if (here) putc_(3, row, G_CURSOR, YELLOW, true);
    if (level == 0) {
      int m = consoles[i];
      put(5, row, MACHINES[m].name, m == cm ? GREEN : WHITE, here);
      right(36, row, String(lists[m].size()) + (lists[m].size() == 1 ? " game" : " games"), GREY, here);
    } else {
      put(5, row, fit(shown(lists[cur][i].name), 31), WHITE, here);
    }
  }
  if (top > 0) putc_(38, LIST_TOP + 1, G_UP, YELLOW);
  if (top + rows < n) putc_(38, LIST_TOP + LIST_ROWS - 2, G_DOWN, YELLOW);
  if (level == 1 && n > rows) right(36, 25, " " + String(sel + 1) + "/" + n + " ", GREY);
  put(2, 26, fit(note, 36), YELLOW);
  footer(level == 0 ? (gameIn ? "A open    B back to the game" : "A open")
                    : "A play     B back     L/R page");
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
  if (c == 3) {          // the PlayStation's order (pc/server.py _PS1_BITS): cross 14, circle 13, select 0, start 3, up 4, right 5, down 6, left 7
    uint8_t o = 0;
    if (v & 0x4000) o |= B_A; if (v & 0x2000) o |= B_B; if (v & 0x0001) o |= B_SEL; if (v & 0x0008) o |= B_START;
    if (v & 0x0010) o |= B_UP; if (v & 0x0040) o |= B_DOWN; if (v & 0x0080) o |= B_LEFT; if (v & 0x0020) o |= B_RIGHT;
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
static const uint32_t SYS_PCHK = 0x00000018;   // the board's checksum of cartridge writes
static bool pchkOk = false;                 // this core keeps it (older ones do not)
static void probeChecksum() {
  // a word into the cartridge window (the load writes over it) and the sum it must make
  fpga.busWrite(SYS_PCHK, 0);
  fpga.busWrite(NES_PRG, 0x5A5A5A5A);
  pchkOk = fpga.busRead(SYS_PCHK) == (NES_PRG ^ 0x5A5A5A5Au);
}
static uint32_t loadFixes = 0;              // chunks written again this load
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
    // written and checked: the board folds every word it takes into a checksum with
    // its address (regfile.v pchk, SYS 0x0018), the same sum is made here, and a chunk
    // whose sums differ goes again -- the wire to the FPGA flips a bit now and then,
    // and a game loaded with a few wrong bytes showed corrupted tiles in its title
    uint32_t want_c = 0;
    const uint32_t *w32 = (const uint32_t *)buf;
    for (size_t k = 0; k < words; k++) want_c = ((want_c << 1) | (want_c >> 31)) ^ (addr + 4 * k) ^ w32[k];
    bool same = false;
    for (int tries = 0; tries < 4 && !same; tries++) {
      if (tries) loadFixes++;
      if (pchkOk) fpga.busWrite(SYS_PCHK, 0);
      fpga.busWrite(addr, w32, words);
      same = !pchkOk || fpga.busRead(SYS_PCHK) == want_c;
    }
    if (!same) return false;
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

// --- the PlayStation's memory card ----------------------------------------------
// /saves/card1.mcr on the card (raw 128 kB, the format DuckStation reads), put into the
// board's DDR3 card with the BIOS; every sector the game stores is queued on the board
// (ps1_sio.v, CARD_Q) and copied back into the file from here -- as pc/server.py's
// MemCard does over Ethernet. A missing file becomes a freshly formatted card.
static const uint32_t CARD_Q = NES + 0x138, HR_LINE = NES + 0x7C, HR_DATA = NES + 0x80;
static const uint32_t CARD_LINE = 0x090000, CARD_BYTES = 128 * 1024;
static const char *CARD_PATH = "/saves/card1.mcr";
static bool cardIn = false;

// a formatted, empty card (DuckStation's MemoryCardImage::Format)
static void blankCard(uint8_t *d) {
  memset(d, 0xFF, CARD_BYTES);
  auto frame = [&](int n, const uint8_t *head, int hn, bool chk) {
    uint8_t *f = d + n * 128;
    memset(f, 0, 128);
    memcpy(f, head, hn);
    if (chk) { uint8_t c = 0; for (int i = 0; i < 127; i++) c ^= f[i]; f[127] = c; }
  };
  const uint8_t mc[] = { 'M', 'C' };
  const uint8_t dir[] = { 0xA0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF };
  const uint8_t bad[] = { 0xFF, 0xFF, 0xFF, 0xFF, 0, 0, 0, 0, 0xFF, 0xFF };
  frame(0, mc, 2, true);
  for (int n = 1; n < 16; n++) frame(n, dir, sizeof(dir), true);
  for (int n = 16; n < 36; n++) frame(n, bad, sizeof(bad), true);
  for (int n = 36; n < 63; n++) frame(n, nullptr, 0, false);
  memcpy(d + 63 * 128, d, 128);
}

static bool cardInsert() {
  cardIn = false;
  if (!SD.exists(CARD_PATH)) {
    SD.mkdir("/saves");
    uint8_t *d = (uint8_t *)malloc(CARD_BYTES);
    if (!d) return false;
    blankCard(d);
    File w = SD.open(CARD_PATH, FILE_WRITE);
    if (w) { w.write(d, CARD_BYTES); w.close(); }
    free(d);
    Serial.println("menu: a new memory card, " + String(CARD_PATH));
  }
  File f = SD.open(CARD_PATH);
  if (!f || f.size() != CARD_BYTES) { if (f) f.close(); return false; }
  fpga.busWrite(CARD_CTL, 0b0010);                 // the fill goes to card 1
  fpga.busWrite(NES_CART_BANK, 0);
  bool ok = stream(f, NES_PRG, CARD_BYTES);
  f.close();
  fpga.busWrite(CARD_Q, 1u << 31);                 // a fresh card owes the file nothing
  for (int i = 0; i < 32 && ((fpga.busRead(CARD_Q) >> 16) & 0x1F); i++) fpga.busWrite(CARD_Q, 1);
  fpga.busWrite(CARD_CTL, ok ? 0b0001 : 0);         // card 1 in
  cardIn = ok;
  return ok;
}

// one DDR3 line (16 bytes) through the console's window
static bool cardLine(uint32_t line, uint8_t *out) {
  fpga.busWrite(HR_LINE, line);
  for (int i = 0; i < 200; i++)
    if (fpga.busRead(HR_LINE) >> 31) {
      for (int k = 0; k < 4; k++) { uint32_t w = fpga.busRead(HR_DATA + 4 * k); memcpy(out + 4 * k, &w, 4); }
      return true;
    }
  return false;
}

// what the game has stored since last time, into the file
static void cardService() {
  if (!cardIn) return;
  uint32_t q = fpga.busRead(CARD_Q);
  bool ovf = q >> 31; uint32_t n = (q >> 16) & 0x1F, slot = (q >> 10) & 1, sec = q & 0x3FF;
  if (!ovf && !n) return;
  File f = SD.open(CARD_PATH, "r+");
  if (!f) return;
  uint8_t sector[128];
  if (ovf) {                                        // more than the queue held: the whole card
    for (uint32_t s2 = 0; s2 < 1024; s2++) {
      for (int k = 0; k < 8; k++) if (!cardLine(CARD_LINE + s2 * 8 + k, sector + 16 * k)) { f.close(); return; }
      f.seek(s2 * 128); f.write(sector, 128);
    }
    fpga.busWrite(CARD_Q, 1u << 31);
    for (int i = 0; i < 32 && ((fpga.busRead(CARD_Q) >> 16) & 0x1F); i++) fpga.busWrite(CARD_Q, 1);
  } else if (slot == 0) {
    for (int k = 0; k < 8; k++) if (!cardLine(CARD_LINE + sec * 8 + k, sector + 16 * k)) { f.close(); return; }
    f.seek(sec * 128); f.write(sector, 128);
    fpga.busWrite(CARD_Q, 1);
  } else fpga.busWrite(CARD_Q, 1);                 // (slot 2 has no file here)
  f.close();
}

// --- the N64's save EEPROM ---------------------------------------------------------
// Which games have one, and its size, by the game ID at 0x3B (pc/n64_saves.py's table,
// from the games' own documentation). The EEPROM lives on the board (ctrl 0x16C, a byte
// at a time); /saves/n64/<id> <title>.eep holds it between sessions, written back
// whenever it has changed (looked at every 20 s, as the PC server does).
static const char *EEP_4K = " CLB NAB NAD NAG NB6 NBC NBD NBH NBK NBM NBN NBV NCG NCH NCR NCT NCU NCX NDQ NDR NDU NDY NEA NER NF2 NFG NFH NFW NFX NFY NGE NGL NGU NGV NHA NHF NHP NIC NIJ NIR NJK NJM NK2 NKA NKI NKT NLB NLL NLR NMG NMI NML NMO NMR NMS NMU NMW NMZ NN6 NNA NOS NP2 NPG NPT NPW NPY NRA NRC NRS NS3 NS6 NSA NSC NSN NSS NSU NSV NSW NT6 NTB NTC NTJ NTM NTN NTP NTR NTW NTX NVL NVY NWC NWQ NWU NXO NYK ";
static const char *EEP_16K = " N3D NB7 NCW NCZ ND2 ND3 ND4 ND6 NDO NEP NEV NFU NGC NGT NIM NM8 NMV NMX NNB NPD NPP NR7 NRZ NUB NYS ";
static const uint32_t N64_CFG = NES + 0x168, N64_EEP = NES + 0x16C;
static String eepPath; static uint16_t eepSize = 0; static uint8_t *eepLast = nullptr;
static uint32_t eepCheck = 0;

static uint16_t eepromSize(const uint8_t *h) {           // h: the header, z64 byte order
  char gid[4] = { (char)h[0x3B], (char)h[0x3C], (char)h[0x3D], 0 };
  char region = h[0x3E]; uint8_t rev = h[0x3F];
  String g = gid;
  if (g == "NK4") return (region == 'J' && rev < 2) ? 0 : 2048;
  if (g == "NDK" || g == "NWT") return region == 'J' ? 512 : 0;
  if (g == "ND3" || g == "ND4") return region == 'J' ? 2048 : 0;
  if (g == "NWR" || g == "NSM") return 512;              // Wave Race 64, Super Mario 64
  if (g.substring(1) == "ED") return (rev >> 4) == 1 ? 512 : (rev >> 4) == 2 ? 2048 : 0;
  String key = " " + g + " ";
  if (strstr(EEP_4K, key.c_str())) return 512;
  if (strstr(EEP_16K, key.c_str())) return 2048;
  return 0;
}

static void eepBegin(const uint8_t *h) {
  eepSize = eepromSize(h);
  fpga.busWrite(N64_CFG, (0b0001 << 4) | (eepSize == 512 ? 1 : eepSize == 2048 ? 2 : 0));   // pad 1 in
  if (!eepSize) { eepPath = ""; return; }
  String name;
  for (int i = 0x3B; i < 0x3F; i++) name += (char)h[i];
  name += " ";
  for (int i = 0x20; i < 0x34; i++) { char c = h[i]; name += (isalnum(c) || c == ' ' || c == '-' || c == '_') ? c : '_'; }
  name.trim();
  eepPath = "/saves/n64/" + name + ".eep";
  if (!eepLast) eepLast = (uint8_t *)malloc(2048);
  memset(eepLast, 0, 2048);
  File f = SD.open(eepPath);
  if (f) { f.read(eepLast, eepSize); f.close(); }
  for (int a = 0; a < eepSize; a++) fpga.busWrite(N64_EEP, (1u << 31) | ((uint32_t)eepLast[a] << 16) | a);
  eepCheck = millis();
}

static void eepService(bool now_ = false) {
  if (!eepSize || !eepPath.length() || (!now_ && millis() - eepCheck < 20000)) return;
  eepCheck = millis();
  static uint8_t now[2048];
  for (int a = 0; a < eepSize; a++) { fpga.busWrite(N64_EEP, a); now[a] = (fpga.busRead(N64_EEP) >> 16) & 0xFF; }
  if (!memcmp(now, eepLast, eepSize)) return;
  SD.mkdir("/saves"); SD.mkdir("/saves/n64");
  File f = SD.open(eepPath, FILE_WRITE);
  if (f) { f.write(now, eepSize); f.close(); memcpy(eepLast, now, eepSize); Serial.println("menu: saved " + eepPath); }
}

// The PlayStation's BIOS: SCPH*.BIN in /bios, /roms/ps1 or /roms.
static String findBios() {
  const char *dirs[] = { "/bios", "/roms/ps1", "/roms" };
  for (const char *dn : dirs) {
    File d = SD.open(dn);
    while (d) {
      File e = d.openNextFile();
      if (!e) break;
      String n = baseName(e), lo = n; lo.toLowerCase();
      bool hit = !e.isDirectory() && lo.startsWith("scph") && e.size() == 512 * 1024;
      e.close();
      if (hit) { d.close(); return String(dn) + "/" + n; }
    }
    if (d) d.close();
  }
  return "";
}

static String load(const Game &g) {
  if (g.m != 4) cardIn = false;
  File f = SD.open(g.path);
  if (!f) return "cannot open " + g.path;
  uint32_t size = f.size();
  if (size > MACHINES[g.m].limit) { f.close(); return "too big for the " + String(MACHINES[g.m].name); }
  probeChecksum();
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
  } else if (g.m == 4) {                             // PlayStation: the BIOS, then the disc
    f.close();
    String bios = findBios();
    if (!bios.length()) return "no PlayStation BIOS on the card (SCPH*.BIN in /roms or /bios)";
    File b = SD.open(bios);
    if (!b) return "cannot open " + bios;
    fpga.busWrite(NES_CONSOLE, 3);
    fpga.busWrite(CARD_CTL, 0);                      // (the fill is the BIOS's; no memory card yet)
    message("loading", "the BIOS");
    bool ok = streamBanks(b, b.size());
    b.close();
    if (!ok) return "the BIOS file ended early";
    fpga.busWrite(NES_FILL_END, 1);
    if (!cardInsert()) Serial.println("menu: no memory card (" + String(CARD_PATH) + ")");
    if (!discInsert(g.path)) return "cannot open the disc " + g.path;
    fpga.busWrite(VID_CTRL, 3);
    fpga.busWrite(NES_CTRL, 1);
    return "";
  } else {                                           // N64: big-endian (.z64) whatever the file
    uint8_t h[64]; f.read(h, 64); f.seek(0);
    int swap = (h[0] == 0x37 && h[1] == 0x80) ? 1 : (h[0] == 0x40 && h[1] == 0x12) ? 2 : 0;
    if (swap == 1) for (int k = 0; k + 1 < 64; k += 2) std::swap(h[k], h[k + 1]);
    if (swap == 2) for (int k = 0; k + 3 < 64; k += 4) { std::swap(h[k], h[k + 3]); std::swap(h[k + 1], h[k + 2]); }
    fpga.busWrite(NES_CONSOLE, 4);
    eepBegin(h);                                     // pad 1 plugged in, the save in
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
  message(String("switching to the ") + M.name, "this takes about a minute");
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
  // the N64 game running now: its save to the card while the N64 is still there
  if (eepSize) { eepService(true); eepSize = 0; }
  Status st = fpga.status();
  if (machineOfCore(st.core) != g.m) {
    String e = switchTo(g.m);
    if (e.length()) { note = e; open_ = true; osd(1); draw(); return; }
  }
  loadFixes = 0;
  String e = load(g);
  if (e.length()) { note = e; draw(); return; }
  note = "";
  gameIn = true; open_ = false;
  osd(0);
  Serial.println("menu: loaded " + g.path + (loadFixes ? " (" + String(loadFixes) + " chunk(s) written again)" : ""));
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
    static uint32_t lastCard = 0;
    if (cardIn && millis() - lastCard > 100) { lastCard = millis(); cardService(); }
    if (gameIn) eepService();
    bool sysMenu = menuButton && menuButton();
    uint8_t p = pad();
    uint8_t edge = p & ~was;
    if (p != was) held = millis();
    bool rep = (p & (B_UP | B_DOWN)) && millis() - held > 350;
    if (rep) held = millis() - 270;                  // ~12 a second once it repeats
    was = p;
    if (edge) Serial.printf("menu: buttons %02x (new %02x), %s, level %d, item %d\n", p, edge, open_ ? "open" : "closed", level, sel);
    if (!open_) {
      if (sysMenu || ((p & (B_START | B_SEL)) == (B_START | B_SEL) && (edge & (B_START | B_SEL)))) openMenu();
      continue;
    }
    if (sysMenu && gameIn) { closeMenu(); continue; }
    int n = count();
    if ((edge | (rep ? p : 0)) & B_UP)   { if (sel > 0) sel--; draw(); }
    if ((edge | (rep ? p : 0)) & B_DOWN) { if (sel + 1 < n) sel++; draw(); }
    if (edge & B_LEFT)  { sel = max(0, sel - pageRows()); draw(); }
    if (edge & B_RIGHT) { sel = max(0, min(n - 1, sel + pageRows())); draw(); }
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
      // (255 while it configures: wait for a real answer)
      while (millis() - t0 < 5000) { uint8_t c = fpga.status().core; if (c != 0 && c != 255) break; delay(100); }
      uint8_t c = fpga.status().core;
      if (c != 0 && c != 255) break;
    }
    Serial.printf("menu: booted the slot's core (%u)\n", fpga.status().core);
  }
  scan();
  for (int m : consoles) Serial.printf("menu: %s, %u games\n", MACHINES[m].name, (unsigned)lists[m].size());
  xTaskCreatePinnedToCore(task, "menu", 8192, nullptr, 1, nullptr, 1);
}

}  // namespace menu
