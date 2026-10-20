// ui_ref.h - the board's menu picture on the PC: rtl/shell_ui.v's memories, its bus (the ESP32's
// writes decoded as the board decodes them), and the reference renderer (ui_list.h's arithmetic,
// line by line, object by object). tools/menu/ui_model.cpp checks the RTL against it;
// tools/menu/gfx_preview.cpp runs the menu's own drawing code (gfx.h, gfxmenu.h) into it.
#pragma once
#include <cstdint>
#include <cstring>
#include "ui_list.h"

namespace uiref {
using namespace uil;

static uint32_t objm[2][MAX_OBJ][4];
static uint8_t strm[2][STR_BYTES];
static uint32_t glym[4096][2];
static uint8_t fntm[FONT_BYTES];
static uint16_t imgm[IMG_PIXELS];
static uint8_t ascm[16];
static int front = 0; static bool pending = false, on = false;

// --- the bus (pages 9-F, as shell_ui.v) ---------------------------------------------------------------
static void busWrite(uint32_t a, uint32_t v) {
  uint32_t pg = (a >> 16) & 15, off = a & 0xFFFF;
  if (pg == 9) {
    if (off == 0x0004) on = v & 1;
    if (off == 0x0008) pending = true;
    if ((off >> 6) == 0x004) ascm[(off >> 2) & 15] = (uint8_t)v;
  } else if (pg == 10) {
    if ((off >> 14) == 0) objm[(off >> 12) & 1][(off >> 4) & 255][(off >> 2) & 3] = v;
    else if ((off >> 14) == 1) { for (int k = 0; k < 4; k++) strm[(off >> 12) & 1][((off & 0xFFF) & ~3u) + k] = (uint8_t)(v >> (8 * k)); }
    else glym[(off >> 3) & 4095][(off >> 2) & 1] = v;
  } else if (pg == 11 || pg == 12) {
    uint32_t b = ((pg - 11) << 16) | (off & ~3u);
    for (int k = 0; k < 4; k++) fntm[b + k] = (uint8_t)(v >> (8 * k));
  } else if (pg >= 13) {
    uint32_t p = (((pg - 13) << 16) | (off & ~3u)) / 2;
    if (p + 1 < (uint32_t)IMG_PIXELS) { imgm[p] = (uint16_t)v; imgm[p + 1] = (uint16_t)(v >> 16); }
  }
}
static uint32_t busRead(uint32_t a) {
  if ((a & 0xFFFFF) == 0x90008) return ((uint32_t)front << 1) | (pending ? 1 : 0);
  if ((a & 0xFFFFF) == 0x90000) return 0x55493031;
  return 0;
}

// --- the renderer -----------------------------------------------------------------------------------
static void put(uint8_t lb[640][3], int x, uint32_t c, int a9) {
  if (x < 0 || x >= 640 || a9 <= 0) return;
  lb[x][0] = blend(lb[x][0], (uint8_t)(c >> 16), a9); lb[x][1] = blend(lb[x][1], (uint8_t)(c >> 8), a9); lb[x][2] = blend(lb[x][2], (uint8_t)c, a9);
}
static void renderLine(int L, int bank, uint8_t lb[640][3]) {
  for (int i = 0; i < MAX_OBJ; i++) {
    const uint32_t *w = objm[bank][i];
    int ty = w[0] >> 28; if (ty == T_END) break;
    int X = w[0] & 1023, Y = (w[0] >> 16) & 1023, W = w[1] & 1023, Hh = (w[1] >> 10) & 1023, R = (w[1] >> 23) & 31, T = (w[1] >> 20) & 7;
    uint32_t col = w[2] & 0xFFFFFF; int A = w[2] >> 24;
    if (ty == T_BG) { for (int x = 0; x < 640; x++) bgPixel(x, L, col, lb[x]); continue; }
    if (L < Y || L >= Y + Hh) continue;
    if (ty == T_RECT || ty == T_LINE) {
      for (int px = X; px < X + W; px++) {
        int cov = cover(px, L, X, Y, W, Hh, R);
        if (ty == T_LINE) {
          int iw = W > 2 * T ? W - 2 * T : 0, ih = Hh > 2 * T ? Hh - 2 * T : 0, ir = R > T ? R - T : 0;
          int ci = (iw && ih) ? cover(px, L, X + T, Y + T, iw, ih, ir) : 0;
          cov = cov > ci ? cov - ci : 0;
        }
        if (!cov) continue;
        put(lb, px, col, a9of((A * cov) >> 8));
      }
    } else if (ty == T_TEXT) {
      int f = w[3] >> 28, n = (w[3] >> 20) & 255, sa = w[3] & 0x1FFF, pen = X;
      for (int c = 0; c < n; c++) {
        uint8_t ch = strm[bank][(sa + c) & 4095];
        int gi = (ch >= 32 && ch <= 126) ? ch - 32 : (ch >= 160) ? ch - 65 : 31;
        uint32_t g0 = glym[f * 256 + gi][0], g1 = glym[f * 256 + gi][1];
        int at = g0 & 0x1FFFF, gw = (g0 >> 17) & 63, gh = (g0 >> 23) & 63, adv = g1 & 63, dx = (int8_t)((g1 >> 6) & 255), dy = (int8_t)((g1 >> 14) & 255);
        int gy0 = Y + ascm[f] + dy, row = L - gy0, rb = (gw + 1) / 2;
        if (row >= 0 && row < gh && gw)
          for (int xx = 0; xx < gw; xx++) {
            uint8_t b = fntm[at + row * rb + xx / 2];
            int v = (xx & 1) ? b >> 4 : b & 15;
            if (!v) continue;
            put(lb, pen + dx + xx, col, a9of(v == 15 ? A : (A * (v * 17)) >> 8));
          }
        pen += adv;
      }
    } else if (ty == T_IMAGE) {
      uint32_t base = (w[3] & 0x1FFFF) + (uint32_t)(L - Y) * W;
      for (int xx = 0; xx < W; xx++) {
        uint16_t p = imgm[base + xx];
        int a4 = p & 15; if (!a4) continue;
        uint32_t c = ((uint32_t)((p >> 12) & 15) * 17 << 16) | ((uint32_t)((p >> 8) & 15) * 17 << 8) | (uint32_t)((p >> 4) & 15) * 17;
        put(lb, X + xx, c, a9of(a4 == 15 ? A : (A * (a4 * 17)) >> 8));
      }
    }
  }
}
// a frame: a waiting list swaps in first, as the board does at line 0
static void frame(uint8_t out[480][640][3]) {
  if (pending) { front ^= 1; pending = false; }
  for (int L = 0; L < 480; L++) renderLine(L, front, out[L]);
}
}  // namespace uiref
