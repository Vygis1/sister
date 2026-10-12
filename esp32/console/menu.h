// menu.h - the menu on the TV: the games on the card, listed over the HDMI picture
// (the console image's osd.v, written through esp_bus.v), picked with the pad, and
// loaded straight from the card -- the console switched first when the game is for
// another one (back to the shell, the core installed from /cores, booted). And the
// settings: the picture, Wi-Fi (a network picked and its password typed on the screen,
// or a phone shown QR codes), the controllers (pairing, a test, each console's button
// mapping, two players), the system. At power-up: the start-up logo.
//
// Included by console.ino after everything it uses (fpga, the card, installFrom,
// job, prefs, pads.h). What the pages look like is screens.h's; this is what they do.
//
//   START + SELECT, or PS / Home   open the menu (it is open at power-up, on the shell's
//                                  own picture when the shell can draw it: version 2)
//   UP / DOWN                      move; LEFT / RIGHT, L1 / R1 a page at a time
//   CROSS (or START)               open / pick / change
//   CIRCLE                         back (from the consoles: back to the game)
//   TRIANGLE                       the settings, from the consoles
//
// The pads are read on this chip (pads.h), both players driving the menu.

#pragma once
#include <vector>
#include <algorithm>
#include "screens.h"
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
  { "Super NES",     "snes", 'F', 6 * 1024 * 1024 + 512 },   // (+ a copier header, sometimes)
};
static const int NMACH = 6;
static const uint32_t SNES_CFG = NES + 0x180;      // [0] HiROM, [15:8] log2 ROM size, [23:16] log2 save RAM
static const uint32_t CARD_CTL = NES + 0x134;

static int machineOfName(const String &n) {
  String l = n; l.toLowerCase();
  if (l.endsWith(".nes")) return 0;
  if (l.endsWith(".sms")) return 1;
  if (l.endsWith(".md") || l.endsWith(".gen") || l.endsWith(".smd")) return 2;
  if (l.endsWith(".z64") || l.endsWith(".n64") || l.endsWith(".v64")) return 3;
  if (l.endsWith(".sfc") || l.endsWith(".smc")) return 5;
  return -1;
}
static int machineOfCore(uint8_t id) {
  for (int i = 0; i < NMACH; i++) if (MACHINES[i].id == id) return i;
  return -1;
}

// A game's path and name live in a pool in the external PSRAM, the lists likewise: hundreds
// of small Strings in internal RAM left it in pieces too small for Wi-Fi's buffers and the
// card's DMA (the web server stopped answering).
struct Game { const char *path, *name; int8_t m; uint32_t size; };
template <class T> struct PsAlloc {
  typedef T value_type;
  PsAlloc() = default;
  template <class U> PsAlloc(const PsAlloc<U> &) {}
  T *allocate(size_t n) { void *p = heap_caps_malloc(n * sizeof(T), MALLOC_CAP_SPIRAM); if (!p) p = malloc(n * sizeof(T)); return (T *)p; }
  void deallocate(T *p, size_t) { free(p); }
  bool operator==(const PsAlloc &) const { return true; }
  bool operator!=(const PsAlloc &) const { return false; }
};
static std::vector<char *> poolChunks;
static size_t poolLeft = 0;
static char *poolAt = nullptr;
static const char *pooled(const String &s) {
  size_t n = s.length() + 1;
  if (n > poolLeft) {
    size_t sz = n > 16384 ? n : 16384;
    char *c = (char *)heap_caps_malloc(sz, MALLOC_CAP_SPIRAM);
    if (!c) c = (char *)malloc(sz);
    poolChunks.push_back(c); poolAt = c; poolLeft = sz;
  }
  char *r = poolAt;
  memcpy(r, s.c_str(), n);
  poolAt += n; poolLeft -= n;
  return r;
}
static void poolClear() { for (char *c : poolChunks) free(c); poolChunks.clear(); poolLeft = 0; poolAt = nullptr; }

// The shell draws the menu itself from version 2 (osd.v and the pad register on its own
// bus): the menu runs there with no console booted, and installs one when a game wants it.
static bool shellMenu(const Status &s) { return s.alive && s.core == 0 && s.version >= 2; }


// --- the screen: ui.h's cells, sent to osd.v ---------------------------------------------------
// (version 2 has the menu's own glyphs and palette; the console images built before it,
// version 1, get plain characters -- ui.h folds them)
static const uint32_t OSD_ID = OSD + 0x00, OSD_GLYPHS = OSD + 0x4000;
static scr::Chrome chrome();
static void hookUi() {
  ui::hal.cells = [](int first, const uint32_t *v, int n) { fpga.busWrite(OSD_CELLS + 4 * first, v, n); };
  ui::hal.reg = [](uint32_t off, uint32_t v) { fpga.busWrite(OSD + off, v); };
  ui::hal.glyphRows = [](int first, const uint32_t *rows, int n) { fpga.busWrite(OSD_GLYPHS + 4 * first, rows, n); };
}
// a console image (or the shell) has just come up: what its osd.v is, and the menu's glyphs
// and palette into it (they do not survive a new bitstream)
static void freshBoard() {
  ui::v2 = fpga.busRead(OSD_ID) == 0x4F534432;     // "OSD2"
  // The glyphs again only when the board has lost them -- a new bitstream: palette entry 7
  // is black only once this menu has set it (osd.v powers up with orange there). Sending
  // ~500 words when they were still there held up a PlayStation game's disc feed on the same
  // link -- which made the drive's ring-restart race (fixed in ps1_cdrom.v, sb_stale) likelier.
  bool kept = ui::v2 && fpga.busRead(OSD + 0x5C) == 0x000000;
  ui::forget();
  if (!kept) { ui::loadGlyphs(); Serial.println("menu: the board's glyphs loaded"); }
  ui::palette(art::MENU_PAL);
}
static void osd(uint32_t ctrl) { ui::ctrl(ctrl); }
static void show() { ui::flush(); }

