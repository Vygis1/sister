// gfx.h - the graphical menu's drawing, as a list the board draws (rtl/shell_ui.v composes the
// picture itself, a line at a time, from objects: esp32/console/ui_list.h). The screens
// (gfxmenu.h) call the drawing functions here as they would draw pixels; each call is an object
// in the list, and render() sends the list (a couple of kilobytes) and swaps it in at the next
// frame. The fonts (gfx_font.h, from tools/menu/mkfont.py) and the images (the consoles' logos and
// the pad's symbols from the card, tools/menu/mklogos.py) go to the board once (begin(), and an
// image the first time it is drawn).
//
// (Until 2026-10-17 evening the pixels were drawn here and sent -- a page took two seconds.)

#pragma once
#include <Arduino.h>
#include <SD.h>
#include <esp_heap_caps.h>
#include <string>
#include <vector>
#include "gfx_font.h"
#include "ui_list.h"

namespace gfx {

static const int W = 640, H = 480;
static const uint32_t UI = 0x00090000, UI_CTRL = UI + 0x04, UI_COMMIT = UI + 0x08, UI_ASC = UI + 0x100,
                      HL_POS = UI + 0x20, HL_SIZE = UI + 0x24, HL_CTL = UI + 0x28, HL_COL = UI + 0x2C,
                      HL_LUT = UI + 0x40, HL_T = UI + 0x80,
                      UI_OBJ = 0x000A0000, UI_STR = 0x000A4000, UI_GLY = 0x000A8000, UI_FNT = 0x000B0000, UI_IMG = 0x000D0000;

struct RGB { uint8_t r, g, b; };
static inline RGB rgb(uint32_t c) { return { (uint8_t)(c >> 16), (uint8_t)(c >> 8), (uint8_t)c }; }
static inline uint32_t u24(RGB c) { return ((uint32_t)c.r << 16) | ((uint32_t)c.g << 8) | c.b; }

// --- the link ------------------------------------------------------------------------------------
static void (*wr1)(uint32_t, uint32_t) = nullptr;
static void (*wrN)(uint32_t, const uint32_t *, size_t) = nullptr;
static uint32_t (*rd1)(uint32_t) = nullptr;
static void link(void (*w1)(uint32_t, uint32_t), void (*wN)(uint32_t, const uint32_t *, size_t), uint32_t (*r1)(uint32_t)) {
  wr1 = w1; wrN = wN; rd1 = r1;
}

// --- the fonts -------------------------------------------------------------------------------------
using gfxfont::Font;
static const Font *FONTS[] = { &gfxfont::F12, &gfxfont::F12B, &gfxfont::F14, &gfxfont::F14B, &gfxfont::F18,
                               &gfxfont::F18B, &gfxfont::F22B, &gfxfont::F24B, &gfxfont::F30 };
static const int NF = 9;
static int fontIndex(const Font &f) { for (int i = 0; i < NF; i++) if (FONTS[i] == &f) return i; return 0; }
static uint32_t gen = 0;               // the board's generation: a new bitstream has none of what was sent
static bool ready = false;
// the fonts to the board: their pixels one after another, the glyph table, the ascents
static bool begin() {
  if (!wr1 || !wrN) return false;
  gen++;
  uint32_t at = 0;
  static uint32_t tab[2 * 191];
  static uint32_t buf[256];
  for (int f = 0; f < NF; f++) {
    const Font &F = *FONTS[f];
    uint32_t n = 0;
    for (int g = 0; g < 191; g++) { uint32_t e = F.g[g].at + ((F.g[g].w + 1) / 2) * F.g[g].h; if (e > n) n = e; }
    uint32_t words = (n + 3) / 4;
    for (uint32_t k = 0; k < words; k += 256) {
      uint32_t m = min((uint32_t)256, words - k);
      memset(buf, 0, sizeof(buf));
      memcpy(buf, F.px + k * 4, min((uint32_t)(m * 4), n - k * 4));
      wrN(UI_FNT + at + k * 4, buf, m);
    }
    for (int g = 0; g < 191; g++) {
      const gfxfont::Glyph &G = F.g[g];
      tab[2 * g] = (at + G.at) | ((uint32_t)G.w << 17) | ((uint32_t)G.h << 23);
      tab[2 * g + 1] = (uint32_t)G.adv | ((uint32_t)(uint8_t)G.dx << 6) | ((uint32_t)(uint8_t)G.dy << 14);
    }
    wrN(UI_GLY + f * 256 * 8, tab, 2 * 191);
    wr1(UI_ASC + 4 * f, F.ascent);
    at += words * 4;
  }
  wr1(UI_CTRL, 1);
  ready = true;
  return true;
}
static void forget() {}                // (the list is sent whole each time)
static void end() { ready = false; }

// --- images: RGBA from the card (.lgo, tools/menu/mklogos.py), on the board the first time drawn ----
struct Image { uint16_t w = 0, h = 0; uint8_t *px = nullptr; uint32_t at = 0, gen = 0; };
static uint32_t imgNext = 0, imgGen = 0;
static Image loadImage(const char *path) {
  Image im;
  File f = SD.open(path);
  if (!f) return im;
  uint8_t hd[8];
  if (f.read(hd, 8) == 8 && !memcmp(hd, "LGO1", 4)) {
    im.w = hd[4] | (hd[5] << 8); im.h = hd[6] | (hd[7] << 8);
    size_t n = (size_t)im.w * im.h * 4;
    im.px = (uint8_t *)heap_caps_malloc(n, MALLOC_CAP_SPIRAM);
    if (!im.px || f.read(im.px, n) != (int)n) { if (im.px) free(im.px); im = Image(); }
  }
  f.close();
  return im;
}
static bool ensure(Image &im) {
  if (!im.px) return false;
  if (im.gen == gen) return true;
  if (imgGen != gen) { imgNext = 0; imgGen = gen; }
  uint32_t n = (uint32_t)im.w * im.h;
  if (imgNext + n > (uint32_t)uil::IMG_PIXELS) return false;
  im.at = imgNext;
  static uint32_t buf[256];
  uint32_t k = 0, sent = 0;
  for (uint32_t i = 0; i < n; i += 2) {
    uint32_t v = 0;
    for (int h = 0; h < 2; h++) {
      if (i + h >= n) break;
      const uint8_t *p = im.px + (i + h) * 4;
      uint32_t q = ((uint32_t)((p[0] * 15 + 127) / 255) << 12) | ((uint32_t)((p[1] * 15 + 127) / 255) << 8) |
                   ((uint32_t)((p[2] * 15 + 127) / 255) << 4) | (uint32_t)((p[3] * 15 + 127) / 255);
      v |= q << (16 * h);
    }
    buf[k++] = v;
    if (k == 256) { wrN(UI_IMG + (im.at + sent) * 2, buf, k); sent += 2 * k; k = 0; }
  }
  if (k) wrN(UI_IMG + (im.at + sent) * 2, buf, k);
  imgNext = (imgNext + n + 1) & ~1u;
  im.gen = gen;
  return true;
}

// --- the list ---------------------------------------------------------------------------------------
static std::vector<uil::Obj> objs;
static std::string strs;
static bool full() { return objs.size() >= (size_t)uil::MAX_OBJ - 1; }
static void clip(int, int, int, int) {}
static void noClip() {}
static void background(RGB accent) { if (!full()) objs.push_back(uil::mk(uil::T_BG, 0, 0, W, H, 0, 0, u24(accent), 255)); }
static void rrect(int x, int y, int w, int h, int r, RGB c, int a = 255) {
  if (w <= 0 || h <= 0 || a <= 0 || full()) return;
  r = min(r, min(w, h) / 2); r = min(r, 31);
  objs.push_back(uil::mk(uil::T_RECT, x, y, w, h, r, 0, u24(c), a));
}
static void fill(int x, int y, int w, int h, RGB c, int a = 255) { rrect(x, y, w, h, 0, c, a); }
static void rrectLine(int x, int y, int w, int h, int r, RGB c, int a = 255, int t = 1) {
  if (w <= 0 || h <= 0 || a <= 0 || full()) return;
  r = min(r, min(w, h) / 2); r = min(r, 31);
  objs.push_back(uil::mk(uil::T_LINE, x, y, w, h, r, min(t, 7), u24(c), a));
}
static void glow(int x, int y, int w, int h, int r, RGB c, int spread, int a = 160) {
  for (int d = spread; d >= 1; d--) rrectLine(x - d, y - d, w + 2 * d, h + 2 * d, r + d, c, a * (spread - d + 1) / (spread + 1) / spread * 2, 1);
}
static void disc(float cx, float cy, float r, RGB c, int a = 255) {
  int ri = (int)(r + 0.5f);
  rrect((int)cx - ri, (int)cy - ri, 2 * ri, 2 * ri, ri, c, a);
}

// text: UTF-8 in (anything past Latin-1 as '?'), Latin-1 to the board
static uint32_t nextCp(const char *&s) {
  uint8_t c = (uint8_t)*s++;
  if (c < 0x80) return c;
  int n = (c & 0xE0) == 0xC0 ? 1 : (c & 0xF0) == 0xE0 ? 2 : (c & 0xF8) == 0xF0 ? 3 : 0;
  uint32_t cp = c & (0x3F >> n);
  for (int i = 0; i < n && (*s & 0xC0) == 0x80; i++) cp = (cp << 6) | (*s++ & 0x3F);
  return cp;
}
static const gfxfont::Glyph *glyphOf(const Font &f, uint32_t cp) {
  if (cp >= 32 && cp <= 126) return &f.g[cp - 32];
  if (cp >= 160 && cp <= 255) return &f.g[95 + cp - 160];
  return &f.g['?' - 32];
}
static int textWidth(const Font &f, const char *s) {
  int w = 0;
  while (*s) w += glyphOf(f, nextCp(s))->adv;
  return w;
}
enum Align { LEFT, CENTRE, RIGHT };
// y: the top of the line
static int text(const Font &f, int x, int y, const char *s, RGB c, Align al = LEFT, int a = 255) {
  int w = textWidth(f, s);
  if (al == CENTRE) x -= w / 2; else if (al == RIGHT) x -= w;
  std::string t;
  while (*s) { uint32_t cp = nextCp(s); t += (char)((cp >= 32 && cp <= 126) || (cp >= 160 && cp <= 255) ? cp : '?'); }
  if (t.empty() || full() || strs.size() + t.size() > (size_t)uil::STR_BYTES || t.size() > 255) return w;
  objs.push_back(uil::mk(uil::T_TEXT, x, y, w, f.line, 0, 0, u24(c), a,
                         ((uint32_t)fontIndex(f) << 28) | ((uint32_t)t.size() << 20) | (uint32_t)strs.size()));
  strs += t;
  return w;
}
// text cut to a width, with an ellipsis
static std::string fit(const Font &f, const std::string &s, int w) {
  if (textWidth(f, s.c_str()) <= w) return s;
  std::string t = s;
  while (!t.empty() && textWidth(f, (t + "...").c_str()) > w) {
    t.pop_back();
    while (!t.empty() && ((uint8_t)t.back() & 0xC0) == 0x80) t.pop_back();   // (a whole UTF-8 character)
  }
  return t + "...";
}
// an image, centred on cx, cy
static void image(Image &im, int cx, int cy, int a = 255) {
  if (full() || !ensure(im)) return;
  objs.push_back(uil::mk(uil::T_IMAGE, cx - im.w / 2, cy - im.h / 2, im.w, im.h, 0, 0, 0, a, im.at));
}
static void image(const Image &im, int cx, int cy, int a = 255) { image(const_cast<Image &>(im), cx, cy, a); }

// the pad's face buttons and the gear: little images from the card (/menu/icons)
enum Sym { S_CROSS, S_CIRCLE, S_SQUARE, S_TRIANGLE, S_START, S_L1R1 };
static Image icons[7]; static bool iconsTried = false;
static Image &icon(int i) {
  if (!iconsTried) {
    iconsTried = true;
    static const char *N[7] = { "cross", "circle", "square", "triangle", "start", "l1", "gear" };
    for (int k = 0; k < 7; k++) icons[k] = loadImage((std::string("/menu/icons/") + N[k] + ".lgo").c_str());
  }
  return icons[i];
}
static void buttonSym(Sym s, int cx, int cy) {
  disc(cx, cy, 10, { 255, 255, 255 }, 40);
  image(icon((int)s), cx, cy);
}
static void gear(int cx, int cy, int, RGB) { image(icon(6), cx, cy); }

// --- the selection: drawn by the board over the picture (rtl/shell_hl.v) ----------------------------
// A rounded rectangle and how it looks by the distance from its edge (its table: k - 4 pixels from
// the edge, inside negative): moving it is four register writes.
enum HlStyle { HL_TILE, HL_BAR };
struct HlEntry { uint8_t a; bool col; };
static const HlEntry HL_TILE_T[16] = { { 22, 0 }, { 22, 0 }, { 200, 0 }, { 255, 0 }, { 255, 0 }, { 150, 1 }, { 110, 1 }, { 80, 1 },
                                       { 55, 1 }, { 35, 1 }, { 20, 1 }, { 10, 1 }, { 0, 0 }, { 0, 0 }, { 0, 0 }, { 0, 0 } };
static const HlEntry HL_BAR_T[16] = { { 120, 1 }, { 120, 1 }, { 150, 1 }, { 170, 0 }, { 90, 0 }, { 70, 1 }, { 45, 1 }, { 28, 1 },
                                      { 15, 1 }, { 6, 1 }, { 0, 0 }, { 0, 0 }, { 0, 0 }, { 0, 0 }, { 0, 0 }, { 0, 0 } };
static int hlStyle = -1, hlR = -1;
template <class W1>
static void highlight(W1 w1, int x, int y, int w, int h, int r, RGB c, HlStyle st) {
  if (st != hlStyle) {
    const HlEntry *t = st == HL_TILE ? HL_TILE_T : HL_BAR_T;
    for (int k = 0; k < 16; k++) w1(HL_LUT + 4 * k, (uint32_t)t[k].a | (t[k].col ? 0x100u : 0u));
    hlStyle = st;
  }
  if (r != hlR) {
    for (int k = 0; k < 14; k++) { int d = r + k - 3; w1(HL_T + 4 * k, (uint32_t)(d > 0 ? d * d : 0)); }
    hlR = r;
  }
  w1(HL_COL, u24(c));
  w1(HL_POS, ((uint32_t)y << 16) | (uint32_t)x);
  w1(HL_SIZE, ((uint32_t)h << 16) | (uint32_t)w);
  w1(HL_CTL, ((uint32_t)r << 8) | 1u);
}
template <class W1>
static void highlightOff(W1 w1) { w1(HL_CTL, 0); }
static void hlForget() { hlStyle = -1; hlR = -1; }   // (a new bitstream: its table is empty)

// --- to the board ------------------------------------------------------------------------------------
// The screen: paint() makes the list, it goes to the bank not showing, and shows from the next frame.
// (The rectangle is what changed: the board draws the whole picture each frame anyway.) Returns the
// bytes sent.
template <class Paint>
static int render(int, int, int, int, Paint paint, void (*)(uint32_t, uint32_t), void (*)(uint32_t, const uint32_t *, size_t)) {
  if (!ready) return 0;
  objs.clear(); strs.clear();
  paint();
  objs.push_back(uil::mk(uil::T_END, 0, 0, 0, 0, 0, 0, 0, 0));
  // (the list sent before this one, if it has not shown yet, is in the other bank: wait for it --
  // a frame at most)
  uint32_t t0 = millis(), st = rd1 ? rd1(UI_COMMIT) : 0;
  while ((st & 1) && millis() - t0 < 40) { delay(1); st = rd1(UI_COMMIT); }
  uint32_t bank = ((st >> 1) & 1) ^ 1;
  wrN(UI_OBJ + bank * 0x1000, (const uint32_t *)objs.data(), objs.size() * 4);
  if (!strs.empty()) {
    size_t n = (strs.size() + 3) / 4;
    strs.resize(n * 4, '\0');
    wrN(UI_STR + bank * 0x1000, (const uint32_t *)strs.data(), n);
  }
  wr1(UI_COMMIT, 1);
  return (int)(objs.size() * 16 + strs.size());
}
}  // namespace gfx
