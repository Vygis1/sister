// gfxmenu.h - the graphical menu's screens (the board in its menu image with a picture:
// rtl/shell_fb.v), from plain data as screens.h's are: menu.h gathers what a page shows and
// calls these, they draw into gfx.h's picture. The look: build/menu_home_logos.png (the
// mock-up it was agreed from, 2026-10-17).

#pragma once
#include <string>
#include <vector>
#include "gfx.h"

namespace gscr {
using namespace gfx;
using namespace gfxfont;

static const RGB WHITE = { 255, 255, 255 }, DIM = { 170, 178, 212 }, FAINT = { 120, 128, 165 }, ROW = { 205, 210, 235 },
                 SOFT = { 190, 200, 255 }, GREEN = { 150, 230, 170 }, TILE = { 226, 229, 238 }, TILE_ON = { 246, 247, 251 };

// --- the consoles' art from the card (/menu/logos: tools/menu/mklogos.py), loaded once -------------
struct Art { gfx::Image logo, pad; bool tried = false; };
static Art art[16];
static Art &artOf(int m, const char *key) {
  Art &a = art[m & 15];
  if (!a.tried) {
    a.tried = true;
    std::string b = std::string("/menu/logos/") + key;
    a.logo = gfx::loadImage((b + "_logo.lgo").c_str());
    a.pad = gfx::loadImage((b + "_pad.lgo").c_str());
  }
  return a;
}
static void forgetArt() { for (auto &a : art) a.tried = false; }   // (the card changed: look again)

// --- what every page has: the title, where you are, the clock, the button hints ------------------
struct Top { std::string title, crumbs, time, date; bool gear = false; };
static void top(const Top &t) {
  text(F24B, 28, 14, t.title.c_str(), WHITE);
  if (!t.crumbs.empty()) text(F12, 30, 46, t.crumbs.c_str(), FAINT);
  text(F30, W - 28, 6, t.time.c_str(), WHITE, RIGHT);
  text(F12, W - 28, 46, t.date.c_str(), FAINT, RIGHT);
  if (t.gear) gear(W - 28 - textWidth(F30, t.time.c_str()) - 30, 30, 11, { 200, 205, 230 });
}
struct Hint { Sym s; std::string what; };
static void hints(const std::vector<Hint> &h, const std::string &note = "") {
  int x = 28;
  for (auto &k : h) {
    buttonSym(k.s, x + 10, 460);
    text(F14, x + 26, 451, k.what.c_str(), DIM);
    x += 26 + textWidth(F14, k.what.c_str()) + 26;
  }
  if (!note.empty()) text(F14, W - 28, 451, fit(F14, note, W - 56 - x).c_str(), SOFT, RIGHT);
}

// --- home: the game to carry on with, and the consoles -------------------------------------------
struct Tile { int m; std::string name, key; RGB colour; int games; };
struct Continue { bool on = false; int m = -1; std::string game, key, console, when; };
struct HomeView {
  Top top; Continue cont; std::vector<Tile> tiles;
  int sel = 0;                      // -1: the continue card; else a tile
  int firstRow = 0;                 // the grid's top row (more than two rows scroll)
  std::vector<std::string> lines;   // (no tiles: what to do instead)
  std::vector<Hint> hints; std::string note;
};
static void homeScreen(const HomeView &v, RGB accent) {
  background(accent);
  top(v.top);
  // the card: the game last played
  int gy = 82;
  if (v.cont.on) {
    rrect(24, 78, 592, 64, 16, { 80, 100, 235 }, 70);
    rrectLine(24, 78, 592, 64, 16, RGB{ 140, 160, 255 }, 110, 1);
    rrect(38, 88, 96, 44, 10, TILE_ON);
    Art &a = artOf(v.cont.m, v.cont.key.c_str());
    if (a.logo.px) image(a.logo, 86, 110); else text(F12B, 86, 102, v.cont.console.c_str(), { 60, 70, 120 }, CENTRE);
    text(F12B, 150, 86, "CONTINUE", SOFT);
    text(F22B, 150, 102, fit(F22B, v.cont.game, 260).c_str(), WHITE);
    text(F12, 600, 104, (v.cont.console + (v.cont.when.empty() ? "" : "  \xC2\xB7  " + v.cont.when)).c_str(), SOFT, RIGHT);
    gy = 156;
  }
  if (v.tiles.empty()) {
    int y = gy + 30;
    for (auto &l : v.lines) { text(F18, W / 2, y, l.c_str(), DIM, CENTRE); y += 30; }
  }
  // the grid: five across, tiles 108 x 128 (two rows show; more scroll)
  const int tw = 108, th = 128, gx = 9, gyy = 12, x0 = 24;
  int rows = v.cont.on ? 2 : 2;
  for (size_t i = 0; i < v.tiles.size(); i++) {
    int r = (int)i / 5 - v.firstRow;
    if (r < 0 || r >= rows) continue;
    const Tile &t = v.tiles[i];
    int cx = x0 + (int)(i % 5) * (tw + gx), cy = gy + r * (th + gyy);
    rrect(cx, cy, tw, th, 14, TILE);
    // the band at the foot: the console's colour, the count
    rrect(cx, cy + th - 30, tw, 30, 14, t.colour);
    fill(cx, cy + th - 30, tw, 14, t.colour);
    std::string n = std::to_string(t.games) + (t.games == 1 ? " game" : " games");
    text(F12B, cx + tw / 2, cy + th - 24, n.c_str(), WHITE, CENTRE);
    Art &a = artOf(t.m, t.key.c_str());
    if (a.logo.px) image(a.logo, cx + tw / 2, cy + 26);
    else text(F14B, cx + tw / 2, cy + 18, fit(F14B, t.name, tw - 10).c_str(), t.colour, CENTRE);
    if (a.pad.px) image(a.pad, cx + tw / 2, cy + 68);
  }
  // more rows than show: a hint at the side
  int nrows = ((int)v.tiles.size() + 4) / 5;
  if (nrows > rows) {
    for (int r = 0; r < nrows; r++)
      disc(W - 12, gy + 100 + r * 14, r >= v.firstRow && r < v.firstRow + rows ? 3.5f : 2.5f,
           r >= v.firstRow && r < v.firstRow + rows ? WHITE : FAINT);
  }
  hints(v.hints, v.note);
}

// --- a list: a console's games, a settings page ----------------------------------------------------
struct Row { std::string text, sub, value, tag; RGB tagInk = GREEN; bool gap = false; };
struct ListView {
  Top top; std::vector<Row> rows; int sel = 0, first = 0;
  bool badges = false;              // the games' initials in a square at the left
  RGB accent = { 80, 100, 235 };
  std::vector<std::string> info;    // lines under the list
  std::vector<Hint> hints; std::string note;
};
static const int LIST_Y = 82, LIST_ROW = 56, LIST_ROWS = 6;
static int listRows(const ListView &v) { return v.info.empty() ? LIST_ROWS : LIST_ROWS - 1; }
static void listScreen(const ListView &v) {
  int shown = listRows(v);
  for (int i = 0; i < shown && v.first + i < (int)v.rows.size(); i++) {
    const Row &r = v.rows[v.first + i];
    int y = LIST_Y + i * LIST_ROW;
    const bool on = false;                         // (the selection is the board's highlight)
    rrect(24, y, 592, 48, 12, WHITE, 14);
    int tx = 40;
    if (v.badges) {
      rrect(36, y + 10, 28, 28, 7, on ? RGB{ 255, 255, 255 } : WHITE, on ? 60 : 30);
      const char *p = r.text.c_str();
      uint32_t cp = nextCp(p);
      char ini[8] = {0};
      if (cp < 0x80) { ini[0] = (char)toupper((int)cp); }
      else { size_t k = p - r.text.c_str(); memcpy(ini, r.text.c_str(), min((size_t)7, k)); }
      text(F14B, 50, y + 14, ini, WHITE, CENTRE);
      tx = 78;
    }
    int right = 600;
    if (!r.tag.empty()) { int w = text(F12B, right, y + 17, r.tag.c_str(), r.tagInk, RIGHT); right -= w + 14; }
    if (!r.value.empty()) { int w = text(F18, right, y + 13, r.value.c_str(), on ? WHITE : SOFT, RIGHT); right -= w + 16; }
    std::string t = fit(on ? F18B : F18, r.text, right - tx - 8);
    if (r.sub.empty()) text(on ? F18B : F18, tx, y + 13, t.c_str(), on ? WHITE : ROW);
    else {
      text(on ? F18B : F18, tx, y + 5, t.c_str(), on ? WHITE : ROW);
      text(F12, tx, y + 28, r.sub.c_str(), SOFT);
    }
  }
  // the scroll bar
  if ((int)v.rows.size() > shown) {
    int h = shown * LIST_ROW - 8, bh = max(24, h * shown / (int)v.rows.size());
    int by = LIST_Y + (h - bh) * v.first / max(1, (int)v.rows.size() - shown);
    rrect(622, LIST_Y, 6, h, 3, WHITE, 20);
    rrect(622, by, 6, bh, 3, WHITE, 120);
  }
  int y = LIST_Y + shown * LIST_ROW + 4;
  for (auto &l : v.info) { text(F14, 40, y, l.c_str(), DIM); y += 20; }
  hints(v.hints, v.note);
}
static void listPage(const ListView &v) {
  background(v.accent);
  top(v.top);
  listScreen(v);
}

// --- a message: what is happening (a game loading, the board switching) --------------------------
static void messageScreen(const Top &t, const std::string &a, const std::string &b, RGB accent, int m = -1, const char *key = nullptr,
                          float progress = -1) {
  background(accent);
  top(t);
  rrect(70, 150, 500, 180, 18, WHITE, 16);
  rrectLine(70, 150, 500, 180, 18, WHITE, 40);
  int y = 200;
  if (key) {
    Art &ar = artOf(m, key);
    if (ar.logo.px) { rrect(W / 2 - 60, 172, 120, 52, 12, TILE_ON); image(ar.logo, W / 2, 198); y = 246; }
  }
  text(F22B, W / 2, y, a.c_str(), WHITE, CENTRE);
  if (!b.empty()) text(F14, W / 2, y + 36, b.c_str(), DIM, CENTRE);
  // (a core going in: the bar, as the shell's own screen draws it)
  if (progress >= 0) {
    int w = (int)(420 * (progress > 1 ? 1 : progress));
    rrect(110, 300, 420, 10, 5, WHITE, 30);
    if (w >= 10) rrect(110, 300, w, 10, 5, RGB{ 80, 100, 235 });
  }
}
}  // namespace gscr
