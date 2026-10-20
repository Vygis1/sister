// ui.h - the menu's screen: osd.v's 40 x 30 cells (version 2: its own glyphs, an 8-colour
// palette, a background colour per cell), kept here and sent to the board as it changes.
//
// Nothing in here knows about the ESP32: the board is reached through three functions
// (ui::hal), so the same drawing compiles on the PC for tools/menu_preview.
//
// A cell (osd.v):  [7:0] glyph  [8] highlight  [10:9]+[12] ink (palette 0-7)  [11] bar
//                  [13] own background, [16:14] its colour
// On a version-1 board (no glyph RAM, four inks) the menu's own glyphs are sent as the
// nearest plain character and the colours folded into the four it has.

#pragma once
#include <stdint.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <string>
#include "art.h"
extern "C" {
#include "qrgen.h"
}

namespace ui {

static const int COLS = 40, ROWS = 30;

// --- the board ---------------------------------------------------------------------------
struct Hal {
  void (*cells)(int first, const uint32_t *v, int n);      // cells first..first+n-1
  void (*reg)(uint32_t off, uint32_t v);                   // osd.v's page: CTRL, the palette
  void (*glyphRows)(int first, const uint32_t *rows, int n);  // glyph rows (glyph * 8 + row)
};
static Hal hal = { nullptr, nullptr, nullptr };
static bool v2 = true;                                     // the board's osd.v is version 2

// --- colours and cell bits ----------------------------------------------------------------
enum { WHITE = 0, YELLOW = 1, GREY = 2, GREEN = 3, PINK = 4, RED = 5, BLUE = 6, BLACK = 7 };
static const int SKIN = 6;                                 // (the splash's palette: 6 is skin)
enum : uint32_t { HL = 1u << 8, BAR = 1u << 11, SOLID = 1u << 13 };
static inline uint32_t inkBits(int c) { return ((uint32_t)(c & 3) << 9) | ((uint32_t)((c >> 2) & 1) << 12); }
static inline uint32_t bgBits(int c) { return SOLID | ((uint32_t)(c & 7) << 14); }

// --- the screen ---------------------------------------------------------------------------
// (on the heap: static RAM is short beside Bluetooth)
static uint32_t *cell = (uint32_t *)calloc(COLS * ROWS, 4);
static uint32_t *sent = (uint32_t *)calloc(COLS * ROWS, 4);
static uint32_t *runBuf = (uint32_t *)calloc(COLS * ROWS, 4);
static bool sentValid = false;
static uint32_t base = 0;            // what an empty cell is (a bar, a background)

static void clear(uint32_t attr = 0) {
  base = attr;
  for (int i = 0; i < COLS * ROWS; i++) cell[i] = ' ' | attr;
}
// one cell's glyph, ink and extra bits (the background bits are kept unless given)
static void glyph(int col, int row, uint8_t g, int ink = WHITE, uint32_t extra = 0) {
  if (col < 0 || col >= COLS || row < 0 || row >= ROWS) return;
  uint32_t &c = cell[row * COLS + col];
  uint32_t keep = (extra & (SOLID | (7u << 14))) ? 0 : (c & (SOLID | (7u << 14) | BAR));
  c = g | inkBits(ink) | keep | extra;
}
// a run of text (cut at the screen's edge); width pads with spaces
static void text(int col, int row, const char *s, int ink = WHITE, uint32_t extra = 0, int width = -1) {
  int n = (int)strlen(s), w = width < 0 ? n : width;
  for (int i = 0; i < w; i++) {
    uint8_t ch = i < n ? (uint8_t)s[i] : ' ';
    if (ch < 0x20 || ch > 0x7E) ch = '?';
    glyph(col + i, row, ch, ink, extra);
  }
}
static void text(int col, int row, const std::string &s, int ink = WHITE, uint32_t extra = 0, int width = -1) { text(col, row, s.c_str(), ink, extra, width); }
static void centre(int row, const std::string &s, int ink = WHITE, uint32_t extra = 0) { text((COLS - (int)s.size()) / 2, row, s, ink, extra); }
static void right(int endCol, int row, const std::string &s, int ink = WHITE, uint32_t extra = 0) { text(endCol - (int)s.size() + 1, row, s, ink, extra); }
// a rectangle's cells: given bits (a background, the highlight), spaces
static void fill(int c0, int r0, int c1, int r1, uint32_t attr) {
  for (int r = r0; r <= r1; r++) for (int c = c0; c <= c1; c++)
    if (c >= 0 && c < COLS && r >= 0 && r < ROWS) cell[r * COLS + c] = ' ' | attr;
}
// a name cut to fit, with an ellipsis
static std::string fit(const std::string &s, int w) { return (int)s.size() <= w ? s : s.substr(0, w > 3 ? w - 3 : 0) + "..."; }
static std::string num(long v) { char b[16]; snprintf(b, sizeof b, "%ld", v); return b; }

// A card, as the graphical menu's rows and panels: rounded, a colour of the palette (BLACK: the
// cards' own). Its top is the lower half of row r0, its bottom the upper half of row r1, so a
// card of three rows has its middle row's text centred in 32 pixels. What is written on it
// afterwards keeps its background (glyph keeps the cell's).
static void card(int c0, int r0, int c1, int r1, int colour = BLACK) {
  for (int c = c0; c <= c1; c++) {
    glyph(c, r0, c == c0 ? 0xC0 : c == c1 ? 0xC1 : 0x8C, colour, 0);
    glyph(c, r1, c == c0 ? 0xC2 : c == c1 ? 0xC3 : 0x83, colour, 0);
  }
  fill(c0, r0 + 1, c1, r1 - 1, bgBits(colour));
}
// a panel (once the font's thin lines): a card, its title over it in the dim ink
static void frame(int c0, int r0, int c1, int r1, const std::string &title = "", int ink = GREY) {
  card(c0, r0, c1, r1);
  if (!title.empty()) text(c0 + 1, r0 - 1, title, ink);
}

// --- big letters: 5 x 7, two letter pixels a cell each way (quadrant glyphs) --------------
static const art::BigChar *big(char c) {
  for (int i = 0; i < art::NBIG; i++) if (art::BIG[i].c == c) return &art::BIG[i];
  return &art::BIG[art::NBIG - 1];      // (a space)
}
static int bigWidth(const std::string &s) { return (int)s.size() * 3; }   // 6 letter pixels a letter, with its gap
// inks: one per cell row (4 of them), for a gradient
static void bigText(int col, int row, const std::string &s, const int inks[4], uint32_t extra = 0) {
  int w = (int)s.size() * 6;
  for (int cy = 0; cy < 4; cy++)
    for (int cx = 0; cx < w / 2; cx++) {
      int q = 0;
      for (int k = 0; k < 4; k++) {
        int px = cx * 2 + (k & 1), py = cy * 2 + (k >> 1);
        const art::BigChar *b = big(s[px / 6]);
        int lx = px % 6;
        if (py < 7 && lx < 5 && (b->rows[py] >> (4 - lx) & 1)) q |= 1 << k;
      }
      if (q) glyph(col + cx, row + cy, art::G_QUAD + q, inks[cy], extra);
    }
}

// --- the logo ----------------------------------------------------------------------------
// (on the splash's black: its black cells are left as they are)
static void logo(int col, int row) {
  for (int y = 0; y < art::LOGO_H; y++)
    for (int x = 0; x < art::LOGO_W; x++) {
      const art::LogoCell &L = art::LOGO[y * art::LOGO_W + x];
      if (L.glyph == 0 && L.bg == art::C_BLACK) continue;
      glyph(col + x, row + y, L.glyph ? L.glyph : ' ', L.ink, L.bg == art::C_BLACK ? 0 : bgBits(L.bg));
    }
}

// --- a QR code ---------------------------------------------------------------------------
// (the version from the text's length: qrcode_initText says yes to a version too small and
// makes a code no phone reads -- byte mode, low error correction, versions 1-6)
static int qrVersion(const char *s) {
  static const int CAP[7] = { 0, 17, 32, 53, 78, 106, 134 };
  int n = (int)strlen(s);
  for (int v = 1; v <= 6; v++) if (n <= CAP[v]) return v;
  return 0;
}
// Black modules on white, two modules a cell each way, a quiet zone of two modules. Returns
// its size in cells (0: the text did not fit version 6).
static int qr(int col, int row, const char *s) {
  static uint8_t buf[256];
  QRCode q;
  int ver = qrVersion(s);
  if (!ver || qrcode_getBufferSize(ver) > sizeof buf || qrcode_initText(&q, buf, ver, ECC_LOW, s) != 0) return 0;
  int n = q.size + 4, cells = (n + 1) / 2;
  for (int cy = 0; cy < cells; cy++)
    for (int cx = 0; cx < cells; cx++) {
      int b = 0;
      for (int k = 0; k < 4; k++) {
        int mx = cx * 2 + (k & 1) - 2, my = cy * 2 + (k >> 1) - 2;
        if (mx >= 0 && my >= 0 && mx < q.size && my < q.size && qrcode_getModule(&q, mx, my)) b |= 1 << k;
      }
      glyph(col + cx, row + cy, art::G_QUAD + b, BLACK, bgBits(WHITE));
    }
  return cells;
}
static int qrCells(const char *s) {
  int v = qrVersion(s);
  return v ? (17 + 4 * v + 4 + 1) / 2 : 0;
}

// --- to the board ------------------------------------------------------------------------
// (version 1: the menu's glyphs as plain characters, the inks folded into four)
static uint32_t asV1(uint32_t c) {
  uint8_t g = c & 0xFF;
  int ink = ((c >> 9) & 3) | (((c >> 12) & 1) << 2);
  static const char QUAD[16] = { ' ', '\'', '\'', '"', '.', '|', '/', 'P', '.', '\\', '|', '9', '_', 'b', 'd', '#' };
  if (g >= art::G_QUAD && g < art::G_QUAD + 16) g = QUAD[g - art::G_QUAD];
  else if (g == art::G_CROSS) g = 'X';
  else if (g == art::G_CIRCLE) g = 'O';
  else if (g == art::G_SQUARE) g = '#';
  else if (g == art::G_TRIANGLE) g = 'A';
  else if (g == art::G_TICK) g = '*';
  else if (g == art::G_LEFT) g = '<';
  else if (g == art::G_RIGHT) g = '>';
  else if (g >= 0x80) g = (g >= art::G_LOGO) ? '#' : '*';
  static const int FOLD[8] = { 0, 1, 2, 3, 1, 1, 0, 2 };
  return g | ((uint32_t)FOLD[ink & 7] << 9) | (c & (HL | BAR));
}

// the cells that changed since the last time, in runs
static void flush() {
  if (!hal.cells) return;
  int i = 0, N = COLS * ROWS;
  uint32_t *run = runBuf;
  while (i < N) {
    if (sentValid && sent[i] == cell[i]) { i++; continue; }
    int j = i;
    while (j < N && (!sentValid || sent[j] != cell[j] || (j + 1 < N && sent[j + 1] != cell[j + 1]))) j++;
    for (int k = i; k < j; k++) run[k - i] = v2 ? cell[k] : asV1(cell[k]);
    hal.cells(i, run, j - i);
    for (int k = i; k < j; k++) sent[k] = cell[k];
    i = j;
  }
  sentValid = true;
}
static void forget() { sentValid = false; }      // (the board's cells are not what was sent: send them all)

static uint32_t palNow[8];
static void palette(const uint32_t p[8]) {
  for (int i = 0; i < 8; i++) if (palNow[i] != p[i] || !sentValid) { palNow[i] = p[i]; if (hal.reg && v2) hal.reg(0x40 + 4 * i, p[i]); }
}
// CTRL: [0] show [1] the game dimmed behind [2] black
static void ctrl(uint32_t v) { if (hal.reg) hal.reg(0x04, v2 ? v : (v & 3)); }

// the glyphs (at power-up: the RAM's upper half starts empty)
static void loadGlyphs() {
  if (!hal.glyphRows || !v2) return;
  static uint32_t rows[8];
  for (int i = 0; i < art::NGLYPHS; i++) {
    for (int r = 0; r < 8; r++) rows[r] = art::GLYPHS[i].rows[r];
    hal.glyphRows(art::GLYPHS[i].code * 8, rows, 8);
  }
}

}  // namespace ui
