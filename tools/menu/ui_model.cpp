// ui_model.cpp - the reference for rtl/shell_ui.v: a list of things to draw (esp32/console/ui_list.h)
// rendered with the board's own arithmetic, line by line, object by object, and the memories the
// board would hold for it written as hex for sim/tb_shell_ui.v, which compares pixel for pixel.
//
//   g++ -O2 -std=c++17 -Iesp32/console tools/menu/ui_model.cpp -o build/ui_model.exe
//   build/ui_model.exe build/menu_logos build/ui_test     -> expected.ppm, *.hex
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>
#include "gfx_font.h"
#include "ui_list.h"

using namespace uil;
static const gfxfont::Font *FONTS[] = { &gfxfont::F12, &gfxfont::F12B, &gfxfont::F14, &gfxfont::F14B, &gfxfont::F18,
                                        &gfxfont::F18B, &gfxfont::F22B, &gfxfont::F24B, &gfxfont::F30 };
static const int NF = 9;

// --- the board's memories ------------------------------------------------------------------------
static uint32_t objm[2][MAX_OBJ][4];
static uint8_t strm[2][STR_BYTES];
static uint32_t glym[4096][2];
static uint8_t fntm[FONT_BYTES];
static uint16_t imgm[IMG_PIXELS];
static uint8_t ascm[16];

static void loadFonts() {
  uint32_t at = 0;
  for (int f = 0; f < NF; f++) {
    const gfxfont::Font &F = *FONTS[f];
    // the font's pixels: its glyphs' bytes, in order
    uint32_t n = 0;
    for (int g = 0; g < 191; g++) { uint32_t e = F.g[g].at + ((F.g[g].w + 1) / 2) * F.g[g].h; if (e > n) n = e; }
    memcpy(fntm + at, F.px, n);
    for (int g = 0; g < 191; g++) {
      const gfxfont::Glyph &G = F.g[g];
      glym[f * 256 + g][0] = (at + G.at) | ((uint32_t)G.w << 17) | ((uint32_t)G.h << 23);
      glym[f * 256 + g][1] = (uint32_t)G.adv | ((uint32_t)(uint8_t)G.dx << 6) | ((uint32_t)(uint8_t)G.dy << 14);
    }
    ascm[f] = F.ascent;
    at = (at + n + 3) & ~3u;
  }
  fprintf(stderr, "fonts: %u bytes\n", at);
}
struct Img { int w = 0, h = 0; uint32_t at = 0; };
static uint32_t imgAt = 0;
static Img loadImg(const std::string &path) {
  Img im;
  FILE *f = fopen(path.c_str(), "rb");
  if (!f) { fprintf(stderr, "no %s\n", path.c_str()); return im; }
  uint8_t hd[8]; fread(hd, 1, 8, f);
  im.w = hd[4] | (hd[5] << 8); im.h = hd[6] | (hd[7] << 8);
  std::vector<uint8_t> px((size_t)im.w * im.h * 4); fread(px.data(), 1, px.size(), f); fclose(f);
  im.at = imgAt;
  for (int i = 0; i < im.w * im.h; i++) {
    uint8_t *p = &px[i * 4];
    imgm[imgAt + i] = (uint16_t)(((p[0] * 15 + 127) / 255) << 12 | ((p[1] * 15 + 127) / 255) << 8 | ((p[2] * 15 + 127) / 255) << 4 | ((p[3] * 15 + 127) / 255));
  }
  imgAt = (imgAt + im.w * im.h + 1) & ~1u;
  return im;
}