// A message in a box (loading, switching, an error).
static void message(const String &a, const String &b = "", int colour = ui::WHITE) {
  scr::message(chrome(), a.c_str(), b.c_str(), colour);
  show(); osd(1);
}

// a game's name as shown: without the dump's tags -- "(USA, Europe)", "[!]", "(Rev-A)"
static String shown(const String &n) {
  int cut = -1;
  for (int i = 1; i < (int)n.length(); i++)
    if ((n[i] == '(' || n[i] == '[') && n[i - 1] == ' ') { cut = i - 1; break; }
  return cut > 0 ? n.substring(0, cut) : n;
}

// --- the card: a folder in /roms for each console ------------------------------------
// /roms/nes, /roms/sms, /roms/md (or genesis, megadrive), /roms/n64. A game loose in
// /roms itself is moved into its console's folder, by its extension, the first time
// the card is seen; anything not recognised (a BIOS, a .bin) stays where it is.
static std::vector<Game, PsAlloc<Game>> lists[NMACH];
static std::vector<int> consoles;          // the machines with a folder, in order

static int machineOfFolder(String n) {
  n.toLowerCase();
  if (n == "nes") return 0;
  if (n == "sms" || n == "mastersystem" || n == "master system") return 1;
  if (n == "md" || n == "genesis" || n == "megadrive" || n == "mega drive") return 2;
  if (n == "n64") return 3;
  if (n == "ps1" || n == "psx" || n == "playstation" || n == "discs") return 4;
  if (n == "snes" || n == "sfc" || n == "superfamicom" || n == "super nes") return 5;
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
  poolClear();
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
          lists[m].push_back({ pooled(dir + "/" + n), pooled(dot > 0 ? n.substring(0, dot) : n), (int8_t)m, (uint32_t)f.size() });
        }
        f.close();
      }
      if (g) g.close();
    }
  }
  for (int m = 0; m < NMACH; m++) {
    std::sort(lists[m].begin(), lists[m].end(), [](const Game &a, const Game &b) { return strcasecmp(a.name, b.name) < 0; });
    if (!lists[m].empty()) consoles.push_back(m);
  }
}

// --- the settings --------------------------------------------------------------
static bool bootLast() { prefs.begin("menu", true); bool v = prefs.getBool("bootlast", false); prefs.end(); return v; }

// The picture's settings: one word into every console (0x17C on its page), as n64_vid
// reads it -- [1:0] scaling, [3:2] scanlines, [5:4] the N64's VI filters, [6] dedither,
// [7] no gamma, [8] the N64 draws without dither, [9] the PlayStation does.
static const uint32_t VID_OPT = NES + 0x17C;
struct VidSet { const char *name; uint8_t shift, bits; const char *vals[4]; uint8_t n; };
static const VidSet VSET[] = {
  { "Scaling",          0, 3, { "as the console", "sharp", "smooth", "edge-directed" }, 4 },
  { "Scanlines",        2, 3, { "off", "light", "heavy" }, 3 },
  { "N64 VI filters",   4, 3, { "as the game", "off", "all on" }, 3 },
  { "N64 dedither",     6, 1, { "as the game", "always" }, 2 },
  { "N64 gamma",        7, 1, { "as the game", "off" }, 2 },
  { "N64 dither",       8, 3, { "as the game", "off" }, 2 },
};
static const int NVSET = sizeof(VSET) / sizeof(VSET[0]);
static const int NSET = 2 + NVSET;          // at power-up, the picture's, back
static uint32_t vidOpt() { prefs.begin("menu", true); uint32_t v = prefs.getUInt("vid", 0); prefs.end(); return v; }
static int vidVal(int k) { const VidSet &v = VSET[k]; int x = (vidOpt() >> v.shift) & v.bits; return x == (int)v.bits && v.shift == 8 ? 1 : min(x, v.n - 1); }
static void vidStep(int k) {
  const VidSet &v = VSET[k];
  int x = (vidVal(k) + 1) % v.n;
  uint32_t o = vidOpt() & ~((uint32_t)v.bits << v.shift);
  o |= (uint32_t)(v.shift == 8 ? (x ? 3 : 0) : x) << v.shift;    // (both consoles' dither at once)
  prefs.begin("menu", false); prefs.putUInt("vid", o); prefs.end();
}
static void applyVideo() { fpga.busWrite(VID_OPT, vidOpt()); }
static bool splashOn() { prefs.begin("menu", true); bool v = prefs.getBool("splash", true); prefs.end(); return v; }

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

// a buffer in the external PSRAM when there is one (internal RAM is short beside Bluetooth:
// the menu's own stack needs it)
static uint8_t *bigBuf(size_t n) {
  void *p = heap_caps_malloc(n, MALLOC_CAP_SPIRAM);
  return (uint8_t *)(p ? p : malloc(n));
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
  if (!eepLast) eepLast = bigBuf(2048);
  memset(eepLast, 0, 2048);
  File f = SD.open(eepPath);
  if (f) { f.read(eepLast, eepSize); f.close(); }
  for (int a = 0; a < eepSize; a++) fpga.busWrite(N64_EEP, (1u << 31) | ((uint32_t)eepLast[a] << 16) | a);
  eepCheck = millis();
}

