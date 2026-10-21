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
//
// The graphical menu (2026-10-17): with the menu image at version 3 (rtl/shell_fb.v: a picture
// under the text) the home screen, the games and the settings are drawn as pictures (gfx.h,
// gfxmenu.h) -- home is the game to carry on with and a tile for each console. Inside a game
// the menu button opens the small text menu: back to the game, reset it, the settings, and
// home (its save to the card, back to the menu image).
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
#include "gfxmenu.h"
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
  { "Game Gear",     "gg",  'G', 256 * 1024 },               // (its cartridge is block RAM, as the Master System's)
  { "Game Boy",      "gb",  'B', 8 * 1024 * 1024 },          // (the cartridge in DDR3, as the SNES's)
  { "Atari 2600",    "a26", 'A', 32 * 1024 },                // (the cartridge in the core's own block RAM)
  { "PC Engine",     "pce", 'E', 1024 * 1024 + 512 },        // (the HuCard in DDR3, as the Game Boy's; + a copier header, sometimes)
  { "GB Advance",    "gba", 'V', 16 * 1024 * 1024 },         // (the cartridge in DDR3; 16 MB is the cache's reach)
  { "PC",            "pc",  'C', 0xFFFFFFFF },               // a hard-disk image (DOS): any size (pc.h)
};
static const int NMACH = 12;
static const uint32_t A26_CFG = NES + 0x1C8;       // [15:0] the image's size, [19:16] its bank scheme (0: by the size)
static const uint32_t PCE_CFG = NES + 0x1CC;       // [19:0] the HuCard image's size in bytes
static const uint32_t GBA_CFG = NES + 0x1D0;       // [24:0] the cartridge's size in bytes, [31] the fill goes to the BIOS memory
static const uint32_t SNES_CFG = NES + 0x180;      // [0] HiROM, [15:8] log2 ROM size, [23:16] log2 save RAM
static const uint32_t CARD_CTL = NES + 0x134;

static int machineOfName(const String &n) {
  String l = n; l.toLowerCase();
  if (l.endsWith(".nes")) return 0;
  if (l.endsWith(".sms")) return 1;
  if (l.endsWith(".md") || l.endsWith(".gen") || l.endsWith(".smd")) return 2;
  if (l.endsWith(".z64") || l.endsWith(".n64") || l.endsWith(".v64")) return 3;
  if (l.endsWith(".sfc") || l.endsWith(".smc")) return 5;
  if (l.endsWith(".gg")) return 6;
  // (.gbc is a Game Boy Color game: the core is one of those too (gb_top, by the cartridge's
  // header) -- both go to /roms/gb; an Atari's .bin is anybody's, so only .a26 says Atari)
  if (l.endsWith(".gb") || l.endsWith(".gbc")) return 7;
  if (l.endsWith(".a26")) return 8;
  if (l.endsWith(".pce")) return 9;
  if (l.endsWith(".gba")) return 10;
  if (l.endsWith(".img") || l.endsWith(".vhd")) return 11;
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
static bool gmode = false;                  // the menu image with a picture: the graphical menu
static bool inCore = false;                 // the board is a console, not the menu image
static void gW1(uint32_t a, uint32_t v) { fpga.busWrite(a, v); }
static uint32_t gR1(uint32_t a) { return fpga.busRead(a); }
// (the pixels in one SPI call, as the PlayStation's XA: a byte a call took seconds a screen)
// (through a buffer in internal RAM: the SPI driver feeds its FIFO from PSRAM slowly)
static bool quadOff = false;                 // "quad off" on the serial console: loads a bit at a time (testing)
static bool quadOk = false;                  // the board takes quad writes (link.h; set by freshBoard)
static bool shellV7 = false;                 // the menu image has two core slots (set by freshBoard)
static void gWN(uint32_t a, const uint32_t *w, size_t n) {
  static uint32_t chunk[512];
  while (n) {
    size_t k = n < 512 ? n : 512;
    memcpy(chunk, w, k * 4);
    if (quadOk) fpga.busWriteQuad(a, chunk, k); else fpga.busWriteFast(a, chunk, k);
    a += 4 * k; w += k; n -= k;
  }
}
// a rectangle of the screen drawn again (the painting called a strip at a time) and sent; the log says
// how long it took
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
  if (!kept) { ui::loadGlyphs(); Log.println("menu: the board's glyphs loaded"); }
  ui::palette(art::MENU_PAL);
  Status st = fpga.status();
  inCore = st.alive && st.core != 0;
  quadOk = !quadOff && fpga.quadWired() && st.alive && (st.core == 0 ? st.version >= 5 : st.version >= 2);
  // (the image's clock, ctrl 0x1F8 -- 0 on images from before it: 50 MHz or more): bulk transfers at 5 MHz
  // below 48 MHz, else 10
  {
    uint32_t hz = inCore ? fpga.busRead(NES + 0x1F8) : 0;
    // (a PC image that does not say -- the first z486 ones at 40 MHz did not -- gets the safe clock too)
    uint32_t want = ((hz > 1000000 && hz < 48000000) || (hz == 0 && inCore && st.core == 'C')) ? 5000000 : 10000000;
    if (want != fpga.bulkHz()) { fpga.setBulkHz(want); Log.printf("menu: the image runs at %u Hz: bulk transfers at %u Hz" "\n", (unsigned)hz, (unsigned)want); }
  }
  shellV7 = st.alive && st.core == 0 && st.version >= 7;
  // (on the menu image: 32 words through the highlight register, read back -- any wrong, no quad)
  if (quadOk && st.core == 0)
    for (int i = 0; i < 32 && quadOk; i++) {
      uint32_t w = esp_random() & 0x03FF03FF;
      fpga.busWriteQuad(0x00090020, &w, 1);
      if (fpga.busRead(0x00090020) != w) quadOk = false;
    }
  Log.printf("menu: link writes %s\n", quadOk ? "quad (4 bits a clock)" : "a bit a clock");
  bool was = gmode;
  // (version 4: the board composes the picture from a list -- rtl/shell_ui.v; the fonts go to it now)
  gfx::link(gW1, gWN, gR1);
  gmode = st.alive && st.core == 0 && st.version >= 4 && gfx::begin();
  if (!gmode && was) gfx::end();
  if (gmode) {
    gfx::hlForget();
    ui::ctrl(0);
  }
  if (gmode != was) Log.printf("menu: the %s menu\n", gmode ? "graphical" : "text");
}
static void osd(uint32_t ctrl) { ui::ctrl(gmode ? 0 : ctrl); }
static void show() { ui::flush(); }
template <class P> static void grender(int x, int y, int w, int h, P paint) {
  uint32_t t0 = millis();
  int n = gfx::render(x, y, w, h, paint, gW1, gWN);
  Log.printf("gfx: %dx%d drawn, %d kB sent, %u ms\n", w, h, n / 1024, (unsigned)(millis() - t0));
}
// the page's top line: the time and the date from the clock (the DS1302)
static time_t clockNow();
static gscr::Top gtop(const std::string &title, const std::string &crumbs = "") {
  gscr::Top t; t.title = title; t.crumbs = crumbs;
  time_t now = clockNow(); struct tm tm; gmtime_r(&now, &tm);
  char a[16], b[24];
  static const char *WD[7] = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
  static const char *MO[12] = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
  snprintf(a, sizeof(a), "%02d:%02d", tm.tm_hour, tm.tm_min);
  snprintf(b, sizeof(b), "%s %d %s", WD[tm.tm_wday], tm.tm_mday, MO[tm.tm_mon]);
  t.time = a; t.date = b;
  return t;
}
// each console's colour (its tile, its pages' light)
static const gfx::RGB MCOL[NMACH] = { { 215, 55, 60 }, { 210, 60, 70 }, { 50, 120, 220 }, { 40, 160, 90 }, { 150, 155, 180 },
                                      { 125, 100, 210 }, { 90, 90, 110 }, { 130, 175, 50 }, { 200, 120, 60 }, { 235, 135, 35 }, { 80, 100, 235 }, { 120, 130, 150 } };
static const gfx::RGB HOME_ACCENT = { 70, 60, 160 };