// --- a list, as the menu builds one ---------------------------------------------------------------
static std::vector<Obj> list; static int strAt = 0; static const int BANK = 0;
static int fontOf(const gfxfont::Font *F) { for (int f = 0; f < NF; f++) if (FONTS[f] == F) return f; return 0; }
static int glyphW(const gfxfont::Font &F, uint8_t c) {
  int gi = (c >= 32 && c <= 126) ? c - 32 : (c >= 160) ? c - 65 : 31;
  return F.g[gi].adv;
}
static std::string latin1(const char *s) {
  std::string o;
  while (*s) {
    uint8_t c = (uint8_t)*s++;
    if (c < 0x80) { o += (char)c; continue; }
    int n = (c & 0xE0) == 0xC0 ? 1 : (c & 0xF0) == 0xE0 ? 2 : 3;
    uint32_t cp = c & (0x3F >> n);
    for (int i = 0; i < n && *s; i++) cp = (cp << 6) | (*s++ & 0x3F);
    o += (char)(cp < 256 ? cp : '?');
  }
  return o;
}
static void text(const gfxfont::Font &F, int x, int y, const char *s, uint32_t rgb, int align = 0, int a = 255) {
  std::string t = latin1(s);
  int w = 0; for (uint8_t c : t) w += glyphW(F, c);
  if (align == 1) x -= w / 2; else if (align == 2) x -= w;
  memcpy(&strm[BANK][strAt], t.data(), t.size());
  list.push_back(mk(T_TEXT, x, y, w, F.line, 0, 0, rgb, a, ((uint32_t)fontOf(&F) << 28) | ((uint32_t)t.size() << 20) | (uint32_t)strAt));
  strAt += (int)t.size();
}
static void image(const Img &im, int cx, int cy, int a = 255) {
  list.push_back(mk(T_IMAGE, cx - im.w / 2, cy - im.h / 2, im.w, im.h, 0, 0, 0, a, im.at));
}

// --- the reference renderer -------------------------------------------------------------------------
static uint8_t frame[480][640][3];
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
        int ae = (A * cov) >> 8;
        put(lb, px, col, a9of(ae));
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
            int ae = v == 15 ? A : (A * (v * 17)) >> 8;
            put(lb, pen + dx + xx, col, a9of(ae));
          }
        pen += adv;
      }
    } else if (ty == T_IMAGE) {
      uint32_t base = (w[3] & 0x1FFFF) + (uint32_t)(L - Y) * W;
      for (int xx = 0; xx < W; xx++) {
        uint16_t p = imgm[base + xx];
        int a4 = p & 15; if (!a4) continue;
        uint32_t c = ((uint32_t)((p >> 12) & 15) * 17 << 16) | ((uint32_t)((p >> 8) & 15) * 17 << 8) | (uint32_t)((p >> 4) & 15) * 17;
        int ae = a4 == 15 ? A : (A * (a4 * 17)) >> 8;
        put(lb, X + xx, c, a9of(ae));
      }
    }
  }
}

static void hex32(const std::string &path, const uint32_t *v, size_t n) {
  FILE *f = fopen(path.c_str(), "w"); for (size_t i = 0; i < n; i++) fprintf(f, "%08x\n", v[i]); fclose(f);
}
static void hex8(const std::string &path, const uint8_t *v, size_t n) {
  FILE *f = fopen(path.c_str(), "w"); for (size_t i = 0; i < n; i++) fprintf(f, "%02x\n", v[i]); fclose(f);
}