static void eepService(bool now_ = false) {
  if (!eepSize || !eepPath.length() || (!now_ && millis() - eepCheck < 20000)) return;
  eepCheck = millis();
  static uint8_t *now = bigBuf(2048);
  for (int a = 0; a < eepSize; a++) { fpga.busWrite(N64_EEP, a); now[a] = (fpga.busRead(N64_EEP) >> 16) & 0xFF; }
  if (!memcmp(now, eepLast, eepSize)) return;
  SD.mkdir("/saves"); SD.mkdir("/saves/n64");
  File f = SD.open(eepPath, FILE_WRITE);
  if (f) { f.write(now, eepSize); f.close(); memcpy(eepLast, now, eepSize); Serial.println("menu: saved " + eepPath); }
}

// --- the SNES's save RAM -------------------------------------------------------------
// On the board (up to 8 kB; ctrl 0x184 the pointer -- a write reads the word there into
// 0x188, and bit 31 clears the written flag, which 0x184 reads in bit 0 -- and 0x188 the
// word, a write storing it and moving the pointer on); /saves/snes/<game>.srm holds it
// between sessions, written back when the game has written to it and it has changed.
static const uint32_t SNES_HPTR = NES + 0x184, SNES_HWORD = NES + 0x188;
static String srmPath; static uint32_t srmSize = 0; static uint8_t *srmLast = nullptr;
static uint32_t srmCheck = 0;

static void srmBegin(const String &rom, uint32_t size) {
  srmSize = size;
  if (!size) { srmPath = ""; return; }
  String n = rom.substring(rom.lastIndexOf('/') + 1);
  int dot = n.lastIndexOf('.');
  if (dot > 0) n = n.substring(0, dot);
  srmPath = "/saves/snes/" + n + ".srm";
  if (!srmLast) srmLast = bigBuf(8192);
  memset(srmLast, 0, 8192);                         // (no save yet: cleared, not the last game's)
  File f = SD.open(srmPath);
  if (f) { f.read(srmLast, size); f.close(); }
  fpga.busWrite(SNES_HPTR, 1u << 31);
  for (uint32_t a = 0; a < size; a += 4)
    fpga.busWrite(SNES_HWORD, srmLast[a] | srmLast[a + 1] << 8 | srmLast[a + 2] << 16 | (uint32_t)srmLast[a + 3] << 24);
  srmCheck = millis();
}