// A message in a box (loading, switching, an error).
static void message(const String &a, const String &b = "", int colour = ui::WHITE) {
  if (gmode) {
    gfx::highlightOff(gW1);
    gscr::Top t = gtop("FPGA CONSOLE");
    grender(0, 0, gfx::W, gfx::H, [&] { gscr::messageScreen(t, a.c_str(), b.c_str(), HOME_ACCENT); });
    return;
  }
  scr::message(chrome(), a.c_str(), b.c_str(), colour);
  show(); osd(1);
}
// ...with a console's logo over it (and a core's progress going in: installShow)
static String gmA, gmB; static int gmM = -1;
static void gmessage(const String &a, const String &b, int m, float progress = -1) {
  gmA = a; gmB = b; gmM = m;
  gfx::highlightOff(gW1);
  gscr::Top t = gtop("FPGA CONSOLE");
  grender(0, 0, gfx::W, gfx::H, [&] {
    gscr::messageScreen(t, a.c_str(), b.c_str(), m >= 0 ? MCOL[m] : HOME_ACCENT, m, m >= 0 ? MACHINES[m].core : nullptr, progress);
  });
}
// installCard's progress: the last message again, with its bar (four times a second at most). The
// shell's own screen draws it only until the ESP32's first picture.
static void gInstallShow(float f) {
  static uint32_t last = 0;
  if (!gmode || (millis() - last < 1000 && f < 1)) return;   // (each picture costs the install ~50 ms of the link)
  last = millis();
  gmessage(gmA.length() ? gmA : String("installing"), "writing the core", gmM, f);
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
  if (n == "gg" || n == "gamegear" || n == "game gear") return 6;
  if (n == "gb" || n == "gameboy" || n == "game boy") return 7;
  if (n == "a26" || n == "a2600" || n == "atari" || n == "atari2600" || n == "atari 2600") return 8;
  if (n == "pce" || n == "pcengine" || n == "pc engine" || n == "tg16" || n == "turbografx") return 9;
  if (n == "gba" || n == "gameboyadvance" || n == "game boy advance" || n == "advance") return 10;
  if (n == "pc" || n == "dos" || n == "msdos") return 11;
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
    if (SD.rename("/roms/" + n, dir + "/" + n)) Log.println("menu: moved " + n + " into " + dir);
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
    // A PlayStation disc with more than one track comes as a .cue and a .bin per track, and
    // listing every .bin showed Tekken 2 three times. The cue sheet is the game: one entry,
    // named after it, played as the cue (its audio tracks with it); the track files it names
    // are not listed on their own. A .bin without a cue is listed as before.
    std::vector<String> cueBins;
    if (m == 4) {
      File g = SD.open(dir);
      while (g) {
        File f = g.openNextFile();
        if (!f) break;
        String n = baseName(f);
        String lo = n; lo.toLowerCase();
        if (!f.isDirectory() && n[0] != '.' && lo.endsWith(".cue") && f.size() < 8192) {
          String cue = f.readString();
          String first;
          int at = 0;
          while ((at = cue.indexOf("FILE ", at)) >= 0) {
            int q1 = cue.indexOf('"', at), q2 = q1 >= 0 ? cue.indexOf('"', q1 + 1) : -1;
            if (q1 < 0 || q2 < 0) break;
            String bin = cue.substring(q1 + 1, q2);
            int slash = bin.lastIndexOf('/'); if (slash < 0) slash = bin.lastIndexOf('\\');
            if (slash >= 0) bin = bin.substring(slash + 1);
            cueBins.push_back(bin);
            if (!first.length()) first = bin;
            at = q2 + 1;
          }
          if (first.length()) {
            File t = SD.open(dir + "/" + first);
            if (t) {
              lists[m].push_back({ pooled(dir + "/" + n), pooled(n.substring(0, n.length() - 4)), (int8_t)m, (uint32_t)t.size() });   // (the cue: console.ino discInsert lays its tracks out)
              t.close();
            }
          }
        }
        f.close();
      }
      if (g) g.close();
    }
    {
      File g = SD.open(dir);
      while (g) {
        File f = g.openNextFile();
        if (!f) break;
        String n = baseName(f);
        String lo = n; lo.toLowerCase();
        // (a PlayStation's are its raw 2352-byte .bin images; its BIOS is not a game)
        bool ok = m != 4 || (lo.endsWith(".bin") && !lo.startsWith("scph"));
        // (a PC game is its disk: <name>.img; its .cfg, .pad, .cue and the CD's .bin go with it unlisted)
        if (m == 11) ok = lo.endsWith(".img") || lo.endsWith(".vhd");
        if (ok && m == 4) for (auto &cb : cueBins) if (cb == n) { ok = false; break; }   // (a cue's track)
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
// The card read in a task of its own, a piece ahead of the sending: the two at once, not in turn
// (the card on one SPI host or the SD bus, the FPGA on the other).
struct RdJob { File *f; uint8_t *buf; size_t len; };
static QueueHandle_t rdReq = nullptr, rdDone = nullptr;
static uint8_t *buf2 = nullptr;
static void rdLoop(void *) {
  RdJob j;
  for (;;) {
    xQueueReceive(rdReq, &j, portMAX_DELAY);
    size_t got = j.f->read(j.buf, j.len);
    xQueueSend(rdDone, &got, portMAX_DELAY);
  }
}
static bool readAhead() {
  if (rdReq) return true;
  buf2 = (uint8_t *)heap_caps_malloc(BUF, MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
  if (!buf2) return false;
  rdReq = xQueueCreate(1, sizeof(RdJob)); rdDone = xQueueCreate(1, sizeof(size_t));
  if (xTaskCreatePinnedToCore(rdLoop, "cardread", 4096, nullptr, 2, nullptr, 0) != pdPASS) { rdReq = nullptr; return false; }
  return true;
}
// (a look at every chunk a load streams, before it goes: the Game Boy Advance's save-type scan)
static void (*streamScan)(const uint8_t *, size_t) = nullptr;
static bool stream(File &f, uint32_t addr, uint32_t n, int swap = 0) {
  bool ahead = readAhead();
  uint8_t *cur = buf, *next = buf2;
  uint32_t t0 = millis(), total = n;
  if (ahead) { RdJob j{ &f, cur, n > BUF ? BUF : n }; xQueueSend(rdReq, &j, portMAX_DELAY); }
  while (n) {
    size_t want = n > BUF ? BUF : n;
    size_t got;
    if (ahead) {
      xQueueReceive(rdDone, &got, portMAX_DELAY);
      uint32_t after = n - want;
      if (got == want && after) { RdJob j{ &f, next, after > BUF ? BUF : after }; xQueueSend(rdReq, &j, portMAX_DELAY); }
    } else got = f.read(cur, want);
    uint8_t *buf = cur;
    if (got != want) return false;
    if (streamScan) streamScan(buf, want);
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
      // (in pieces the board's write frame can count: 16 K bytes a frame at most)
      for (size_t k = 0; k < words; k += 2048) {
        size_t m = words - k < 2048 ? words - k : 2048;
        if (quadOk && tries < 2) fpga.busWriteQuad(addr + 4 * k, w32 + k, m); else fpga.busWriteFast(addr + 4 * k, w32 + k, m);
      }
      same = !pchkOk || fpga.busRead(SYS_PCHK) == want_c;
    }
    if (!same) {
      // (a piece read ahead must land before its buffer goes away)
      if (ahead && n - want) { size_t g; xQueueReceive(rdDone, &g, portMAX_DELAY); }
      return false;
    }
    addr += words * 4; n -= want;
    std::swap(cur, next);
  }
  uint32_t ms = millis() - t0;
  if (total >= 65536) Log.printf("load: %u kB in %u ms, %u kB/s%s", (unsigned)(total / 1024), (unsigned)ms, (unsigned)(ms ? total / ms : 0), "\n");
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
    Log.println("menu: a new memory card, " + String(CARD_PATH));
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
  if (f) { f.write(now, eepSize); f.close(); memcpy(eepLast, now, eepSize); Log.println("menu: saved " + eepPath); }
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
  if (f) { f.write(now, srmSize); f.close(); memcpy(srmLast, now, srmSize); Log.println("menu: saved " + srmPath); }
}

// --- the Game Boy Advance's save -----------------------------------------------------------
// 128 kB in DDR3 behind the console (lines 0x204000 up: SRAM games use the first 32 or 64 kB,
// flash games all of it); /saves/gba/<game>.sav holds it between sessions -- the layout every
// emulator writes. In: a fill with GBA_CFG bit 30 set (the words land in the save, not the
// cartridge), a blank save being 0xFF as an erased flash chip reads. Out: when the console says
// the game has written to it (ctrl 0x1DC bit 0, cleared by a write), read back a slice of lines
// per pass of the loop -- the pads keep being served -- and written to the file if changed.
static const uint32_t GBA_DIRTY = NES + 0x1DC, GBA_SAVE_LINE = 0x204000, GBA_SAVE_BYTES = 128 * 1024;
static String gsavPath; static uint8_t *gsavLast = nullptr, *gsavNow = nullptr;
static bool gsavOn = false; static int32_t gsavPos = -1; static uint32_t gsavCheck = 0;
static uint32_t gsavFile = 0;                       // the save file's size when it was loaded (0: none)

// What the cartridge saves to: the save library's ID string in the ROM (GBATEK "GBA Cart Backup
// IDs", word-aligned) -- found by looking at the chunks as the loader streams them, the first one
// winning. The core is told (0x1D0 bit 27 an EEPROM at 0x0D000000, bit 28 a 64 kB flash, whose
// ID the 64 kB library looks for), and the file is written at the size emulators use: 32 kB
// SRAM, 64 / 128 kB flash, 512 B / 8 kB EEPROM (which, the core says in 0x1DC [2:1] once the
// game has used it). No string (homebrew): 128 kB, as before.
enum { GSAV_UNKNOWN, GSAV_SRAM, GSAV_FLASH64, GSAV_FLASH128, GSAV_EEPROM };
static int gsavType = GSAV_UNKNOWN;
static uint8_t gscanTail[12]; static size_t gscanTailN = 0;
static int gbaIdAt(const uint8_t *p, size_t left) {
  if (p[0] != 'E' && p[0] != 'S' && p[0] != 'F') return GSAV_UNKNOWN;
  static const struct { const char *s; int t; } ids[] = {
    { "EEPROM_V", GSAV_EEPROM }, { "SRAM_F_V", GSAV_SRAM }, { "SRAM_V", GSAV_SRAM },
    { "FLASH1M_V", GSAV_FLASH128 }, { "FLASH512_V", GSAV_FLASH64 }, { "FLASH_V", GSAV_FLASH64 } };
  for (auto &id : ids) { size_t n = strlen(id.s); if (left >= n && !memcmp(p, id.s, n)) return id.t; }
  return GSAV_UNKNOWN;
}
static void gbaScan(const uint8_t *b, size_t n) {
  if (gsavType != GSAV_UNKNOWN) return;
  if (gscanTailN) {                                 // (one that starts at the end of the chunk before)
    uint8_t j[24]; size_t m = min(n, (size_t)12);
    memcpy(j, gscanTail, gscanTailN); memcpy(j + gscanTailN, b, m);
    for (size_t i = 0; i < gscanTailN; i += 4) if ((gsavType = gbaIdAt(j + i, gscanTailN + m - i))) return;
  }
  for (size_t i = 0; i + 4 <= n; i += 4) if ((gsavType = gbaIdAt(b + i, n - i))) return;
  gscanTailN = min(n, (size_t)12) & ~(size_t)3;
  memcpy(gscanTail, b + n - gscanTailN, gscanTailN);
}
// the bytes of the save that are the game's (what the file holds)
static uint32_t gbaSaveBytes() {
  switch (gsavType) {
    case GSAV_SRAM: return 32 * 1024;
    case GSAV_FLASH64: return 64 * 1024;
    case GSAV_FLASH128: return 128 * 1024;
    case GSAV_EEPROM: {
      uint32_t sz = (fpga.busRead(GBA_DIRTY) >> 1) & 3;
      if (sz & 2) return 8192;
      if (sz & 1) return 512;
      return gsavFile == 512 ? 512 : 8192;            // (not used yet: as the file was, or the bigger)
    }
    default: return GBA_SAVE_BYTES;
  }
}

static void gbaSaveBegin(const String &rom) {
  String n = rom.substring(rom.lastIndexOf('/') + 1);
  int dot = n.lastIndexOf('.');
  if (dot > 0) n = n.substring(0, dot);
  gsavPath = "/saves/gba/" + n + ".sav";
  if (!gsavLast) gsavLast = bigBuf(GBA_SAVE_BYTES);
  if (!gsavNow) gsavNow = bigBuf(GBA_SAVE_BYTES);
  memset(gsavLast, 0xFF, GBA_SAVE_BYTES);           // (no save yet: erased)
  File f = SD.open(gsavPath);
  gsavFile = 0;
  if (f) { gsavFile = f.size(); f.read(gsavLast, min(gsavFile, GBA_SAVE_BYTES)); f.close(); Log.println("menu: save " + gsavPath); }
  // into the console's save memory, through the fill, in checked chunks as a cartridge goes
  fpga.busWrite(NES_CART_BANK, 0);
  for (uint32_t a = 0; a < GBA_SAVE_BYTES; a += 4096) {
    const uint32_t *w32 = (const uint32_t *)(gsavLast + a);
    uint32_t want_c = 0;
    for (size_t k = 0; k < 1024; k++) want_c = ((want_c << 1) | (want_c >> 31)) ^ (NES_PRG + a + 4 * k) ^ w32[k];
    for (int tries = 0; tries < 4; tries++) {
      if (pchkOk) fpga.busWrite(SYS_PCHK, 0);
      if (tries < 2) gWN(NES_PRG + a, w32, 1024); else fpga.busWrite(NES_PRG + a, w32, 1024);   // (quad; a bit a clock if it keeps failing)
      if (!pchkOk || fpga.busRead(SYS_PCHK) == want_c) break;
    }
  }
  fpga.busWrite(GBA_DIRTY, 1);                      // (the load is not the game's writing)
  gsavOn = true; gsavPos = -1; gsavCheck = millis();
}

static void gbaSaveService(bool now_ = false) {
  if (!gsavOn) return;
  if (gsavPos < 0) {
    if (!now_ && millis() - gsavCheck < 3000) return;
    gsavCheck = millis();
    if (!(fpga.busRead(GBA_DIRTY) & 1)) return;
    fpga.busWrite(GBA_DIRTY, 1);                    // (cleared first: a write while this reads sets it again)
    gsavPos = 0;
  }
  // a slice of lines a pass (all of them when it has to be now)
  uint32_t bytes = gbaSaveBytes();
  uint32_t lines = bytes / 16, slice = now_ ? lines : 256;
  for (uint32_t k = 0; k < slice && (uint32_t)gsavPos < lines; k++, gsavPos++)
    if (!cardLine(GBA_SAVE_LINE + gsavPos, gsavNow + 16 * gsavPos)) { gsavPos = -1; return; }
  if ((uint32_t)gsavPos < lines) return;
  gsavPos = -1;
  if (!memcmp(gsavNow, gsavLast, bytes) && gsavFile == bytes) return;
  SD.mkdir("/saves"); SD.mkdir("/saves/gba");
  File f = SD.open(gsavPath, FILE_WRITE);
  if (f) { f.write(gsavNow, bytes); f.close(); memcpy(gsavLast, gsavNow, bytes); gsavFile = bytes; Log.println("menu: saved " + gsavPath); }
}

// --- the clock -----------------------------------------------------------------------------------
// Pokemon Ruby / Sapphire / Emerald and Boktai carry a clock on the cartridge; the core has one
// (gba_rtc.v) that reads the time the menu writes it every second (ctrl 0x1E0 {year, month, day,
// weekday}, 0x1E4 {hour, minute, second}, BCD). The time itself is the board's DS1302 module --
// its coin cell keeps it while the power is off -- on GPIO 25 CLK, 26 DAT, 27 RST: read at the
// first use and again every minute, millis() in between. Without the module the clock starts at
// 2000-01-01 and runs only while the board does. "time <seconds since 1970, local>" on the serial
// console sets it, the module too (pc/pad.py sends the PC's time when it connects).
static const int DS_CLK = 25, DS_DAT = 26, DS_RST = 27;
static const uint32_t GBA_RTC_DATE = NES + 0x1E0, GBA_RTC_TIME = NES + 0x1E4;
static bool clkInit = false, clkModule = false, gclkOn = false;
static time_t clkBase = 946684800;                  // 2000-01-01 00:00:00
static uint32_t clkMs = 0, clkSync = 0, gclkLast = 0;

static uint8_t bcd(int v) { return (uint8_t)(((v / 10) << 4) | (v % 10)); }
static int unbcd(uint8_t v) { return (v >> 4) * 10 + (v & 15); }
// the DS1302's three wires: bits low first, taken on CLK rising, its own given after CLK falls
static void dsOut(uint8_t v) {
  pinMode(DS_DAT, OUTPUT);
  for (int i = 0; i < 8; i++, v >>= 1) {
    digitalWrite(DS_DAT, v & 1); delayMicroseconds(2);
    digitalWrite(DS_CLK, HIGH); delayMicroseconds(2); digitalWrite(DS_CLK, LOW); delayMicroseconds(2);
  }
}
static uint8_t dsIn() {
  pinMode(DS_DAT, INPUT_PULLDOWN);                   // (no module: every byte 0, which is no date)
  uint8_t v = 0;
  for (int i = 0; i < 8; i++) {
    delayMicroseconds(2); v |= (uint8_t)digitalRead(DS_DAT) << i;
    digitalWrite(DS_CLK, HIGH); delayMicroseconds(2); digitalWrite(DS_CLK, LOW);
  }
  return v;
}
// the clock's burst: seconds, minutes, hours, date, month, weekday, year, write-protect
static void dsRead(uint8_t r[8]) {
  digitalWrite(DS_CLK, LOW); digitalWrite(DS_RST, HIGH); delayMicroseconds(4);
  dsOut(0xBF);
  for (int i = 0; i < 8; i++) r[i] = dsIn();
  digitalWrite(DS_RST, LOW); delayMicroseconds(4);
}
static void dsWrite(const struct tm &t) {
  digitalWrite(DS_CLK, LOW);
  digitalWrite(DS_RST, HIGH); delayMicroseconds(4); dsOut(0x8E); dsOut(0x00); digitalWrite(DS_RST, LOW); delayMicroseconds(4);   // write-protect off
  uint8_t w[8] = { bcd(t.tm_sec), bcd(t.tm_min), bcd(t.tm_hour), bcd(t.tm_mday), bcd(t.tm_mon + 1),
                   (uint8_t)(t.tm_wday + 1), bcd(t.tm_year - 100), 0x80 };   // (seconds bit 7 clear: running; 24-hour; protected again)
  digitalWrite(DS_RST, HIGH); delayMicroseconds(4); dsOut(0xBE);
  for (int i = 0; i < 8; i++) dsOut(w[i]);
  digitalWrite(DS_RST, LOW); delayMicroseconds(4);
}
// the module's time, if there is a module and it holds a date
static bool dsGet(time_t &out) {
  uint8_t r[8]; dsRead(r);
  if (r[0] & 0x80) return false;                     // (halted: never set)
  if ((r[2] & 0x80) || r[3] == 0 || r[3] > 0x31 || r[4] == 0 || r[4] > 0x12 || r[0] > 0x59 || r[1] > 0x59 || r[2] > 0x23) return false;
  struct tm t = {};
  t.tm_sec = unbcd(r[0]); t.tm_min = unbcd(r[1]); t.tm_hour = unbcd(r[2] & 0x3F);
  t.tm_mday = unbcd(r[3]); t.tm_mon = unbcd(r[4]) - 1; t.tm_year = unbcd(r[6]) + 100;
  setenv("TZ", "UTC0", 1); tzset();                 // (the times here are local already: no zone)
  out = mktime(&t);
  return true;
}
static time_t clockNow() {
  if (!clkInit) {
    clkInit = true;
    pinMode(DS_CLK, OUTPUT); pinMode(DS_RST, OUTPUT); digitalWrite(DS_RST, LOW); digitalWrite(DS_CLK, LOW);
    time_t t;
    clkModule = dsGet(t);
    if (clkModule) { clkBase = t; clkMs = millis(); }
    Log.printf("menu: clock %s\n", clkModule ? "from the DS1302" : "-- no DS1302 answering (or never set): from 2000-01-01");
    clkSync = millis();
  }
  if (clkModule && millis() - clkSync > 60000) {      // (the module keeps better time than millis)
    time_t t; clkSync = millis();
    if (dsGet(t)) { clkBase = t; clkMs = millis(); }
  }
  return clkBase + (time_t)((millis() - clkMs) / 1000);
}
static void clockSet(time_t t) {
  clockNow();
  clkBase = t; clkMs = millis(); clkSync = millis();
  struct tm tm; gmtime_r(&t, &tm);
  dsWrite(tm);
  time_t back; clkModule = dsGet(back);
  Log.printf("menu: clock set to %04d-%02d-%02d %02d:%02d:%02d%s\n", tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday,
             tm.tm_hour, tm.tm_min, tm.tm_sec, clkModule ? ", the DS1302 too" : " (no DS1302 answering)");
}
// the core's clock: the time now, if the game has a clock
static void gbaClockService(bool now_ = false) {
  if (!gclkOn || (!now_ && millis() - gclkLast < 1000)) return;
  gclkLast = millis();
  time_t t = clockNow(); struct tm tm; gmtime_r(&t, &tm);
  fpga.busWrite(GBA_RTC_DATE, ((uint32_t)bcd(tm.tm_year - 100) << 24) | ((uint32_t)bcd(tm.tm_mon + 1) << 16) | ((uint32_t)bcd(tm.tm_mday) << 8) | (uint32_t)tm.tm_wday);
  fpga.busWrite(GBA_RTC_TIME, ((uint32_t)bcd(tm.tm_hour) << 16) | ((uint32_t)bcd(tm.tm_min) << 8) | (uint32_t)bcd(tm.tm_sec));
}
// the cartridges with the clock, by the game code's first three letters (header 0xAC)
static bool gbaHasClock(File &f) {
  char code[5] = {0};
  f.seek(0xAC); f.read((uint8_t *)code, 4); f.seek(0);
  static const char *withClock[] = { "AXV", "AXP", "BPE", "U3I", "U32", "U33" };
  for (const char *c : withClock) if (!strncmp(code, c, 3)) return true;
  return false;
}

// --- the Game Boy's battery RAM ------------------------------------------------------------
// The cartridge RAM on the board (gb_top: 32 kB of block RAM) through the SNES's two registers
// -- the selected core answers -- 0x184 the pointer, 0x188 the word; the MBC3's clock at
// pointer 0x8000 ({days[7:0], hours, minutes, seconds}) and 0x8004 (the day-high register:
// carry, halt, day bit 8), a write there setting the clock the game starts with.
// /saves/gb/<game>.sav holds the RAM and, for a cartridge with the clock, the 48 bytes BGB,
// VBA-M and mGBA append: the five registers as 32-bit words, the latched five, and when it was
// saved (64-bit seconds since 1970; an older 44-byte trailer has 32). Coming back in, the clock
// is moved on by the time the game was off (the menu's clock, clockNow), so it keeps the
// wall's time across sessions. Written back as the SNES's: when the game has written to it and
// it has changed -- and, for a clock, always on the way out, so the time it was left at is fresh.
static const uint32_t GB_RAM_MAX = 32768, GB_RTC_BYTES = 48, GB_RTC_PTR = 0x8000;
static String gbsPath; static uint32_t gbsSize = 0; static bool gbsClock = false, gbsOn = false;
static uint8_t *gbsLast = nullptr; static uint32_t gbsCheck = 0; static int32_t gbsPos = -1;

// the header's cartridge type ($0147): a battery behind its RAM (MBC1, ROM + RAM, MBC3, MBC5 --
// the mappers gb_top has), and the clock (MBC3 + timer)
static bool gbBattery(uint8_t t) { return t == 0x03 || t == 0x09 || t == 0x0F || t == 0x10 || t == 0x13 || t == 0x1B || t == 0x1E; }
static bool gbHasClock(uint8_t t) { return t == 0x0F || t == 0x10; }
// the header's RAM size ($0149): 2, 8, 32 kB (the 64 and 128 kB ones keep their first 32: the core's)
static uint32_t gbRamBytes(uint8_t r) { return r == 1 ? 2048 : r == 2 ? 8192 : (r >= 3 && r <= 5) ? GB_RAM_MAX : 0; }

static uint32_t gbLe32(const uint8_t *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }
static void gbPut32(uint8_t *p, uint32_t v) { p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24; }
// the clock's registers {s, m, h, days low, day high} moved on by `secs` (a halted clock stays;
// past day 511 the carry is set and the days go round, as the chip's)
static void gbClockAdvance(uint8_t r[5], uint64_t secs) {
  if ((r[4] & 0x40) || !secs) return;
  uint64_t days = ((r[4] & 1) << 8) | r[3];
  uint64_t t = (r[0] & 63) + 60ull * (r[1] & 63) + 3600ull * (r[2] & 31) + secs;
  r[0] = t % 60; t /= 60; r[1] = t % 60; t /= 60; r[2] = t % 24; days += t / 24;
  if (days > 511) r[4] |= 0x80;
  days &= 511;
  r[3] = days & 0xFF; r[4] = (r[4] & 0xFE) | (uint8_t)(days >> 8);
}

static void gbsBegin(const String &rom, uint8_t type, uint8_t ramSz) {
  gbsOn = false;
  gbsClock = gbHasClock(type);
  gbsSize = gbBattery(type) ? gbRamBytes(ramSz) : 0;
  if (!gbsSize && !gbsClock) return;
  String n = rom.substring(rom.lastIndexOf('/') + 1);
  int dot = n.lastIndexOf('.');
  if (dot > 0) n = n.substring(0, dot);
  gbsPath = "/saves/gb/" + n + ".sav";
  if (!gbsLast) gbsLast = bigBuf(GB_RAM_MAX + GB_RTC_BYTES);
  memset(gbsLast, 0, GB_RAM_MAX + GB_RTC_BYTES);   // (no save yet: cleared, not the last game's)
  uint8_t r[5] = { 0, 0, 0, 0, 0 };
  File f = SD.open(gbsPath);
  if (f) {
    uint32_t fs = f.size();
    f.read(gbsLast, min(fs, gbsSize));
    if (gbsClock && fs >= gbsSize + 44) {          // the clock's trailer
      uint8_t t[GB_RTC_BYTES];
      memset(t, 0, sizeof(t));
      f.seek(gbsSize); f.read(t, min(fs - gbsSize, GB_RTC_BYTES));
      for (int k = 0; k < 5; k++) r[k] = t[4 * k];
      uint64_t then = gbLe32(t + 40) | (fs >= gbsSize + 48 ? (uint64_t)gbLe32(t + 44) << 32 : 0);
      uint64_t now = (uint64_t)clockNow();
      if (then && now > then) gbClockAdvance(r, now - then);   // (a clock behind the save's: no time passed)
    }
    f.close();
    Log.println("menu: save " + gbsPath);
  }
  if (gbsClock) {
    fpga.busWrite(SNES_HPTR, GB_RTC_PTR);
    fpga.busWrite(SNES_HWORD, r[0] | r[1] << 8 | r[2] << 16 | (uint32_t)r[3] << 24);
    fpga.busWrite(SNES_HWORD, r[4]);
  }
  fpga.busWrite(SNES_HPTR, 1u << 31);              // (pointer 0, the written flag down)
  for (uint32_t a = 0; a < gbsSize; a += 4) fpga.busWrite(SNES_HWORD, gbLe32(gbsLast + a));
  gbsOn = true; gbsCheck = millis(); gbsPos = -1;
}

static void gbsService(bool now_ = false) {
  if (!gbsOn || !gbsPath.length()) return;
  bool leaving = now_ && gbsClock;                  // (a clock: saved on the way out whatever)
  static uint8_t *now = bigBuf(GB_RAM_MAX + GB_RTC_BYTES);
  if (gbsPos < 0) {
    if (!now_ && millis() - gbsCheck < 5000) return;
    gbsCheck = millis();
    bool written = fpga.busRead(SNES_HPTR) & 1;
    if (!written && !leaving) return;               // not written since the last look
    if (written) fpga.busWrite(SNES_HPTR, 1u << 31);  // (cleared first: a write while this reads sets it again)
    gbsPos = 0;
  }
  // a slice a pass, the pads served in between (all of it when it has to be now)
  uint32_t slice = now_ ? GB_RAM_MAX : 4096;
  for (uint32_t k = 0; k < slice && (uint32_t)gbsPos < gbsSize; k += 4, gbsPos += 4) {
    fpga.busWrite(SNES_HPTR, gbsPos);
    gbPut32(now + gbsPos, fpga.busRead(SNES_HWORD));
  }
  if ((uint32_t)gbsPos < gbsSize) return;
  gbsPos = -1;
  uint32_t n = gbsSize;
  if (gbsClock) {
    fpga.busWrite(SNES_HPTR, GB_RTC_PTR);     uint32_t lo = fpga.busRead(SNES_HWORD);
    fpga.busWrite(SNES_HPTR, GB_RTC_PTR + 4); uint32_t hi = fpga.busRead(SNES_HWORD);
    uint8_t *t = now + gbsSize;
    memset(t, 0, GB_RTC_BYTES);
    uint8_t r[5] = { (uint8_t)lo, (uint8_t)(lo >> 8), (uint8_t)(lo >> 16), (uint8_t)(lo >> 24), (uint8_t)hi };
    for (int k = 0; k < 5; k++) { t[4 * k] = r[k]; t[20 + 4 * k] = r[k]; }   // (the latched five: the same)
    uint64_t when = (uint64_t)clockNow();
    gbPut32(t + 40, (uint32_t)when); gbPut32(t + 44, (uint32_t)(when >> 32));
    n += GB_RTC_BYTES;
  }
  if (!leaving && !memcmp(now, gbsLast, gbsSize)) return;
  SD.mkdir("/saves"); SD.mkdir("/saves/gb");
  File f = SD.open(gbsPath, FILE_WRITE);
  if (f) { f.write(now, n); f.close(); memcpy(gbsLast, now, n); Log.println("menu: saved " + gbsPath); }
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

// The Atari's bank scheme (a26_top's numbers): a tag in the name says -- "(F8SC)", "[E0]" -- as
// the dumps' names often do; otherwise the size, with the Super Chip told the way Stella tells it
// (every 4 kB bank's first 128 bytes repeated in its second 128: the chip's RAM, read through
// those addresses, was dumped as whatever the dumper saw there twice). 0 leaves it to the core.
static uint32_t a26Scheme(const String &name, File &f, uint32_t size) {
  String u = name; u.toUpperCase();
  static const char *const TAG[] = { "F8SC", "F6SC", "F4SC", "F8", "F6", "F4", "FE", "E0", "3F", "FA" };
  static const uint8_t NUM[] = { 9, 10, 11, 2, 3, 4, 5, 6, 7, 8 };
  for (int i = 0; i < 10; i++)
    if (u.indexOf(String("(") + TAG[i] + ")") >= 0 || u.indexOf(String("[") + TAG[i] + "]") >= 0) return NUM[i];
  if (size == 8192 || size == 16384 || size == 32768) {
    bool sc = true;
    uint8_t a[128], b[128];
    for (uint32_t bank = 0; bank < size && sc; bank += 4096) {
      f.seek(bank);
      if (f.read(a, 128) != 128 || f.read(b, 128) != 128 || memcmp(a, b, 128)) sc = false;
    }
    f.seek(0);
    if (sc) return size == 8192 ? 9 : size == 16384 ? 10 : 11;
  }
  return 0;
}

static String load(const Game &g) {
  if (g.m != 4) cardIn = false;
  if (g.m == 11) {                                   // the PC: a hard-disk image, served from the card (pc.h)
    message("starting the PC", g.name);
    return pc::start(g.path, stream, NES_PRG, NES_CART_BANK);
  }
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
        else { memset(buf, 0, 8192); gWN(NES_CHR, (uint32_t *)buf, 2048); }
        uint32_t prgAll = h[4] == 1 ? 2 * prg : prg;
        uint32_t prgLast = prgAll / 8192 ? prgAll / 8192 - 1 : 0;
        fpga.busWrite(NES_MAPPER, (mapper & 0xF) | (prgLast << 8) | (chr ? 0 : 0x4000));
        fpga.busWrite(NES_CONSOLE, 0);
        fpga.busWrite(VID_CTRL, 3); fpga.busWrite(SYN_CTRL, 3);
        if (!err.length()) fpga.busWrite(NES_CTRL, 1 | (mirrorV ? 2 : 0));
      }
    }
  } else if (g.m == 1 || g.m == 6) {                 // Master System, Game Gear: the ROM, nothing else
    if (!stream(f, NES_PRG, size)) err = "the file ended early";
    fpga.busWrite(NES_CONSOLE, g.m == 6 ? 6 : 1);
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
    if (!cardInsert()) Log.println("menu: no memory card (" + String(CARD_PATH) + ")");
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
  } else if (g.m == 7) {                             // Game Boy: into DDR3, bank by bank, as the SNES
    uint8_t hb[3] = { 0, 0, 0 };                     // the header's cartridge type, ROM size, RAM size
    f.seek(0x147); f.read(hb, 3); f.seek(0);
    fpga.busWrite(NES_CONSOLE, 7);                   // first: the fill only reaches the selected core
    if (!streamBanks(f, size)) err = "the file ended early";
    gbsBegin(g.path, hb[0], hb[2]);                  // the battery RAM (and the clock) in
    fpga.busWrite(VID_CTRL, 3); fpga.busWrite(SYN_CTRL, 3);
    if (!err.length()) fpga.busWrite(NES_CTRL, 1);   // (the core reads the header itself)
  } else if (g.m == 10) {                            // Game Boy Advance: the cartridge into DDR3; a BIOS file if the card has one
    fpga.busWrite(NES_CONSOLE, 10);                  // first: the fill only reaches the selected core
    fpga.busWrite(GBA_CFG, 0x40000000u | size);      // the save's fill
    gbaSaveBegin(g.path);
    String bios = SD.exists("/bios/gba_bios.bin") ? "/bios/gba_bios.bin" : SD.exists("/roms/gba/gba_bios.bin") ? "/roms/gba/gba_bios.bin" : "";
    if (bios.length()) {
      File b = SD.open(bios);
      if (b && b.size() == 16384) {
        fpga.busWrite(GBA_CFG, 0x80000000u | size);
        fpga.busWrite(NES_CART_BANK, 0);
        if (!stream(b, NES_PRG, 16384)) err = "the BIOS file ended early";
      }
      if (b) b.close();
    }
    gclkOn = gbaHasClock(f);
    fpga.busWrite(GBA_CFG, size | (gclkOn ? 0x20000000u : 0));   // (bit 29: the cartridge's clock)
    if (gclkOn) { gbaClockService(true); Log.println("menu: the cartridge has a clock"); }
    gsavType = GSAV_UNKNOWN; gscanTailN = 0; streamScan = gbaScan;   // (the save type, from the chunks as they go)
    if (!streamBanks(f, size)) err = "the file ended early";
    streamScan = nullptr;
    // (bit 27: the save is an EEPROM; bit 28: a 64 kB flash)
    fpga.busWrite(GBA_CFG, size | (gclkOn ? 0x20000000u : 0) | (gsavType == GSAV_EEPROM ? 0x08000000u : 0) | (gsavType == GSAV_FLASH64 ? 0x10000000u : 0));
    static const char *const GSN[] = { "unknown (128 kB)", "SRAM", "flash 64 kB", "flash 128 kB", "EEPROM" };
    Log.println(String("menu: the save is ") + GSN[gsavType]);
    fpga.busWrite(VID_CTRL, 3); fpga.busWrite(SYN_CTRL, 3);
    if (!err.length()) fpga.busWrite(NES_CTRL, 1);
  } else if (g.m == 9) {                             // PC Engine: into DDR3 as the Game Boy, less a copier header
    uint32_t base = (size % 8192 == 512) ? 512 : 0;
    uint32_t rom = size - base;
    fpga.busWrite(NES_CONSOLE, 9);                   // first: the fill only reaches the selected core
    fpga.busWrite(PCE_CFG, rom > 0xFFFFF ? 0xFFFFF : rom);   // (the register is 20 bits: a 1 MB card as 0xFFFFF, which still masks to 1 MB)
    f.seek(base);
    if (!streamBanks(f, rom)) err = "the file ended early";
    fpga.busWrite(VID_CTRL, 3); fpga.busWrite(SYN_CTRL, 3);
    if (!err.length()) fpga.busWrite(NES_CTRL, 1);
  } else if (g.m == 8) {                             // Atari 2600: the image, its size and scheme
    if (size < 2048) err = "too small for an Atari cartridge";
    uint32_t scheme = a26Scheme(g.name, f, size);
    fpga.busWrite(NES_CONSOLE, 8);                   // first: the fill only reaches the selected core
    fpga.busWrite(NES_CART_BANK, 0);
    if (!err.length() && !stream(f, NES_PRG, size)) err = "the file ended early";
    // colour, both difficulty switches at B
    fpga.busWrite(A26_CFG, (size & 0xFFFF) | scheme << 16);
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

// --- the two core slots (the menu image from version 7) -------------------------------------------
// The flash past the menu image holds two cores, 3 MB each: slot 0 at 2 MB, slot 1 at 5 MB (one
// over 3 MB takes slot 0 and the space of both). Switching to a console in either is a reboot (two
// seconds); else the slot used less recently is written. And while the menu is open on a console
// in neither slot -- its tile, or its games -- that slot is erased in the background, a sector at a
// time: erasing is the flash chip's own 0.66 s a 64 kB sector, most of an install's time.
static const uint32_t SLOT1_OFF = 0x300000, SLOT_HALF = 0x300000, SLOT_SECTORS = SLOT_HALF / SECTOR;
struct SlotRec { String core; uint32_t size = 0, erased = 0; };
static SlotRec slotGet(int i) {
  SlotRec r; char k[12];
  prefs.begin("menu", true);
  snprintf(k, sizeof k, "s%dcore", i); r.core = prefs.getString(k, "");
  snprintf(k, sizeof k, "s%dsize", i); r.size = prefs.getUInt(k, 0);
  snprintf(k, sizeof k, "s%derased", i); r.erased = prefs.getUInt(k, 0);
  // (before version 7 there was one slot, "slot" / "size": it is slot 0)
  if (i == 0 && !r.core.length() && !prefs.isKey("s0core")) { r.core = prefs.getString("slot", ""); r.size = prefs.getUInt("size", 0); }
  prefs.end();
  return r;
}
static void slotPut(int i, const SlotRec &r) {
  char k[12];
  prefs.begin("menu", false);
  snprintf(k, sizeof k, "s%dcore", i); prefs.putString(k, r.core);
  snprintf(k, sizeof k, "s%dsize", i); prefs.putUInt(k, r.size);
  snprintf(k, sizeof k, "s%derased", i); prefs.putUInt(k, r.erased);
  if (i == 0) { prefs.putString("slot", r.core); prefs.putUInt("size", r.size); }   // (the old keys follow slot 0)
  prefs.end();
}
static int slotLast() { prefs.begin("menu", true); int l = prefs.getUChar("slotlast", 0); prefs.end(); return l; }
static void slotSetLast(int i) { prefs.begin("menu", false); prefs.putUChar("slotlast", i); prefs.end(); }
// which slot holds this image (-1: neither)
static int slotOf(const char *core, uint32_t size) {
  for (int i = 0; i < 2; i++) { SlotRec r = slotGet(i); if (r.core == core && r.size == size) return i; }
  return -1;
}
static bool twoSlots() { Status st = fpga.status(); return st.alive && st.core == 0 && st.version >= 7; }

// the background erase: one sector in flight at most
static int bgSlot = -1; static bool bgBusy = false; static uint32_t bgT = 0;
static void bgEraseStep(int victim) {
  if (bgBusy) {
    if (fpga.busy()) return;
    bgBusy = false;
    SlotRec r = slotGet(bgSlot); r.erased++; slotPut(bgSlot, r);
    return;
  }
  if (victim < 0) return;
  SlotRec r = slotGet(victim);
  if (r.core.length()) { r.core = ""; r.size = 0; r.erased = 0; slotPut(victim, r); }   // (no longer a core: it is being cleared)
  if (r.erased >= SLOT_SECTORS) return;
  bgSlot = victim; bgBusy = true; bgT = millis();
  fpga.eraseStart((victim ? SLOT1_OFF : 0) + r.erased * SECTOR);
}
// an install is about to use the flash: the erase in flight finished first, and counted
static void bgEraseFinish() {
  if (!bgBusy) return;
  uint32_t t0 = millis();
  while (fpga.busy() && millis() - t0 < 5000) delay(5);
  bgEraseStep(-1);
}

// --- switching the board to another console ---------------------------------------
static String switchTo(int m) {
  pc::stop();                               // (the PC's disk task off before the board stops being the PC)
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
  // Install (unless a slot holds this core already) and boot; and if it does not come up, once
  // more with the install forced: a slot is not always what was last put there (one was found
  // blank), and a dark screen is no answer.
  bool two = twoSlots();
  uint32_t size = f.size();
  for (int round = 0; round < 2; round++) {
    int use = two ? slotOf(M.core, size) : (slotGet(0).core == M.core && slotGet(0).size == size ? 0 : -1);
    if (round == 1 || use < 0) {
      if (round == 1) message(String("the ") + M.name + " did not start", "installing it again");
      bgEraseFinish();
      // the slot: this one again (round 1), else the one used less recently; a core over 3 MB
      // only in slot 0
      int v = !two || size > SLOT_HALF ? 0 : use >= 0 ? use : 1 - slotLast();
      SlotRec r = slotGet(v);
      uint32_t pre = (round == 0 && !r.core.length()) ? r.erased : 0;
      slotPut(v, SlotRec());                                     // (not a core while it is written)
      if (size > SLOT_HALF) slotPut(1, SlotRec());              // (slot 1's space too)
      bool ok = false;
      installShow = gInstallShow;
      for (int tries = 0; tries < 2 && !ok; tries++) {
        job.busy = true; job.error = "";
        f.seek(0);
        ok = installCard(f, v ? SLOT1_OFF : 0, tries ? 0 : pre);
        job.busy = false;
      }
      installShow = nullptr;
      if (!ok) { f.close(); return "install failed: " + job.error; }
      SlotRec n; n.core = M.core; n.size = size; slotPut(v, n);
      use = v;
    }
    // (boot asked twice if the first did not take: once, it did not)
    if (two) slotSetLast(use);
    for (int tries = 0; tries < 2; tries++) {
      if (two) fpga.bootSlot(use + 1); else fpga.boot(true);
      t0 = millis();
      while (millis() - t0 < 5000) {
        delay(100);
        Status s = fpga.status();
        if (s.alive && s.core == M.id) { f.close(); return ""; }
      }
    }
    // not up: back in the shell (the fallback takes it there; else PROGRAM_B) for the next round
    Log.printf("menu: the %s did not come up (round %d)%s", M.name, round + 1, "\n");
    t0 = millis();
    while (millis() - t0 < 3000 && fpga.status().core != 0) delay(100);
    if (fpga.status().core != 0) { fpga.forceShell(); delay(3000); }
    if (use >= 0) slotPut(use, SlotRec());
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
  if (gameIn) c.running = shown(gameName).c_str();
  // (the clock and the date as the graphical menu's top: gtop)
  gscr::Top t = gtop("");
  if (clockNow() > 1600000000) { c.time = t.time; c.date = t.date; }
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
// The game to carry on with (the last one started), if it is still on the card
struct Last { int m = -1, i = -1; };
static Last lastGame() {
  static Last memo; static uint32_t memoT = 0;          // (a page is painted once a strip: asked 60 times)
  if (memoT && millis() - memoT < 300) return memo;
  Last l;
  memoT = millis();
  prefs.begin("menu", true); String last = prefs.getString("last", ""); prefs.end();
  if (!last.length()) return l;
  for (int m = 0; m < NMACH; m++)
    for (int i = 0; i < (int)lists[m].size(); i++)
      if (last.equals(lists[m][i].path)) { l.m = m; l.i = i; memo = l; return l; }
  memo = l;
  return l;
}
// What home's items do: the graphical home (the menu image) -- the game to carry on with,
// then the consoles; inside a console, the game's own menu; the old text home (a menu image
// without a picture) -- back to the game, the consoles, the settings.
enum HomeAct { H_CONTINUE, H_CONSOLE, H_RESUME, H_RESET, H_SETTINGS, H_HOME };
struct HomeItem { HomeAct act; int m; };
static std::vector<HomeItem> homeItems() {
  std::vector<HomeItem> v;
  if (gmode) {
    if (lastGame().m >= 0) v.push_back({ H_CONTINUE, -1 });
    for (int m : consoles) v.push_back({ H_CONSOLE, m });
  } else if (inCore) {
    if (gameIn) { v.push_back({ H_RESUME, -1 }); v.push_back({ H_RESET, -1 }); }
    v.push_back({ H_SETTINGS, -1 });
    v.push_back({ H_HOME, -1 });
  } else {
    for (int m : consoles) v.push_back({ H_CONSOLE, m });
    v.push_back({ H_SETTINGS, -1 });
  }
  return v;
}
static std::vector<Item> items() {
  std::vector<Item> v;
  switch (nav.page) {
  case P_HOME:
    if (gmode || inCore) {
      for (auto &h : homeItems()) {
        switch (h.act) {
        case H_CONTINUE: { Last l = lastGame(); v.push_back(item(("Continue " + std::string(shown(lists[l.m][l.i].name).c_str())).c_str())); break; }
        case H_CONSOLE: { size_t n = lists[h.m].size(); v.push_back(item(MACHINES[h.m].name, art::G_PAD, ui::PINK, std::to_string(n) + (n == 1 ? " game" : " games"))); break; }
        case H_RESUME: v.push_back(item(("Back to " + gameName).c_str(), art::G_RIGHT, ui::GREEN)); break;
        case H_RESET: v.push_back(item("Reset the game", art::G_CIRCLE, ui::RED)); break;
        case H_SETTINGS: v.push_back(item("Settings", art::G_GEAR, ui::YELLOW, "", ui::GREY, true)); break;
        case H_HOME: v.push_back(item("Home", art::G_HEART, ui::PINK, gameIn ? "saves, quits the game" : "", ui::GREY)); break;
        }
      }
      break;
    }
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
  case P_HOME: return inCore ? "PAUSED" : "CONSOLES";
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
// --- the graphical pages ---------------------------------------------------------------------
// when the game to carry on with was last started: "today 18:42", "yesterday", "17 Oct"
static std::string whenText() {
  static uint32_t memo = 0, memoT = 0;
  if (!memoT || millis() - memoT > 300) { prefs.begin("menu", true); memo = prefs.getUInt("lastT", 0); prefs.end(); memoT = millis(); }
  uint32_t t = memo;
  if (!t) return "";
  time_t now = clockNow(), then = (time_t)t; struct tm a, b; gmtime_r(&now, &a); gmtime_r(&then, &b);
  static const char *MO[12] = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
  char s[24];
  long days = (long)(now / 86400) - (long)(then / 86400);
  if (days == 0) snprintf(s, sizeof(s), "today %02d:%02d", b.tm_hour, b.tm_min);
  else if (days == 1) snprintf(s, sizeof(s), "yesterday");
  else snprintf(s, sizeof(s), "%d %s", b.tm_mday, MO[b.tm_mon]);
  return s;
}
// a save on the card for the game (the consoles whose saves are named after it)
static bool hasSave(const Game &g) {
  String n = g.path; n = n.substring(n.lastIndexOf('/') + 1);
  int dot = n.lastIndexOf('.'); if (dot > 0) n = n.substring(0, dot);
  if (g.m == 10) return SD.exists("/saves/gba/" + n + ".sav");
  if (g.m == 5) return SD.exists("/saves/snes/" + n + ".srm");
  if (g.m == 7) return SD.exists("/saves/gb/" + n + ".sav");
  return false;
}
static void draw();                       // (below)
static int homeFirstRow = 0;
// home's grid: the top row shown, kept so the selected tile is in one of the two rows
static void homeFix(int hc) {
  int t = nav.sel - hc;
  if (t >= 0) { int row = t / 5; if (row < homeFirstRow) homeFirstRow = row; if (row > homeFirstRow + 1) homeFirstRow = row - 1; }
  else homeFirstRow = 0;
}
// where a selection is drawn (with its glow), for redrawing only that
struct GRect { int x, y, w, h; };
static const GRect G_HINTS = { 0, 436, 640, 44 }, G_CLOCK = { 400, 0, 240, 72 };
static GRect homeSelRect(int sel, int hc) {
  if (hc && sel == 0) return { 12, 66, 616, 88 };
  int t = sel - hc, gy = hc ? 156 : 82;
  return { 24 + (t % 5) * 117 - 12, gy + (t / 5 - homeFirstRow) * 140 - 12, 132, 152 };
}
static GRect listRowRect(int i) { return { 12, gscr::LIST_Y + (i - nav.top) * gscr::LIST_ROW - 8, 616, 64 }; }
// the list's page: how many rows show (the info lines take one)
static int gListRows() {
  bool info_ = nav.page == P_GAMES ? lists[cur].empty() : !info().empty();
  return gscr::LIST_ROWS - (info_ ? 1 : 0);
}
// the games' saves, looked for once a list (the card is slow to ask)
static std::vector<int8_t> saveSeen; static int saveSeenFor = -1;
static void keepVisible(int rows) {
  if (nav.sel < nav.top) nav.top = nav.sel;
  if (nav.sel >= nav.top + rows) nav.top = nav.sel - rows + 1;
  if (nav.top < 0) nav.top = 0;
}
// a page of plain lines (pairing, the pad test, waiting for a button, about)
static void glines(const std::string &title, const std::vector<std::string> &lines, const std::vector<gscr::Hint> &h) {
  gfx::background(HOME_ACCENT);
  gscr::top(gtop(title, "Home  >  Settings"));
  gfx::rrect(40, 86, 560, 344, 18, gscr::WHITE, 14);
  int y = 110;
  for (auto &l : lines) { gfx::text(gfxfont::F18, 64, y, l.c_str(), gscr::ROW); y += 32; }
  gscr::hints(h, note.c_str());
}
static std::string padLine(const pads::Player &p) {
  if (!p.on) return "not connected";
  const pads::In &i = p.in;
  std::string s;
  struct { bool on; const char *n; } b[] = { { i.a, "cross" }, { i.b, "circle" }, { i.x, "square" }, { i.y, "triangle" },
    { i.l1, "L1" }, { i.r1, "R1" }, { i.l2, "L2" }, { i.r2, "R2" }, { i.sel, "select" }, { i.start, "start" }, { i.home, "home" },
    { i.du, "up" }, { i.dd, "down" }, { i.dl, "left" }, { i.dr, "right" } };
  for (auto &x : b) if (x.on) { if (!s.empty()) s += " "; s += x.n; }
  char st[48]; snprintf(st, sizeof(st), "  sticks %d,%d %d,%d", i.lx, i.ly, i.rx, i.ry);
  return (s.empty() ? std::string("-") : s) + st;
}
static void gpaint() {
  using namespace gscr;
  switch (nav.page) {
  case P_HOME: {
    HomeView v; v.top = gtop("FPGA CONSOLE"); v.top.gear = true;
    std::vector<HomeItem> h = homeItems();
    int hc = (!h.empty() && h[0].act == H_CONTINUE) ? 1 : 0;
    if (hc) {
      Last l = lastGame();
      v.cont.on = true; v.cont.m = l.m; v.cont.key = MACHINES[l.m].core; v.cont.console = MACHINES[l.m].name;
      v.cont.game = shown(lists[l.m][l.i].name).c_str(); v.cont.when = whenText();
    }
    for (auto &x : h) if (x.act == H_CONSOLE) v.tiles.push_back({ x.m, MACHINES[x.m].name, MACHINES[x.m].core, MCOL[x.m], (int)lists[x.m].size() });
    int t = nav.sel - hc;
    v.sel = (hc && nav.sel == 0) ? -1 : t;
    homeFix(hc);
    v.firstRow = homeFirstRow;
    if (v.tiles.empty()) { v.lines.push_back(haveCard ? "No games on the card yet" : "No SD card"); v.lines.push_back("Games go in /roms/<console> on the card"); }
    pads::Player p[2]; pads::view(p);
    v.note = (!p[0].on && !p[1].on) ? "No controller: PS4 / PS5 hold SHARE + PS" : note.c_str();
    v.hints = { { S_CROSS, hc && nav.sel == 0 ? "Play" : "Open" }, { S_TRIANGLE, "Settings" } };
    homeScreen(v, HOME_ACCENT);
    break; }
  case P_GAMES: {
    ListView v; v.badges = true; v.accent = MCOL[cur];
    v.top = gtop(MACHINES[cur].name, std::string("Home  >  ") + MACHINES[cur].name);
    for (auto &g : lists[cur]) { Row r; r.text = shown(g.name).c_str(); v.rows.push_back(r); }
    if (v.rows.empty()) v.info.push_back("No games for this console on the card");
    keepVisible(listRows(v));
    v.first = nav.top; v.sel = nav.sel;
    if (saveSeenFor != cur || saveSeen.size() != lists[cur].size()) { saveSeen.assign(lists[cur].size(), -1); saveSeenFor = cur; }
    for (int i = v.first; i < v.first + listRows(v) && i < (int)v.rows.size(); i++) {
      if (saveSeen[i] < 0) saveSeen[i] = hasSave(lists[cur][i]) ? 1 : 0;
      if (saveSeen[i]) v.rows[i].tag = "SAVE";
    }
    Last l = lastGame();
    if (l.m == cur && l.i >= 0 && l.i < (int)v.rows.size()) v.rows[l.i].sub = "last played " + whenText();
    v.hints = { { S_CROSS, "Play" }, { S_CIRCLE, "Back" }, { S_L1R1, "Page" } };
    v.note = note.c_str();
    listPage(v);
    break; }
  case P_PAIR: {
    pads::Player p[2]; pads::view(p);
    int left = 120 - (int)((millis() - pageT0) / 1000);
    std::vector<std::string> l = { "Pairing: " + std::to_string(left < 0 ? 0 : left) + " seconds left", "",
      "PS4 / PS5:  hold SHARE and PS", "Xbox:  hold the pair button", "Switch Pro:  hold sync", "" };
    for (auto &q : p) if (q.on) l.push_back(std::string("connected: ") + q.name);
    glines("Pair a controller", l, { { S_CIRCLE, "Back" } });
    break; }
  case P_TEST:
    glines("Test the controllers", { "Player 1", padLine(testP[0]), "", "Player 2", padLine(testP[1]), "", "hold circle to leave" }, {});
    break;
  case P_WAITBTN: {
    int left = 6 - (int)((millis() - pageT0) / 1000);
    glines("Button mapping", { std::string(pads::LAYOUTS[mapL].name) + ": " + pads::LAYOUTS[mapL].b[mapB].name,
      "", "Press the pad's button for it now", std::to_string(left < 0 ? 0 : left) + " seconds" }, {});
    break; }
  case P_ABOUT:
    glines("About", { "BYBA GAMES", "the FPGA game console", "", "Text: Nunito (SIL Open Font License)",
      "Console art: RetroPie's carbon theme (from the card)" }, { { S_CIRCLE, "Back" } });
    break;
  default: {
    ListView v; v.accent = { 60, 120, 140 };
    std::string t = title(), tc;
    for (size_t i = 0; i < t.size(); i++) tc += (char)(i ? tolower((unsigned char)t[i]) : t[i]);
    v.top = gtop(tc, nav.page == P_SETTINGS ? "Home  >  Settings" : "Home  >  Settings  >  " + tc);
    for (auto &it : items()) { Row r; r.text = it.text; r.value = it.value; v.rows.push_back(r); }
    for (auto &l : info()) v.info.push_back(l);
    keepVisible(listRows(v));
    v.first = nav.top; v.sel = nav.sel;
    bool change = nav.page == P_PICTURE || nav.page == P_SYSTEM;
    v.hints = { { S_CROSS, change ? "Change" : "Open" }, { S_CIRCLE, "Back" } };
    if (nav.page == P_MAP) v.hints.insert(v.hints.begin() + 1, Hint{ S_SQUARE, "Second" });
    v.note = note.c_str();
    listPage(v);
  }
  }
}
// the selection: the board's highlight over it (off on the pages without one)
static void ghl() {
  if (!gmode) return;
  if (nav.page == P_HOME) {
    std::vector<HomeItem> h = homeItems();
    int hc = (!h.empty() && h[0].act == H_CONTINUE) ? 1 : 0;
    if (nav.sel >= (int)h.size()) { gfx::highlightOff(gW1); return; }
    if (hc && nav.sel == 0) { gfx::highlight(gW1, 24, 78, 592, 64, 16, { 120, 140, 255 }, gfx::HL_TILE); return; }
    int t = nav.sel - hc, gy = hc ? 156 : 82;
    gfx::highlight(gW1, 24 + (t % 5) * 117, gy + (t / 5 - homeFirstRow) * 140, 108, 128, 14, MCOL[h[nav.sel].m], gfx::HL_TILE);
    return;
  }
  bool list = nav.page == P_GAMES || nav.page == P_SETTINGS || nav.page == P_PICTURE || nav.page == P_PADS ||
              nav.page == P_MAPS || nav.page == P_MAP || nav.page == P_SYSTEM;
  int n = nav.page == P_GAMES ? (int)lists[cur].size() : (int)items().size();
  if (!list || n == 0) { gfx::highlightOff(gW1); return; }
  gfx::RGB acc = nav.page == P_GAMES ? MCOL[cur] : gfx::RGB{ 60, 120, 140 };
  gfx::highlight(gW1, 24, gscr::LIST_Y + (nav.sel - nav.top) * gscr::LIST_ROW, 592, 48, 12, acc, gfx::HL_BAR);
}
static void gdraw() { grender(0, 0, gfx::W, gfx::H, [] { gpaint(); }); ghl(); }
static void gparts(const std::vector<GRect> &rs) {
  for (auto &r : rs) grender(r.x, r.y, r.w, r.h, [] { gpaint(); });
  ghl();
}
// a list's selection moved: the two rows (and the hints) again, or the page if it scrolled
static void listMoved(int oldSel, int oldTop) {
  if (!gmode || !open_) { draw(); return; }
  keepVisible(gListRows());
  if (nav.top != oldTop) draw();
  else ghl();                                     // (the board moves the highlight: nothing to draw)
}

static void draw() {
  // (a closed menu draws nothing: a page drawn after a game started would put the menu
  // back over it, closed -- deaf to everything but START + SELECT)
  if (!open_) return;
  if (gmode) { gdraw(); return; }
  scr::Chrome ch = chrome();
  switch (nav.page) {
  case P_GAMES: {
    size_t n = lists[cur].size();
    ch.crumbs = "Home  >  " + std::to_string(n) + (n == 1 ? " game" : " games");
    scr::list(ch, MACHINES[cur].name, items(), nav.sel, nav.top, {}, note.c_str(), hintsFor(), 1);
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
    // (where the page is, as the graphical menu's crumbs; in a game, its name)
    if (nav.page != P_HOME) {
      std::string cr = gameIn ? ch.running + "  >  " : "Home  >  ";
      if (nav.page != P_SETTINGS) cr += "Settings  >  ";
      ch.crumbs = cr + scr::titleCase(title());
    }
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
  pc::stop();                               // (any game: the PC's disk closed first; pc::start opens it again)
  // the N64 game running now: its save to the card while the N64 is still there
  if (eepSize) { eepService(true); eepSize = 0; }
  if (srmSize) { srmService(true); srmSize = 0; }    // (the SNES's likewise)
  if (gbsOn) { gbsService(true); gbsOn = false; }    // (the Game Boy's likewise)
  if (gsavOn) { gbaSaveService(true); gsavOn = false; }   // (the Game Boy Advance's likewise)
  gclkOn = false;
  Status st = fpga.status();
  // (and when it is, but the card holds another image of it than the one installed: a
  // console updated on the card was never installed while it ran -- the newer one is now)
  bool stale = false;
  if (machineOfCore(st.core) == g.m) {
    File cf = SD.open(String("/cores/") + MACHINES[g.m].core + ".bin");
    if (cf) {
      stale = slotOf(MACHINES[g.m].core, cf.size()) < 0;
      cf.close();
    }
  }
  if (gmode) gmessage(String("starting ") + shown(g.name), MACHINES[g.m].name, g.m);
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
  prefs.begin("menu", false); prefs.putString("last", g.path); prefs.putUInt("lastT", (uint32_t)clockNow()); prefs.end();
  Log.println(String("menu: loaded ") + g.path + (loadFixes ? " (" + String(loadFixes) + " chunk(s) written again)" : ""));
}

static void goHome();                   // (below: back to the menu image)
// --- what a button does on each page -----------------------------------------------------------
static void pickItem(bool second = false) {
  int s = nav.sel;
  switch (nav.page) {
  case P_HOME: {
    if (gmode || inCore) {
      std::vector<HomeItem> h = homeItems();
      if (s >= (int)h.size()) break;
      switch (h[s].act) {
      case H_CONTINUE: { Last l = lastGame(); if (l.m >= 0) { cur = l.m; playGame(lists[l.m][l.i]); } break; }
      case H_CONSOLE: cur = h[s].m; rescanIfChanged(); go(P_GAMES); break;
      case H_RESUME: closeMenu(); break;
      case H_RESET: {
        if (pc::on) { fpga.busWrite(pc::CTRL, 0); delay(50); fpga.busWrite(pc::CTRL, 1); open_ = false; osd(0); break; }   // (the PC: its CPU's reset)
        // the console held in reset a moment (the run bit) and let go: the game from the start
        uint32_t c = fpga.busRead(NES_CTRL);
        fpga.busWrite(NES_CTRL, c & ~5u); delay(50); fpga.busWrite(NES_CTRL, (c | 1u) & ~4u);
        open_ = false; osd(0);
        break; }
      case H_SETTINGS: go(P_SETTINGS); break;
      case H_HOME: goHome(); break;
      }
      break;
    }
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
  Log.println("menu: the card changed -- its games read again");
}
static void openMenu() {
  // (no rescan here: with a DOS game reading the card all the while, reading every console's games
  // first held the menu back 20-30 s after files had been put on the card -- 2026-10-19; a console's
  // list reads them again when it is opened)
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
// Home: the game's save to the card, then the board back to the menu image (its reboot
// register; PROGRAM_B if that does not take), the graphical home on it. The console stays in
// the flash's slot: a game of it again only boots it.
static void goHome() {
  pc::stop();
  if (eepSize) { eepService(true); eepSize = 0; }
  if (srmSize) { srmService(true); srmSize = 0; }
  if (gbsOn) { gbsService(true); gbsOn = false; }
  if (gsavOn) { gbaSaveService(true); gsavOn = false; }
  gclkOn = false;
  message("going home", "the game is saved");
  pads::busBusy = true;
  fpga.busWrite(0x00000014, 0xB0070000);
  uint32_t t0 = millis();
  while (millis() - t0 < 2000 && fpga.status().core != 0) delay(50);
  if (fpga.status().core != 0) {
    fpga.forceShell();
    t0 = millis();
    while (millis() - t0 < 3000 && fpga.status().core != 0) delay(50);
  }
  pads::busBusy = false;
  gameIn = false;
  freshBoard();
  open_ = true; backStack.clear(); nav = { P_HOME, 0, 0 }; note = "";
  draw();
  Log.println("menu: home");
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
        if (first && splashOn() && !gmode) splash();
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
    if (gameIn) { eepService(); srmService(); gbsService(); gbaSaveService(); gbaClockService(); }
    // the background erase (the menu image from version 7; the slots, above): the highlighted
    // console -- its tile, or its games -- has no slot for a second and a half: the slot used less
    // recently is cleared for it, a sector at a time
    if (gmode && !inCore && shellV7 && open_) {
      static int hovM = -2; static uint32_t hovT = 0; static bool hovCached = true;
      int m = -1;
      if (nav.page == P_GAMES) m = cur;
      else if (nav.page == P_HOME) {
        std::vector<HomeItem> h = homeItems();
        if (nav.sel >= 0 && nav.sel < (int)h.size())
          m = h[nav.sel].act == H_CONSOLE ? h[nav.sel].m : h[nav.sel].act == H_CONTINUE ? lastGame().m : -1;
      }
      if (m != hovM) {
        hovM = m; hovT = millis(); hovCached = true;
        if (m >= 0) {
          File cf = SD.open(String("/cores/") + MACHINES[m].core + ".bin");
          if (cf) { hovCached = slotOf(MACHINES[m].core, cf.size()) >= 0; cf.close(); }
        }
      }
      bgEraseStep(m >= 0 && !hovCached && millis() - hovT > 1500 ? 1 - slotLast() : -1);
    }
    pc::focus = !open_;                            // (the controller types for the PC only with no menu up)
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
        Log.printf("menu: buttons %04x (new %04x), %s, level %d, item %d [%s]\n", p, e, open_ ? "open" : "closed",
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
    // the graphical pages show the time: drawn again when the minute turns
    static int minuteWas = -1;
    if (gmode && open_) {
      time_t now = clockNow();
      int mn = (int)((now / 60) % 60);
      if (mn != minuteWas) { bool first = minuteWas < 0; minuteWas = mn; lastDraw = millis(); if (!first) gparts({ G_CLOCK }); }
    }
    // the graphical home: the card, then the consoles five across
    if (gmode && nav.page == P_HOME) {
      if (!press && !edge) continue;
      std::vector<HomeItem> h = homeItems();
      int hc = (!h.empty() && h[0].act == H_CONTINUE) ? 1 : 0, nt = (int)h.size() - hc, s = nav.sel;
      if (press & pads::M_LEFT)  { if (s >= hc && (s - hc) % 5 > 0) s--; }
      if (press & pads::M_RIGHT) { if (s >= hc && (s - hc) % 5 < 4 && s + 1 < hc + nt) s++; }
      if (press & pads::M_UP)    { if (s >= hc) { if (s - hc >= 5) s -= 5; else if (hc) s = 0; } }
      if (press & pads::M_DOWN)  {
        if (hc && s == 0) { if (nt) s = hc; }
        else if (s - hc + 5 < nt) s += 5;
        else if ((s - hc) / 5 < (nt - 1) / 5) s = hc + nt - 1;
      }
      if (s != nav.sel) {
        int old = nav.sel, oldFirst = homeFirstRow;
        GRect a = homeSelRect(old, hc);
        nav.sel = s; homeFix(hc);
        if (homeFirstRow != oldFirst) draw();
        else if ((hc && old == 0) != (hc && s == 0)) gparts({ G_HINTS });   // (Play / Open)
        else ghl();
      }
      if ((edge & pads::M_A) || ((edge & pads::M_START) && !(p & pads::M_SEL))) pickItem();
      else if (edge & pads::M_Y) go(P_SETTINGS);
      continue;
    }
    // a list
    int n = (int)items().size();
    int pageRows = gmode ? 5 : nav.page == P_GAMES ? 18 : 9;
    bool change = nav.page == P_PICTURE || nav.page == P_SYSTEM;
    if (press & pads::M_UP)   { int o = nav.sel, ot = nav.top; if (nav.sel > 0) nav.sel--; else if (n) nav.sel = n - 1; listMoved(o, ot); }
    if (press & pads::M_DOWN) { int o = nav.sel, ot = nav.top; if (nav.sel + 1 < n) nav.sel++; else nav.sel = 0; listMoved(o, ot); }
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
    if (open_ && (nav.page == P_PADS || (!gmode && (nav.page == P_SETTINGS || nav.page == P_HOME))) && millis() - lastDraw > 1000) {
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
    Log.printf("menu: booted the slot's core (%u)\n", fpga.status().core);
  }
  // The task first -- its stack wants one piece of internal RAM, which Bluetooth leaves
  // short and the card's list (hundreds of small names) leaves in pieces -- then the card:
  // the start-up logo plays while it is read.
  size_t big = heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
  BaseType_t ok = pdFAIL;
  uint32_t stack = 0;
  for (uint32_t st : { 10240u, 9216u, 8192u, 7168u })
    if ((ok = xTaskCreatePinnedToCore(task, "menu", st, nullptr, 1, nullptr, 1)) == pdPASS) { stack = st; break; }
  Log.printf("menu: task %s (stack %u), internal RAM %u free, largest block %u\n", ok == pdPASS ? "running" : "NOT STARTED",
                (unsigned)stack, (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL), (unsigned)big);
  scan();
  for (int m : consoles) Log.printf("menu: %s, %u games\n", MACHINES[m].name, (unsigned)lists[m].size());
  scanned = true;
}

}  // namespace menu
