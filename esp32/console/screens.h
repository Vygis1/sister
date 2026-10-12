// screens.h - what each page of the menu looks like, from plain data (no board, no SD card,
// no Wi-Fi in here: menu.h gathers what a page shows and calls these; tools/menu_preview
// calls them with made-up data). All of it draws into ui.h's cells.

#pragma once
#include <vector>
#include <string>
#include "ui.h"

namespace scr {
using namespace ui;

// --- the frame every page sits in -----------------------------------------------------------
struct Chrome {
  int wifiBars = -1;            // -1 not connected, 0-3
  bool pad1 = false, pad2 = false;
  std::string running;          // the console behind the menu ("" the shell)
};

// the button hints at the bottom: glyph + word, in the pad's own colours
struct Hint { uint8_t g; const char *what; };
static int buttonInk(uint8_t g) {
  return g == art::G_CROSS ? BLUE : g == art::G_CIRCLE ? RED : g == art::G_SQUARE ? PINK : g == art::G_TRIANGLE ? GREEN : WHITE;
}
static void hints(const std::vector<Hint> &h) {
  int w = 0;
  for (auto &x : h) w += 2 + (int)strlen(x.what) + 3;
  int c = (COLS - w + 3) / 2;
  for (auto &x : h) {
    if (x.g) glyph(c, 28, x.g, buttonInk(x.g));
    else glyph(c, 28, ' ');
    text(c + 2, 28, x.what, GREY);
    c += 2 + (int)strlen(x.what) + 3;
  }
}

static void chrome(const Chrome &ch, const std::vector<Hint> &h) {
  clear();
  fill(0, 0, COLS - 1, 2, BAR);
  fill(0, 27, COLS - 1, 29, BAR);
  glyph(2, 1, art::G_HEART, PINK);
  text(4, 1, "BYBA GAMES", YELLOW);
  if (!ch.running.empty()) text(16, 1, fit(ch.running, 12), GREY);
  // the two pads
  glyph(33, 1, art::G_PAD, ch.pad1 ? GREEN : GREY); glyph(34, 1, '1', ch.pad1 ? GREEN : GREY);
  glyph(36, 1, art::G_PAD, ch.pad2 ? GREEN : GREY); glyph(37, 1, '2', ch.pad2 ? GREEN : GREY);
  hints(h);
}

// --- a list: consoles, games, settings, networks, buttons ----------------------------------
struct Item {
  std::string text, value;      // the value goes right-aligned
  uint8_t icon = 0; int iconInk = WHITE;
  int ink = WHITE, valueInk = YELLOW;
  bool gap = false;             // a blank row before it (a group's start)
  uint8_t valueGlyph = 0; int valueGlyphInk = GREY;   // an icon at the right edge (a padlock)
};
// title in the frame's top edge; info: lines under the list (inside the frame); note: one
// line under the frame (what just happened). top: the first item shown, kept so sel shows.
static void list(const Chrome &ch, const std::string &title, const std::vector<Item> &items, int sel, int &top,
                 const std::vector<std::string> &info, const std::string &note, const std::vector<Hint> &h,
                 int step = 0) {
  chrome(ch, h);
  frame(1, 4, 38, 25, title);
  int rowsAvail = 19 - (info.empty() ? 0 : (int)info.size() + 1);
  if (step == 0) {            // a line apart when they all fit that way, else one under another
    int need = 0;
    for (size_t i = 0; i < items.size(); i++) need += 2 + (items[i].gap && i ? 1 : 0);
    step = need <= rowsAvail + 1 ? 2 : 1;
  }
  // rows each item takes (its gap and its step)
  auto rowsOf = [&](int i) { return step + (items[i].gap && i > top ? 1 : 0); };
  if (sel < top) top = sel;
  for (;;) {           // sel must fit below top
    int used = 0;
    for (int i = top; i <= sel && i < (int)items.size(); i++) used += rowsOf(i);
    if (used <= rowsAvail || top >= sel) break;
    top++;
  }
  int row = 6;
  int last = top;
  for (int i = top; i < (int)items.size(); i++) {
    int need = rowsOf(i);
    if (row - 6 + need > rowsAvail) break;
    if (items[i].gap && i > top) row++;
    const Item &it = items[i];
    bool here = i == sel;
    uint32_t hl = here ? HL : 0;
    text(2, row, "", WHITE, hl, 36);
    if (here) glyph(3, row, 0x10, YELLOW, HL);
    int c = 5;
    if (it.icon) { glyph(c, row, it.icon, it.iconInk, hl); c += 2; }
    int vw = (int)it.value.size() + (it.valueGlyph ? 2 : 0);
    text(c, row, fit(it.text, 36 - c - (vw ? vw + 1 : 0)), it.ink, hl);
    if (it.valueGlyph) glyph(36, row, it.valueGlyph, it.valueGlyphInk, hl);
    if (!it.value.empty()) right(it.valueGlyph ? 34 : 36, row, it.value, it.valueInk, hl);
    row += step;
    last = i;
  }
  if (top > 0) glyph(38, 6, 0x1E, YELLOW);
  if (last + 1 < (int)items.size()) glyph(38, 6 + rowsAvail - 1, 0x1F, YELLOW);
  if (items.size() > (size_t)rowsAvail / step && items.size() > 9)
    right(36, 25, " " + num(sel + 1) + "/" + num((long)items.size()) + " ", GREY);
  for (size_t k = 0; k < info.size(); k++) text(3, 25 - (int)info.size() + (int)k, fit(info[k], 34), GREY);
  if (!note.empty()) text(2, 26, fit(note, 36), YELLOW);
}

// --- a message in a box (loading, switching, an error) ---------------------------------------
static void message(const Chrome &ch, const std::string &a, const std::string &b = "", int ink = WHITE) {
  chrome(ch, {});
  frame(2, 10, 37, 18);
  centre(13, fit(a, 32), ink);
  if (!b.empty()) centre(15, fit(b, 32), GREY);
}

// --- the splash: the logo, then the name, a letter at a time ---------------------------------
// t: frames since it started (about 30 a second). Black behind it (osd CTRL bit 2).
static const int SPLASH_FRAMES = 105;
static void splash(int t) {
  clear();
  // the logo, its rows uncovered from the top
  int rows = t < 0 ? 0 : t / 2 + 1;
  int lc = (COLS - art::LOGO_W) / 2, lr = 2;
  for (int y = 0; y < art::LOGO_H && y < rows; y++)
    for (int x = 0; x < art::LOGO_W; x++) {
      const art::LogoCell &L = art::LOGO[y * art::LOGO_W + x];
      if (L.glyph == 0 && L.bg == art::C_BLACK) continue;
      glyph(lc + x, lr + y, L.glyph ? L.glyph : ' ', L.ink, L.bg == art::C_BLACK ? 0 : bgBits(L.bg));
    }
  // the name: BYBA, then GAMES, a letter every three frames
  static const int top[4] = { PINK, PINK, RED, RED }, bot[4] = { YELLOW, YELLOW, YELLOW, YELLOW };
  int shown = (t - 18) / 3;
  if (shown > 0) {
    std::string a = "BYBA", b = "GAMES";
    std::string aa = a.substr(0, shown < 4 ? shown : 4);
    bigText((COLS - bigWidth(a)) / 2, 12, aa, top);
    if (shown > 4) {
      std::string bb = b.substr(0, shown - 4 < 5 ? shown - 4 : 5);
      bigText((COLS - bigWidth(b)) / 2, 17, bb, bot);
    }
  }
  if (t > 50) centre(23, "the FPGA game console", GREY);
  if (t > 70 && (t / 15) % 2 == 0) centre(26, "press any button", WHITE);
}

// --- the on-screen keyboard -------------------------------------------------------------------
// layers: 0 lower case, 1 upper case, 2 symbols. The last row is the keys that do things.
static const char *KB[3][4] = {
  { "1234567890", "qwertyuiop", "asdfghjkl-", "zxcvbnm._@" },
  { "1234567890", "QWERTYUIOP", "ASDFGHJKL-", "ZXCVBNM._@" },
  { "!?#$%&*()=", "+/\\|<>[]{}", ";:'\"`~^,_-", "        .@" },
};
static const char *KB_ACT[5] = { "Shift", "Sym", "Space", "Del", "Done" };
static const int KB_ROWS = 5;                 // four of letters, the action row
static int kbCols(int row) { return row < 4 ? 10 : 5; }
static void keyboard(const Chrome &ch, const std::string &title, const std::string &typed, bool hide, int layer,
                     int kr, int kc, const std::string &note) {
  chrome(ch, { { art::G_CROSS, "type" }, { art::G_CIRCLE, "delete" }, { art::G_SQUARE, hide ? "show" : "hide" }, { art::G_TRIANGLE, "caps" } });
  frame(1, 4, 38, 25, title);
  // the field
  fill(3, 7, 36, 7, bgBits(BLACK));
  std::string shown = hide ? std::string(typed.size(), '*') : typed;
  if ((int)shown.size() > 32) shown = shown.substr(shown.size() - 32);
  text(4, 7, shown, WHITE, bgBits(BLACK));
  glyph(4 + (int)shown.size(), 7, '_', YELLOW, bgBits(BLACK));
  // the keys: three cells each, a cell between
  for (int r = 0; r < 4; r++) {
    const char *keys = KB[layer][r];
    for (int c = 0; c < 10; c++) {
      int col = 5 + c * 3, row = 10 + r * 2;
      bool here = kr == r && kc == c;
      char k[2] = { keys[c], 0 };
      if (k[0] == ' ') continue;
      fill(col, row, col + 1, row, here ? HL : bgBits(BLACK));
      text(col, row, k, here ? YELLOW : WHITE, here ? HL : bgBits(BLACK));
    }
  }
  int col = 3;
  for (int a = 0; a < 5; a++) {
    int w = (int)strlen(KB_ACT[a]) + 2;
    bool here = kr == 4 && kc == a;
    bool on = (a == 0 && layer == 1) || (a == 1 && layer == 2);
    fill(col, 19, col + w - 1, 19, here ? HL : bgBits(BLACK));
    text(col + 1, 19, KB_ACT[a], here ? YELLOW : on ? GREEN : WHITE, here ? HL : bgBits(BLACK));
    col += w + 1;
  }
  text(3, 22, "START when it is typed", GREY);
  if (!note.empty()) text(2, 26, fit(note, 36), YELLOW);
}
// the key under the cursor (0: an action, then act gets 0-4)
static char keyAt(int layer, int kr, int kc, int &act) {
  act = -1;
  if (kr == 4) { act = kc; return 0; }
  return KB[layer][kr][kc];
}

// --- two QR codes: join the console's own network, then open its page ------------------------
static void qrPage(const Chrome &ch, const std::string &apName, const std::string &apPass, const std::string &url) {
  chrome(ch, { { art::G_CIRCLE, "back" } });
  if (!v2) {           // (no glyphs to draw a code with: the same in words)
    frame(2, 8, 37, 20, "CONNECT WITH A PHONE");
    text(4, 11, "1. join the Wi-Fi network", YELLOW);
    text(7, 12, apName + "  password " + apPass, WHITE);
    text(4, 15, "2. open in the browser", YELLOW);
    text(7, 16, url, WHITE);
    return;
  }
  std::string join = "WIFI:T:WPA;S:" + apName + ";P:" + apPass + ";;";
  int a = qrCells(join.c_str()), b = qrCells(url.c_str());
  int gap = 3, c0 = (COLS - (a + gap + b)) / 2;
  int r0 = 4;
  qr(c0, r0, join.c_str());
  qr(c0 + a + gap, r0 + (a - b) / 2, url.c_str());
  int cap = r0 + a + 1;
  auto under = [&](int c, int w, int row, const std::string &s, int ink) { text(c + (w - (int)s.size()) / 2, row, s, ink); };
  under(c0, a, cap, "1. JOIN", YELLOW);
  under(c0, a, cap + 1, apName, WHITE);
  under(c0, a, cap + 2, "pw " + apPass, GREY);
  std::string host = url.substr(url.find("//") == std::string::npos ? 0 : url.find("//") + 2);
  if (!host.empty() && host.back() == '/') host.pop_back();
  under(c0 + a + gap, b, cap, "2. OPEN", YELLOW);
  under(c0 + a + gap, b, cap + 1, host, WHITE);
  centre(cap + 4, "then choose your Wi-Fi on that page", GREY);
}

// --- the controller test: both pads, every button lit as it is pressed -------------------------
struct PadView {
  bool on = false;
  std::string name;
  bool cross, circle, square, triangle, l1, r1, l2, r2, sel, start, home, up, down, left, right;
  int lx, ly, rx, ry;           // -128..127
  int battery = -1;             // 0-100, -1 not known
};
static void stickBox(int c0, int r0, int x, int y, bool on) {
  // 5 x 5 cells, a dot where the stick is
  for (int r = 0; r < 5; r++) for (int c = 0; c < 5; c++) glyph(c0 + c, r0 + r, '.', GREY);
  int cx = 2 + x * 5 / 256, cy = 2 + y * 5 / 256;
  if (cx < 0) cx = 0; if (cx > 4) cx = 4; if (cy < 0) cy = 0; if (cy > 4) cy = 4;
  glyph(c0 + cx, r0 + cy, 0x07, on ? YELLOW : GREY);
}
static void padPanel(int c0, int player, const PadView &p) {
  frame(c0, 4, c0 + 18, 24, std::string("PLAYER ") + (char)('0' + player), p.on ? GREEN : GREY);
  if (!p.on) { text(c0 + 3, 13, "nothing here", GREY); return; }
  text(c0 + 2, 6, fit(p.name, 15), WHITE);
  if (p.battery >= 0) text(c0 + 2, 7, "battery " + num(p.battery) + "%", GREY);
  auto lit = [](bool b) { return b ? YELLOW : GREY; };
  text(c0 + 2, 9, "L2", lit(p.l2)); text(c0 + 5, 9, "L1", lit(p.l1));
  text(c0 + 12, 9, "R1", lit(p.r1)); text(c0 + 15, 9, "R2", lit(p.r2));
  glyph(c0 + 4, 11, 0x1E, lit(p.up)); glyph(c0 + 3, 12, art::G_LEFT, lit(p.left));
  glyph(c0 + 5, 12, art::G_RIGHT, lit(p.right)); glyph(c0 + 4, 13, 0x1F, lit(p.down));
  glyph(c0 + 14, 11, art::G_TRIANGLE, p.triangle ? GREEN : GREY);
  glyph(c0 + 12, 12, art::G_SQUARE, p.square ? PINK : GREY);
  glyph(c0 + 16, 12, art::G_CIRCLE, p.circle ? RED : GREY);
  glyph(c0 + 14, 13, art::G_CROSS, p.cross ? BLUE : GREY);
  text(c0 + 7, 11, "SEL", lit(p.sel)); text(c0 + 7, 13, "STA", lit(p.start));
  glyph(c0 + 8, 12, art::G_HEART, p.home ? PINK : GREY);
  stickBox(c0 + 2, 16, p.lx, p.ly, p.lx || p.ly);
  stickBox(c0 + 12, 16, p.rx, p.ry, p.rx || p.ry);
  text(c0 + 2, 22, "left  " + num(p.lx) + ", " + num(p.ly), GREY);
  text(c0 + 2, 23, "right " + num(p.rx) + ", " + num(p.ry), GREY);
}
static void tester(const Chrome &ch, const PadView &a, const PadView &b) {
  chrome(ch, { { art::G_CIRCLE, "hold 1 s: back" } });
  padPanel(1, 1, a);
  padPanel(20, 2, b);
  centre(26, "press anything: it lights up", GREY);
}

// --- pairing a pad ----------------------------------------------------------------------------
static void pairing(const Chrome &ch, int secondsLeft, const std::vector<std::string> &pads, const std::string &note) {
  chrome(ch, { { art::G_CIRCLE, "done" } });
  frame(1, 4, 38, 25, "PAIR A CONTROLLER");
  glyph(3, 6, art::G_BT, BLUE);
  text(5, 6, "Looking for controllers", WHITE);
  if (secondsLeft >= 0) right(36, 6, num(secondsLeft) + " s", YELLOW);
  text(3, 8, "PS4 / PS5:  hold SHARE (CREATE) and PS", GREY);
  text(3, 9, "            until the light flashes fast", GREY);
  text(3, 10, "Xbox:       hold the pairing button", GREY);
  text(3, 11, "Switch Pro: hold the sync button", GREY);
  text(3, 12, "8BitDo:     START + Y, then pair", GREY);
  text(3, 15, "Connected now:", WHITE);
  for (size_t i = 0; i < pads.size() && i < 4; i++) {
    glyph(4, 17 + (int)i, art::G_PAD, GREEN);
    text(6, 17 + (int)i, fit(pads[i], 30), WHITE);
  }
  if (pads.empty()) text(6, 17, "none yet", GREY);
  if (!note.empty()) text(2, 26, fit(note, 36), YELLOW);
}

// --- press a button (binding) -----------------------------------------------------------------
static void waitButton(const Chrome &ch, const std::string &console, const std::string &button, int secondsLeft) {
  chrome(ch, {});
  frame(4, 9, 35, 19, "BUTTON MAPPING");
  centre(12, console, GREY);
  centre(14, "press the button for", WHITE);
  centre(15, button, YELLOW);
  centre(17, "(" + num(secondsLeft) + " s - or wait to cancel)", GREY);
}

}  // namespace scr