static void srmService(bool now_ = false) {
  if (!srmSize || !srmPath.length() || (!now_ && millis() - srmCheck < 5000)) return;
  srmCheck = millis();
  if (!(fpga.busRead(SNES_HPTR) & 1)) return;      // not written since the last look
  fpga.busWrite(SNES_HPTR, 1u << 31);              // (cleared first: a write while this reads sets it again)
  static uint8_t *now = bigBuf(8192);
  for (uint32_t a = 0; a < srmSize; a += 4) {
    fpga.busWrite(SNES_HPTR, a);
    uint32_t w = fpga.busRead(SNES_HWORD);
    now[a] = w; now[a + 1] = w >> 8; now[a + 2] = w >> 16; now[a + 3] = w >> 24;
  }
  if (!memcmp(now, srmLast, srmSize)) return;
  SD.mkdir("/saves"); SD.mkdir("/saves/snes");
  File f = SD.open(srmPath, FILE_WRITE);
  if (f) { f.write(now, srmSize); f.close(); memcpy(srmLast, now, srmSize); Serial.println("menu: saved " + srmPath); }
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
  if (!f) return String("cannot open ") + g.path;
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
    if (!discInsert(g.path)) return String("cannot open the disc ") + g.path;
    fpga.busWrite(VID_CTRL, 3);
    fpga.busWrite(NES_CTRL, 1);
    return "";
  } else if (g.m == 5) {                             // SNES: into DDR3; its shape from the header
    uint32_t base = (size % 1024 == 512) ? 512 : 0;  // (a copier's header in front)
    uint32_t rom = size - base;
    // LoROM's header is at 7FC0, HiROM's at FFC0: the one whose checksum and complement
    // agree, and whose map byte says so, wins
    int best = 0; uint8_t hh[2][32];
    for (int k = 0; k < 2; k++) {
      memset(hh[k], 0, 32);
      uint32_t at = base + (k ? 0xFFC0 : 0x7FC0);
      if (at + 32 <= size) { f.seek(at); f.read(hh[k], 32); }
    }
    int score[2];
    for (int k = 0; k < 2; k++) {
      uint16_t ck = hh[k][0x1C] | hh[k][0x1D] << 8, cs = hh[k][0x1E] | hh[k][0x1F] << 8;
      uint8_t mode = hh[k][0x15] & 0xEF;
      score[k] = ((ck ^ cs) == 0xFFFF ? 2 : 0) + (mode == (k ? 0x21 : 0x20) || mode == (k ? 0x31 : 0x30) ? 1 : 0);
    }
    best = score[1] > score[0] ? 1 : 0;
    uint32_t romLog = 0; while ((1u << romLog) < rom) romLog++;
    uint8_t ramSz = hh[best][0x18];                  // save RAM: 1 << n kB (0: none)
    uint32_t ramLog = ramSz ? min(13, ramSz + 10) : 0;   // (8 kB of it on the board)
    fpga.busWrite(NES_CONSOLE, 5);                   // first: the fill only reaches the selected core
    fpga.busWrite(SNES_CFG, best | romLog << 8 | ramLog << 16);
    f.seek(base);
    if (!streamBanks(f, rom)) err = "the file ended early";
    srmBegin(g.path, ramLog ? 1u << ramLog : 0);     // the save in
    fpga.busWrite(VID_CTRL, 3); fpga.busWrite(SYN_CTRL, 3);
    if (!err.length()) fpga.busWrite(NES_CTRL, 1);
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
  // Install (unless the slot holds this core already) and boot; and if it does not come
  // up, once more with the install forced: the slot is not always what was last put
  // there (one was found blank), and a dark screen is no answer.
  for (int round = 0; round < 2; round++) {
    prefs.begin("menu", true); String inSlot = prefs.getString("slot", ""); uint32_t inSize = prefs.getUInt("size", 0); prefs.end();
    if (round == 1 || inSlot != M.core || inSize != (uint32_t)f.size()) {
      if (round == 1) message(String("the ") + M.name + " did not start", "installing it again");
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
    // (boot asked twice if the first did not take: once, it did not)
    for (int tries = 0; tries < 2; tries++) {
      fpga.boot(true);
      t0 = millis();
      while (millis() - t0 < 5000) {
        delay(100);
        Status s = fpga.status();
        if (s.alive && s.core == M.id) { f.close(); return ""; }
      }
    }
    // not up: back in the shell (the fallback takes it there; else PROGRAM_B) for the next round
    Serial.printf("menu: the %s did not come up (round %d)\n", M.name, round + 1);
    t0 = millis();
    while (millis() - t0 < 3000 && fpga.status().core != 0) delay(100);
    if (fpga.status().core != 0) { fpga.forceShell(); delay(3000); }
    prefs.begin("menu", false); prefs.putString("slot", ""); prefs.end();
  }
  f.close();
  return String("the ") + M.name + " core did not come up";
}

// --- the pages -------------------------------------------------------------------------------
// Each page is a list of items (screens.h draws it) and what picking one does; B goes back up
// the way it came. The splash, the pairing page and the pad test are pages of their own.
// (The Wi-Fi pages -- networks, the keyboard, the QR codes -- went with the Wi-Fi, 2026-10-12.)
enum Page { P_HOME, P_GAMES, P_SETTINGS, P_PICTURE,
            P_PADS, P_PAIR, P_TEST, P_MAPS, P_MAP, P_WAITBTN, P_SYSTEM, P_ABOUT };
struct Nav { Page page; int sel, top; };
static Nav nav = { P_HOME, 0, 0 };
static std::vector<Nav> backStack;
static int cur = 0;                         // the console whose games are shown
static bool (*menuButton)() = nullptr;      // a pad's PS / Home button (console.ino sets it)
static bool open_ = false, gameIn = false;
static volatile bool scanned = false;       // the card's games are listed (begin(), after the task starts)
static String note;                         // one line under the list: what just happened
static String gameName;                     // the game in the console now
static uint32_t pageT0 = 0;                 // when this page came up (the pairing countdown)

// mapping: the console's layout and button being set; which of its two pad buttons
static int mapL = 0, mapB = 0, mapSlot = 0;

static scr::Chrome chrome() {
  scr::Chrome c;
  pads::Player p[2]; pads::view(p);
  c.pad1 = p[0].on; c.pad2 = p[1].on;
  if (gameIn) c.running = gameName.c_str();
  return c;
}
static std::string padText(const pads::Player &p) {
  if (!p.on) return "none";
  std::string s = p.name;
  if (p.battery >= 0) s += "  " + std::to_string(p.battery) + "%";
  return s;
}

// --- each page's items ------------------------------------------------------------------------
using scr::Item;
static Item item(const char *t, uint8_t icon = 0, int iconInk = ui::WHITE, const std::string &value = "", int valueInk = ui::GREY, bool gap = false) {
  Item x; x.text = t; x.icon = icon; x.iconInk = iconInk; x.value = value; x.valueInk = valueInk; x.gap = gap; return x;
}
static std::vector<Item> items() {
  std::vector<Item> v;
  switch (nav.page) {
  case P_HOME:
    if (gameIn) v.push_back(item(("Back to " + gameName).c_str(), art::G_RIGHT, ui::GREEN));
    for (size_t i = 0; i < consoles.size(); i++) {
      int m = consoles[i];
      size_t n = lists[m].size();
      Item x = item(MACHINES[m].name, art::G_PAD, ui::PINK, std::to_string(n) + (n == 1 ? " game" : " games"));
      if (i == 0 && gameIn) x.gap = true;
      v.push_back(x);
    }
    v.push_back(item("Settings", art::G_GEAR, ui::YELLOW, "", ui::GREY, true));
    break;
  case P_GAMES:
    for (auto &g : lists[cur]) v.push_back(item(shown(g.name).c_str()));
    break;
  case P_SETTINGS: {
    v.push_back(item("Picture", art::G_HEART, ui::PINK, "scaling, scanlines"));
    pads::Player p[2]; pads::view(p);
    int n = p[0].on + p[1].on;
    v.push_back(item("Controllers", art::G_PAD, ui::GREEN, std::to_string(n) + " connected"));
    v.push_back(item("System", art::G_GEAR, ui::YELLOW));
    v.push_back(item("About", art::G_TICK, ui::BLUE));
    break; }
  case P_PICTURE:
    for (int k = 0; k < NVSET; k++) v.push_back(item(VSET[k].name, 0, 0, VSET[k].vals[vidVal(k)], ui::YELLOW));
    break;
  case P_PADS: {
    pads::Player p[2]; pads::view(p);
    v.push_back(item("Player 1", art::G_PAD, p[0].on ? ui::GREEN : ui::GREY, padText(p[0])));
    v.push_back(item("Player 2", art::G_PAD, p[1].on ? ui::GREEN : ui::GREY, padText(p[1])));
    v.push_back(item("Pair a new controller", art::G_BT, ui::BLUE, "", ui::GREY, true));
    v.push_back(item("Test the controllers", art::G_CROSS, ui::BLUE));
    v.push_back(item("Button mapping", art::G_SQUARE, ui::PINK));
    v.push_back(item("Swap players 1 and 2", art::G_RIGHT, ui::WHITE, pads::swapPlayers ? "swapped" : ""));
    v.push_back(item("Forget paired controllers", art::G_CIRCLE, ui::RED));
    break; }
  case P_MAPS:
    for (int l = 0; l < pads::NLAYOUTS; l++) v.push_back(item(pads::LAYOUTS[l].name, art::G_PAD, ui::PINK));
    break;
  case P_MAP: {
    const pads::Layout &L = pads::LAYOUTS[mapL];
    for (int i = 0; i < L.n; i++) {
      std::string s;
      for (int k = 0; k < 2; k++) {
        uint8_t b = pads::bind[mapL][i][k];
        if (b == pads::PB_NONE) continue;
        if (!s.empty()) s += " / ";
        s += pads::PB_NAME[b];
      }
      v.push_back(item(L.b[i].name, 0, 0, s.empty() ? "-" : s, ui::YELLOW));
    }
    v.push_back(item("Back to the usual buttons", art::G_CIRCLE, ui::RED, "", ui::GREY, true));
    break; }
  case P_SYSTEM: {
    v.push_back(item("At power-up", 0, 0, bootLast() ? "the last game" : "this menu", ui::YELLOW));
    v.push_back(item("Start-up logo", 0, 0, splashOn() ? "on" : "off", ui::YELLOW));
    v.push_back(item("Show the start-up logo", art::G_HEART, ui::PINK, "", ui::GREY, true));
    v.push_back(item("Restart the console", art::G_CIRCLE, ui::RED));
    break; }
  default: break;
  }
  return v;
}
static std::vector<std::string> info() {
  std::vector<std::string> v;
  if (nav.page == P_HOME) {
    // (out of the box there is no pad yet, and nothing to press to ask for one: Bluetooth
    // takes new pads from power-up, so say how)
    pads::Player p[2]; pads::view(p);
    if (!p[0].on && !p[1].on) {
      v.push_back("PS4 / PS5:  hold SHARE + PS");
      v.push_back("Xbox:       hold the pair button");
      v.push_back("Switch Pro: hold sync");
    }
  } else if (nav.page == P_SYSTEM || nav.page == P_SETTINGS) {
    Status st = fpga.status();
    int cm = machineOfCore(st.core);
    v.push_back(std::string("board: ") + (st.core == 0 ? "the shell" : cm >= 0 ? MACHINES[cm].name : "a core") +
                ", protocol " + std::to_string(st.version) + (ui::v2 ? "" : " (old menu display)"));
    if (haveCard) v.push_back("SD card: " + std::to_string((uint32_t)(SD.totalBytes() >> 30)) + " GB, " +
                              std::to_string((uint32_t)((SD.totalBytes() - SD.usedBytes()) >> 30)) + " GB free");
    else v.push_back("SD card: none");
  } else if (nav.page == P_PICTURE) {
    v.push_back("left / right or cross change it; at once");
  } else if (nav.page == P_MAP) {
    v.push_back("cross: set the button, square: a second one");
  }
  return v;
}
static const char *title() {
  switch (nav.page) {
  case P_HOME: return "CONSOLES";
  case P_SETTINGS: return "SETTINGS";
  case P_PICTURE: return "PICTURE";
  case P_PADS: return "CONTROLLERS";
  case P_MAPS: return "BUTTON MAPPING";
  case P_SYSTEM: return "SYSTEM";
  default: return "";
  }
}
static std::vector<scr::Hint> hintsFor() {
  using H = scr::Hint;
  switch (nav.page) {
  case P_HOME: return gameIn ? std::vector<H>{ { art::G_CROSS, "open" }, { art::G_CIRCLE, "back to the game" } }
                             : std::vector<H>{ { art::G_CROSS, "open" } };
  case P_GAMES: return { { art::G_CROSS, "play" }, { art::G_CIRCLE, "back" }, { 0, "L1/R1 page" } };
  case P_PICTURE: case P_SYSTEM: return { { art::G_CROSS, "change" }, { art::G_CIRCLE, "back" } };
  case P_MAP: return { { art::G_CROSS, "set" }, { art::G_SQUARE, "second" }, { art::G_CIRCLE, "back" } };
  default: return { { art::G_CROSS, "open" }, { art::G_CIRCLE, "back" } };
  }
}

// --- drawing ----------------------------------------------------------------------------------
static pads::Player testP[2];
static uint8_t waitFor = pads::PB_NONE;
static scr::PadView padView(const pads::Player &p) {
  scr::PadView v;
  v.on = p.on; v.name = p.name; v.battery = p.battery;
  const pads::In &i = p.in;
  v.cross = i.a; v.circle = i.b; v.square = i.x; v.triangle = i.y; v.l1 = i.l1; v.r1 = i.r1; v.l2 = i.l2; v.r2 = i.r2;
  v.sel = i.sel; v.start = i.start; v.home = i.home; v.up = i.du; v.down = i.dd; v.left = i.dl; v.right = i.dr;
  v.lx = i.lx; v.ly = i.ly; v.rx = i.rx; v.ry = i.ry;
  return v;
}
static void draw() {
  // (a closed menu draws nothing: a page drawn after a game started would put the menu
  // back over it, closed -- deaf to everything but START + SELECT)
  if (!open_) return;
  scr::Chrome ch = chrome();
  switch (nav.page) {
  case P_GAMES: {
    size_t n = lists[cur].size();
    std::string t = std::string(MACHINES[cur].name) + "  " + std::to_string(n) + (n == 1 ? " game" : " games");
    scr::list(ch, t, items(), nav.sel, nav.top, {}, note.c_str(), hintsFor(), 1);
    break; }
  case P_PAIR: {
    pads::Player p[2]; pads::view(p);
    std::vector<std::string> names;
    for (auto &q : p) if (q.on) names.push_back(q.name);
    int left = 120 - (int)((millis() - pageT0) / 1000);
    scr::pairing(ch, left < 0 ? 0 : left, names, note.c_str());
    break; }
  case P_TEST:
    scr::tester(ch, padView(testP[0]), padView(testP[1]));
    break;
  case P_WAITBTN: {
    int left = 6 - (int)((millis() - pageT0) / 1000);
    scr::waitButton(ch, pads::LAYOUTS[mapL].name, pads::LAYOUTS[mapL].b[mapB].name, left < 0 ? 0 : left);
    break; }
  case P_ABOUT:
    if (ui::v2) {
      ui::palette(art::SPLASH_PAL);
      scr::splash(scr::SPLASH_FRAMES);
      ui::centre(26, "circle: back", ui::GREY);
    } else {
      // (an image built before the menu's own glyphs: no logo to draw)
      scr::message(ch, "BYBA GAMES", "the FPGA game console", ui::YELLOW);
    }
    break;
  default:
  {
    std::string nt = note.c_str();
    if (nav.page == P_HOME && nt.empty() && !ch.pad1 && !ch.pad2) nt = "No controller yet: pair one now";
    scr::list(ch, title(), items(), nav.sel, nav.top, info(), nt, hintsFor(), nav.page == P_HOME ? 2 : 0);
  }
  }
  bool logo = nav.page == P_ABOUT && ui::v2;
  if (!logo) ui::palette(art::MENU_PAL);
  show();
  osd(logo ? 5 : gameIn ? 3 : 1);
}

static void rescanIfChanged();          // (below, by openMenu)
static void go(Page p, int sel = 0) {
  backStack.push_back(nav);
  nav = { p, sel, 0 };
  pageT0 = millis();
  note = "";
  draw();
}
static void closeMenu();
static void back() {
  note = "";
  if (backStack.empty()) { if (gameIn) closeMenu(); return; }
  nav = backStack.back(); backStack.pop_back();
  pageT0 = millis();
  draw();
}

// --- the splash ---------------------------------------------------------------------------------
static void splash() {
  if (!ui::v2) return;                      // (an old display: no logo to draw)
  ui::palette(art::SPLASH_PAL);
  osd(5);
  uint32_t t0 = millis();
  uint16_t was = pads::menuButtons();
  for (int f = 0; f <= scr::SPLASH_FRAMES; f++) {
    scr::splash(f);
    show();
    while (millis() - t0 < (uint32_t)(f + 1) * 33) delay(2);
    uint16_t b = pads::menuButtons();
    if (b & ~was) break;                    // a button: on with it
    was = b;
  }
  ui::palette(art::MENU_PAL);
}

// --- picking a game ---------------------------------------------------------------------------
static void playGame(const Game &g) {
  // the N64 game running now: its save to the card while the N64 is still there
  if (eepSize) { eepService(true); eepSize = 0; }
  if (srmSize) { srmService(true); srmSize = 0; }    // (the SNES's likewise)
  Status st = fpga.status();
  // (and when it is, but the card holds another image of it than the one installed: a
  // console updated on the card was never installed while it ran -- the newer one is now)
  bool stale = false;
  if (machineOfCore(st.core) == g.m) {
    File cf = SD.open(String("/cores/") + MACHINES[g.m].core + ".bin");
    if (cf) {
      prefs.begin("menu", true); String inSlot = prefs.getString("slot", ""); uint32_t inSize = prefs.getUInt("size", 0); prefs.end();
      stale = inSlot != MACHINES[g.m].core || inSize != (uint32_t)cf.size();
      cf.close();
    }
  }
  pads::busBusy = true;
  if (machineOfCore(st.core) != g.m || stale) {
    String e = switchTo(g.m);
    freshBoard();
    if (e.length()) { pads::busBusy = false; note = e; open_ = true; draw(); return; }
  }
  loadFixes = 0;
  applyVideo();                             // (before the game runs: a core comes up with 0)
  String e = load(g);
  pads::busBusy = false;
  if (e.length()) { note = e; draw(); return; }
  note = "";
  gameIn = true; open_ = false;
  gameName = shown(g.name);
  backStack.clear(); nav = { P_HOME, 0, 0 };
  osd(0);
  prefs.begin("menu", false); prefs.putString("last", g.path); prefs.end();
  Serial.println(String("menu: loaded ") + g.path + (loadFixes ? " (" + String(loadFixes) + " chunk(s) written again)" : ""));
}

// --- what a button does on each page -----------------------------------------------------------
static void pickItem(bool second = false) {
  int s = nav.sel;
  switch (nav.page) {
  case P_HOME: {
    int k = s;
    if (gameIn) { if (k == 0) { closeMenu(); return; } k--; }
    if (k < (int)consoles.size()) { cur = consoles[k]; rescanIfChanged(); go(P_GAMES); }
    else go(P_SETTINGS);
    break; }
  case P_GAMES:
    if (!lists[cur].empty()) playGame(lists[cur][s]);
    break;
  case P_SETTINGS:
    if (s == 0) go(P_PICTURE); else if (s == 1) go(P_PADS);
    else if (s == 2) go(P_SYSTEM); else go(P_ABOUT);
    break;
  case P_PICTURE:
    vidStep(s);
    { Status st = fpga.status(); if (st.alive && machineOfCore(st.core) >= 0) applyVideo(); }
    draw();
    break;
  case P_PADS:
    if (s == 2) { pads::cmd = pads::CMD_PAIR_ON; go(P_PAIR); }
    else if (s == 3) go(P_TEST);
    else if (s == 4) go(P_MAPS);
    else if (s == 5) {
      pads::swapPlayers = !pads::swapPlayers;
      prefs.begin("menu", false); prefs.putBool("swap", pads::swapPlayers); prefs.end();
      draw();
    } else if (s == 6) { pads::cmd = pads::CMD_FORGET; note = "paired controllers forgotten: pair them again"; draw(); }
    break;
  case P_MAPS:
    mapL = s; go(P_MAP);
    break;
  case P_MAP:
    if (s >= pads::LAYOUTS[mapL].n) { pads::defaultBinds(mapL); note = "the usual buttons again"; draw(); break; }
    mapB = s; mapSlot = second ? 1 : 0; waitFor = pads::PB_NONE;
    go(P_WAITBTN);
    break;
  case P_SYSTEM:
    if (s == 0) { bool v = !bootLast(); prefs.begin("menu", false); prefs.putBool("bootlast", v); prefs.end(); draw(); }
    else if (s == 1) { bool v = !splashOn(); prefs.begin("menu", false); prefs.putBool("splash", v); prefs.end(); draw(); }
    else if (s == 2) { splash(); draw(); }
    else if (s == 3) { message("restarting"); delay(300); fpga.forceShell(); ESP.restart(); }
    break;
  default: break;
  }
}

// A game (or a core) put on the card from the PC: the lists read again. They were read once, at
// start-up, and a game copied over Wi-Fi stayed out of the menu until the ESP32 restarted.
static void rescanIfChanged() {
  if (!cardChanged) return;
  cardChanged = false;
  scan();
  Serial.println("menu: the card changed -- its games read again");
}
static void openMenu() {
  rescanIfChanged();
  open_ = true;
  uint32_t c = fpga.busRead(NES_CTRL);
  if (c & 1) fpga.busWrite(NES_CTRL, c | 4);       // pause
  backStack.clear(); nav = { P_HOME, 0, 0 }; note = "";
  draw();
}
static void closeMenu() {
  open_ = false;
  osd(0);
  uint32_t c = fpga.busRead(NES_CTRL);
  fpga.busWrite(NES_CTRL, c & ~4u);
}

// --- the task -------------------------------------------------------------------
static void task(void *) {
  uint16_t was = 0; uint32_t held = 0, lastCheck = 0, lastDraw = 0, circleT = 0; bool up = false;
  for (;;) {
    delay(16);
    // is a console image there to draw on? (gone only after three looks in a row say so: one
    // status frame lost on a busy link made a running game look new, and the glyphs went in
    // again over its disc feed)
    if (millis() - lastCheck > 1000 || !up) {
      lastCheck = millis();
      Status s = fpga.status();
      bool console = s.alive && (machineOfCore(s.core) >= 0 || shellMenu(s));
      static int misses = 0;
      if (console) misses = 0;
      else if (up && ++misses < 3) console = true;   // (not yet: look again)
      if (console && !up) {                          // it came up (power-up, or a core booted by hand)
        up = true;
        freshBoard();
        static bool first = true;
        if (first && splashOn()) splash();
        if (!scanned) { message("reading the card", "a few seconds"); while (!scanned) delay(100); }
        if (!gameIn) { open_ = true; backStack.clear(); nav = { P_HOME, 0, 0 }; draw(); }
        // (at power-up, in the shell: the last game, if the settings say so)
        if (first && s.core == 0 && bootLast()) {
          prefs.begin("menu", true); String last = prefs.getString("last", ""); prefs.end();
          for (int m = 0; m < NMACH && last.length(); m++)
            for (int i = 0; i < (int)lists[m].size(); i++)
              if (last.equals(lists[m][i].path)) { cur = m; playGame(lists[m][i]); m = NMACH; break; }
        }
        first = false;
      }
      if (!console) { up = false; continue; }
    }
    static uint32_t lastCard = 0;
    if (cardIn && millis() - lastCard > 100) { lastCard = millis(); cardService(); }
    if (gameIn) { eepService(); srmService(); }
    bool sysMenu = menuButton && menuButton();
    uint16_t p = pads::menuButtons();
    uint16_t edge = p & ~was;
    if (p != was) held = millis();
    bool rep = (p & (pads::M_UP | pads::M_DOWN | pads::M_LEFT | pads::M_RIGHT)) && millis() - held > 350;
    if (rep) held = millis() - 270;                  // ~12 a second once it repeats
    was = p;
    // (logged once the press has done its work -- whichever way this pass ends -- with the
    // item it leaves highlighted: tools/menunav.py steers by it)
    struct LogAfter {
      uint16_t p, e;
      ~LogAfter() {
        if (!e) return;
        std::string it;
        if (open_) { auto v = items(); if (nav.sel < (int)v.size()) it = v[nav.sel].text; }
        Serial.printf("menu: buttons %04x (new %04x), %s, level %d, item %d [%s]\n", p, e, open_ ? "open" : "closed",
                      nav.page == P_HOME ? 0 : nav.page == P_GAMES ? 1 : 2, nav.sel, it.c_str());
      }
    } logAfter{ p, edge };
    if (!open_) {
      if (sysMenu || ((p & (pads::M_START | pads::M_SEL)) == (pads::M_START | pads::M_SEL) && (edge & (pads::M_START | pads::M_SEL)))) openMenu();
      continue;
    }
    if (sysMenu && gameIn) { closeMenu(); continue; }
    uint16_t press = edge | (rep ? p : 0);
    // pages that are not lists
    if (nav.page == P_ABOUT) { if (edge & (pads::M_B | pads::M_A)) back(); continue; }
    if (nav.page == P_PAIR) {
      if (edge & (pads::M_B | pads::M_A)) { back(); continue; }
      if (millis() - lastDraw > 500) { lastDraw = millis(); draw(); }
      continue;
    }
    if (nav.page == P_TEST) {
      pads::view(testP);
      if (p & pads::M_B) { if (!circleT) circleT = millis(); if (millis() - circleT > 1000) { circleT = 0; back(); continue; } }
      else circleT = 0;
      if (millis() - lastDraw > 50) { lastDraw = millis(); draw(); }
      continue;
    }
    if (nav.page == P_WAITBTN) {
      // the first pad button pressed after everything is let go (6 s, then nothing)
      pads::Player q[2]; pads::view(q);
      uint8_t b = pads::PB_NONE;
      for (auto &x : q) if (x.on && b == pads::PB_NONE) b = pads::firstPressed(x.in);
      if (waitFor == pads::PB_NONE && b == pads::PB_NONE) waitFor = 0xFE;           // all up: listening
      else if (waitFor == 0xFE && b != pads::PB_NONE) {
        pads::bind[mapL][mapB][mapSlot] = b;
        if (mapSlot == 0) pads::bind[mapL][mapB][1] = pads::PB_NONE;
        pads::saveBinds(mapL);
        back();
        note = String(pads::LAYOUTS[mapL].b[mapB].name) + " is now " + pads::PB_NAME[b];
        draw();
        continue;
      }
      if (millis() - pageT0 > 6000) { back(); continue; }
      if (millis() - lastDraw > 500) { lastDraw = millis(); draw(); }
      continue;
    }
    // a list
    int n = (int)items().size();
    int pageRows = nav.page == P_GAMES ? 18 : 9;
    bool change = nav.page == P_PICTURE || nav.page == P_SYSTEM;
    if (press & pads::M_UP)   { if (nav.sel > 0) nav.sel--; else if (n) nav.sel = n - 1; draw(); }
    if (press & pads::M_DOWN) { if (nav.sel + 1 < n) nav.sel++; else nav.sel = 0; draw(); }
    if (change && (edge & (pads::M_LEFT | pads::M_RIGHT)) && nav.page == P_PICTURE) { pickItem(); }
    else if (change && (edge & (pads::M_LEFT | pads::M_RIGHT)) && nav.sel <= 1) { pickItem(); }
    else {
      if (edge & (pads::M_LEFT | pads::M_L1)) { nav.sel = max(0, nav.sel - pageRows); draw(); }
      if (edge & (pads::M_RIGHT | pads::M_R1)) { nav.sel = max(0, min(n - 1, nav.sel + pageRows)); draw(); }
    }
    if ((edge & pads::M_A) || ((edge & pads::M_START) && !(p & pads::M_SEL))) pickItem();
    else if ((edge & pads::M_X) && nav.page == P_MAP) pickItem(true);
    else if ((edge & pads::M_Y) && nav.page == P_HOME) go(P_SETTINGS);
    else if (edge & pads::M_B) back();
    // (the settings pages show live things -- the pads coming and going, Wi-Fi: now and then)
    if (open_ && (nav.page == P_PADS || nav.page == P_SETTINGS || nav.page == P_HOME) && millis() - lastDraw > 1000) {
      lastDraw = millis(); draw();
    }
  }
}

static void begin() {
  buf = (uint8_t *)malloc(BUF);
  hookUi();
  // The board starts in the shell (power-up, or this chip's own reset pulsing
  // PROGRAM_B): start whatever core the slot holds, so the menu has a screen.
  Status s0 = fpga.status();
  if (s0.alive && s0.core == 0 && !s0.busy && !shellMenu(s0)) {
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
  // The task first -- its stack wants one piece of internal RAM, which Bluetooth leaves
  // short and the card's list (hundreds of small names) leaves in pieces -- then the card:
  // the start-up logo plays while it is read.
  size_t big = heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
  BaseType_t ok = pdFAIL;
  uint32_t stack = 0;
  for (uint32_t st : { 10240u, 9216u, 8192u, 7168u })
    if ((ok = xTaskCreatePinnedToCore(task, "menu", st, nullptr, 1, nullptr, 1)) == pdPASS) { stack = st; break; }
  Serial.printf("menu: task %s (stack %u), internal RAM %u free, largest block %u\n", ok == pdPASS ? "running" : "NOT STARTED",
                (unsigned)stack, (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL), (unsigned)big);
  scan();
  for (int m : consoles) Serial.printf("menu: %s, %u games\n", MACHINES[m].name, (unsigned)lists[m].size());
  scanned = true;
}

}  // namespace menu
