// gfx_preview.cpp - the graphical menu's screens (esp32/console/gfxmenu.h and gfx.h: the firmware's
// own code) drawn on the PC with made-up data: the lists and the fonts and images they send go to
// a model of the board (tools/menu/ui_ref.h: rtl/shell_ui.v's bus and its reference renderer),
// and each screen is written as the board would show it.
//
//   g++ -O2 -std=c++17 -Itools/menu/shim -Itools/menu -Iesp32/console -DGFX_CARD="\"build\"" \
//       tools/menu/gfx_preview.cpp -o build/gfx_preview.exe && build/gfx_preview.exe build
//   -> build/gfx_home.ppm, gfx_games.ppm, gfx_settings.ppm, gfx_message.ppm
#include "gfxmenu.h"
#include "ui_ref.h"

using namespace gscr;

static void w1(uint32_t a, uint32_t v) { uiref::busWrite(a, v); }
static void wN(uint32_t a, const uint32_t *w, size_t n) { for (size_t i = 0; i < n; i++) uiref::busWrite(a + 4 * (uint32_t)i, w[i]); }
static uint32_t r1(uint32_t a) { return uiref::busRead(a); }
static uint8_t pic[480][640][3];
static void save(const char *dir, const char *name) {
  uiref::frame(pic);
  std::string p = std::string(dir) + "/" + name;
  FILE *f = fopen(p.c_str(), "wb");
  fprintf(f, "P6\n%d %d\n255\n", 640, 480);
  fwrite(pic, 1, sizeof(pic), f);
  fclose(f);
  printf("%s: %zu objects, %zu string bytes\n", p.c_str(), gfx::objs.size(), gfx::strs.size());
}
#define SHOT(name, ...) do { gfx::render(0, 0, 640, 480, [&] { __VA_ARGS__; }, w1, wN); save(dir, name); } while (0)

int main(int argc, char **argv) {
  const char *dir = argc > 1 ? argv[1] : ".";
  gfx::link(w1, wN, r1);
  gfx::begin();
  Top t; t.title = "FPGA CONSOLE"; t.time = "18:42"; t.date = "Sat 17 Oct"; t.gear = true;
  struct { const char *n, *k; RGB c; int g; } sys[] = {
    { "NES", "nes", { 215, 55, 60 }, 12 }, { "Super NES", "snes", { 125, 100, 210 }, 8 }, { "Nintendo 64", "n64", { 40, 160, 90 }, 3 },
    { "Game Boy", "gb", { 130, 175, 50 }, 9 }, { "GB Advance", "gba", { 80, 100, 235 }, 6 }, { "Master System", "sms", { 210, 60, 70 }, 4 },
    { "Mega Drive", "md", { 50, 120, 220 }, 7 }, { "Game Gear", "gg", { 90, 90, 110 }, 2 }, { "PC Engine", "pce", { 235, 135, 35 }, 2 },
    { "PlayStation", "ps1", { 150, 155, 180 }, 5 } };
  HomeView v; v.top = t;
  v.cont.on = true; v.cont.m = 10; v.cont.key = "gba"; v.cont.console = "GB Advance"; v.cont.game = "Celeste Classic"; v.cont.when = "today 18:20";
  for (int i = 0; i < 10; i++) v.tiles.push_back({ i, sys[i].n, sys[i].k, sys[i].c, sys[i].g });
  v.sel = 4;
  v.hints = { { S_CROSS, "Open" }, { S_TRIANGLE, "Settings" } };
  SHOT("gfx_home.ppm", homeScreen(v, { 70, 60, 160 }));

  ListView g; g.top = t; g.top.title = "GB Advance"; g.top.crumbs = "Home  >  GB Advance"; g.top.gear = false;
  g.badges = true; g.accent = { 80, 100, 235 };
  const char *names[] = { "Celeste Classic", "Tonc: Brinstar demo", "Tonc: Mode 7", "Tonc: Sprites", "Tonc: Windows", "Tonc: Blending", "jsmolka ARM test", "jsmolka Thumb test" };
  for (auto n : names) { Row r; r.text = n; g.rows.push_back(r); }
  g.rows[0].sub = "last played today 18:20"; g.rows[0].tag = "SAVE";
  g.sel = 0; g.first = 0;
  g.hints = { { S_CROSS, "Play" }, { S_CIRCLE, "Back" }, { S_L1R1, "Page" } };
  SHOT("gfx_games.ppm", listPage(g));

  ListView s; s.top = t; s.top.title = "Picture"; s.top.crumbs = "Home  >  Settings  >  Picture"; s.top.gear = false; s.accent = { 60, 120, 140 };
  const char *k[][2] = { { "Scaling", "integer" }, { "Scanlines", "off" }, { "Smoothing", "on" }, { "Colour", "vivid" } };
  for (auto &x : k) { Row r; r.text = x[0]; r.value = x[1]; s.rows.push_back(r); }
  s.info = { "left / right or cross change it; at once" };
  s.sel = 1;
  s.hints = { { S_CROSS, "Change" }, { S_CIRCLE, "Back" } };
  SHOT("gfx_settings.ppm", listPage(s));

  Top tm = t; tm.gear = false;
  SHOT("gfx_message.ppm", messageScreen(tm, "starting Celeste Classic", "GB Advance", { 80, 100, 235 }, 10, "gba"));
  return 0;
}
