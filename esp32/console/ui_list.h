// ui_list.h - the menu image's picture as a list of things to draw (rtl/shell_ui.v composes it a
// line at a time as the TV scans; nothing but the list and its assets crosses the link). What
// every object is, its words as the board takes them, and the exact arithmetic the board does --
// ui_ref() below is the reference the RTL is checked against (tools/menu/ui_model.cpp,
// sim/tb_shell_ui.v), pixel for pixel.
//
// An object is four words:
//   w0  [31:28] type  [25:16] y  [9:0] x
//   w1  [27:23] radius  [22:20] thickness  [19:10] height  [9:0] width
//   w2  [31:24] alpha (255: all of it)  [23:0] colour, 0xRRGGBB
//   w3  TEXT: [31:28] font, [27:20] characters, [12:0] where the string starts (bytes)
//       IMAGE: [16:0] its first pixel (images are 16-bit RGBA 4444, a row after another)
// Types: 0 the end; 1 the background (w2: the page's colour; the whole line, write only);
// 2 a rounded rectangle, filled; 3 its outline (thickness pixels); 4 text, its line's top at y
// (height: the font's line); 5 an image.
//
// Fonts: a glyph table (16 fonts x 256 entries, two words: [16:0] where its pixels start, [22:17]
// width, [28:23] height; then [5:0] advance, [13:6] x offset (signed), [21:14] y offset from the
// baseline (signed)) and the pixels (4 bits a pixel, two to a byte, the left in the low nibble,
// rows padded to bytes); each font's ascent in a register.
#pragma once
#include <stdint.h>

namespace uil {

enum Type : uint8_t { T_END = 0, T_BG = 1, T_RECT = 2, T_LINE = 3, T_TEXT = 4, T_IMAGE = 5 };
static const int MAX_OBJ = 256, STR_BYTES = 4096, IMG_PIXELS = 98304, FONT_BYTES = 131072;

struct Obj { uint32_t w[4]; };
static inline Obj mk(Type t, int x, int y, int w, int h, int r, int th, uint32_t rgb, int a, uint32_t w3 = 0) {
  Obj o;
  o.w[0] = ((uint32_t)t << 28) | ((uint32_t)(y & 1023) << 16) | (uint32_t)(x & 1023);
  o.w[1] = ((uint32_t)(r & 31) << 23) | ((uint32_t)(th & 7) << 20) | ((uint32_t)(h & 1023) << 10) | (uint32_t)(w & 1023);
  o.w[2] = ((uint32_t)(a & 255) << 24) | (rgb & 0xFFFFFF);
  o.w[3] = w3;
  return o;
}

// --- the board's arithmetic ----------------------------------------------------------------------
static inline int clamp8(int v) { return v < 0 ? 0 : v > 255 ? 255 : v; }
// a channel: d + (c - d) a / 256, a 0..256
static inline uint8_t blend(uint8_t d, uint8_t c, int a9) { return (uint8_t)(d + ((((int)c - (int)d) * a9) >> 8)); }
static inline int a9of(int a) { return a + (a >> 7); }              // 0..255 -> 0..256
// the background at x on line L, in the page's colour acc
static inline void bgPixel(int x, int L, uint32_t acc, uint8_t out[3]) {
  int t8 = ((480 - L) * 136) >> 8;
  int base[3] = { 13 + ((9 * t8) >> 8), 15 + ((7 * t8) >> 8), 34 + ((18 * t8) >> 8) };
  int dx = x - 90, dy = L + 30;
  int d2 = dx * dx + dy * dy, k = 0;
  if (d2 < 115600) {
    uint32_t s = (uint32_t)(115600 - d2) >> 4;
    k = (int)(((uint64_t)(s * s) * 105) >> 26);
  }
  int a[3] = { (int)(acc >> 16) & 255, (int)(acc >> 8) & 255, (int)acc & 255 };
  for (int c = 0; c < 3; c++) out[c] = (uint8_t)(base[c] + (((a[c] - base[c]) * k) >> 8));
}
// 64 / (2R + 1) in 16 fractional bits (the board's table: no divider)
static inline int invE(int R) { int E = 2 * R + 1; return (64 * 65536 + E / 2) / E; }
// how much of a pixel a rounded rectangle covers: 0..256
static inline int cover(int px, int L, int X, int Y, int W, int H, int R) {
  if (W <= 0 || H <= 0 || px < X || px >= X + W || L < Y || L >= Y + H) return 0;
  int xx = px - X, yy = L - Y;
  int cx = xx < R ? R - xx : (xx >= W - R ? xx - (W - R - 1) : 0);
  int cy = yy < R ? R - yy : (yy >= H - R ? yy - (H - R - 1) : 0);
  if (!cx || !cy) return 256;
  int Dx = 2 * cx - 1, Dy = 2 * cy - 1, E = 2 * R + 1;
  int num = E * E - (Dx * Dx + Dy * Dy);
  if (num <= 0) return 0;
  int v = (int)(((int64_t)num * invE(R)) >> 16);
  return v > 256 ? 256 : v;
}
}  // namespace uil