int main(int argc, char **argv) {
  std::string logos = argc > 1 ? argv[1] : "build/menu_logos", out = argc > 2 ? argv[2] : "build/ui_test";
  loadFonts();
  // the home screen, roughly as the menu draws it
  const char *keys[] = { "nes", "snes", "n64", "gb", "gba", "sms", "md", "gg", "pce", "ps1" };
  const char *names[] = { "NES", "Super NES", "Nintendo 64", "Game Boy", "GB Advance", "Master System", "Mega Drive", "Game Gear", "PC Engine", "PlayStation" };
  uint32_t cols[] = { 0xD7373C, 0x7D64D2, 0x28A05A, 0x82AF32, 0x5064EB, 0xD23C46, 0x3278DC, 0x5A5A6E, 0xEB8723, 0x969BB4 };
  Img logo[10], pad[10];
  for (int i = 0; i < 10; i++) { logo[i] = loadImg(logos + "/" + keys[i] + "_logo.lgo"); pad[i] = loadImg(logos + "/" + keys[i] + "_pad.lgo"); }
  list.push_back(mk(T_BG, 0, 0, 640, 480, 0, 0, 0x463CA0, 255));
  text(gfxfont::F24B, 28, 14, "FPGA CONSOLE", 0xFFFFFF);
  text(gfxfont::F30, 612, 6, "18:42", 0xFFFFFF, 2);
  text(gfxfont::F12, 612, 46, "Sat 17 Oct", 0x7880A5, 2);
  list.push_back(mk(T_RECT, 24, 78, 592, 64, 16, 0, 0x5064EB, 70));
  list.push_back(mk(T_LINE, 24, 78, 592, 64, 16, 1, 0x8CA0FF, 110));
  list.push_back(mk(T_RECT, 38, 88, 96, 44, 10, 0, 0xF6F7FB, 255));
  image(logo[4], 86, 110);
  text(gfxfont::F12B, 150, 86, "CONTINUE", 0xBEC8FF);
  text(gfxfont::F22B, 150, 102, "Pok\xC3\xA9mon Emerald", 0xFFFFFF);
  text(gfxfont::F12, 600, 104, "GB Advance \xC2\xB7 today 18:20", 0xBEC8FF, 2);
  for (int i = 0; i < 10; i++) {
    int cx = 24 + (i % 5) * 117, cy = 156 + (i / 5) * 140;
    list.push_back(mk(T_RECT, cx, cy, 108, 128, 14, 0, 0xE2E5EE, 255));
    list.push_back(mk(T_RECT, cx, cy + 98, 108, 30, 14, 0, cols[i], 255));
    list.push_back(mk(T_RECT, cx, cy + 98, 108, 14, 0, 0, cols[i], 255));
    char n[16]; snprintf(n, sizeof(n), "%d games", 2 + i);
    text(gfxfont::F12B, cx + 54, cy + 104, n, 0xFFFFFF, 1);
    image(logo[i], cx + 54, cy + 26);
    image(pad[i], cx + 54, cy + 68);
  }
  text(gfxfont::F14, 54, 451, "Open", 0xAAB2D4);
  text(gfxfont::F14, 150, 451, "Settings", 0xAAB2D4);
  list.push_back(mk(T_END, 0, 0, 0, 0, 0, 0, 0, 0));
  for (size_t i = 0; i < list.size(); i++) for (int k = 0; k < 4; k++) objm[BANK][i][k] = list[i].w[k];
  fprintf(stderr, "%zu objects, %d string bytes, %u image pixels\n", list.size(), strAt, imgAt);

  for (int L = 0; L < 480; L++) renderLine(L, BANK, frame[L]);
  std::string pp = out + "/expected.ppm";
  FILE *f = fopen(pp.c_str(), "wb"); fprintf(f, "P6\n640 480\n255\n"); fwrite(frame, 1, sizeof(frame), f); fclose(f);
  // the memories, as sim/tb_shell_ui.v loads them
  uint32_t lane[4][512];
  for (int k = 0; k < 4; k++) for (int b = 0; b < 2; b++) for (int i = 0; i < 256; i++) lane[k][b * 256 + i] = objm[b][i][k];
  for (int k = 0; k < 4; k++) hex32(out + "/obj" + std::to_string(k) + ".hex", lane[k], 512);
  uint8_t sl[4][2048];
  for (int b = 0; b < 2; b++) for (int a = 0; a < 4096; a++) sl[a & 3][b * 1024 + (a >> 2)] = strm[b][a];
  for (int k = 0; k < 4; k++) hex8(out + "/str" + std::to_string(k) + ".hex", sl[k], 2048);
  uint32_t g0[4096], g1[4096];
  for (int i = 0; i < 4096; i++) { g0[i] = glym[i][0]; g1[i] = glym[i][1]; }
  hex32(out + "/gly0.hex", g0, 4096); hex32(out + "/gly1.hex", g1, 4096);
  hex32(out + "/fnt.hex", (const uint32_t *)fntm, FONT_BYTES / 4);
  hex32(out + "/img.hex", (const uint32_t *)imgm, IMG_PIXELS / 2);
  hex8(out + "/asc.hex", ascm, 16);
  fprintf(stderr, "%s\n", pp.c_str());
  return 0;
}
