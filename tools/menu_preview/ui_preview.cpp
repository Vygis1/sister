// ui_preview.cpp - the menu's pages (esp32/console/screens.h) drawn on the PC with made-up
// data; prints what osd.v would hold: CTRL, the palette, the glyph rows written, the cells.
// tools/menu_preview/ui_preview.py renders it.
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>
#include "../../esp32/console/screens.h"

static uint32_t g_ctrl = 1, g_pal[8];
static uint8_t g_glyph[2048];
static bool g_glyphSet[2048];
static uint32_t g_cells[1200];

int main(int argc, char **argv) {
  std::string which = argc > 1 ? argv[1] : "home";
  int t = argc > 2 ? atoi(argv[2]) : 200;
  ui::hal.cells = [](int first, const uint32_t *v, int n) { for (int i = 0; i < n; i++) g_cells[first + i] = v[i]; };
  ui::hal.reg = [](uint32_t off, uint32_t v) { if (off == 4) g_ctrl = v; else if (off >= 0x40 && off < 0x60) g_pal[(off - 0x40) / 4] = v; };
  ui::hal.glyphRows = [](int first, const uint32_t *rows, int n) { for (int i = 0; i < n; i++) { g_glyph[first + i] = rows[i]; g_glyphSet[first + i] = true; } };
  ui::loadGlyphs();

  scr::Chrome ch; ch.wifiBars = 2; ch.pad1 = true; ch.pad2 = false; ch.running = ""; ch.time = "18:42"; ch.date = "Sat 17 Oct";
  int top = 0;
  bool splash = which == "splash";
  ui::palette(splash ? art::SPLASH_PAL : art::MENU_PAL);
  if (splash) { scr::splash(t); ui::ctrl(5); }
  else ui::ctrl(1);

  using scr::Item;
  if (which == "homenopad") { ch.pad1 = false; which = "home"; }
  std::vector<std::string> homeInfo;
  if (!ch.pad1 && !ch.pad2) homeInfo = { "PS4 / PS5:  hold SHARE + PS", "Xbox:       hold the pair button", "Switch Pro: hold sync" };
  if (which == "ingame") {
    ch.running = "Tony Hawk's Pro Skater";
    std::vector<Item> it;
    auto add = [&](const char *a, uint8_t ic, int ink, const char *v) { Item x; x.text = a; x.icon = ic; x.iconInk = ink; x.value = v; x.valueInk = ui::GREY; it.push_back(x); };
    add("Back to Tony Hawk's Pro Skater", art::G_RIGHT, ui::GREEN, "");
    add("Reset", 0, 0, "");
    add("Settings", art::G_GEAR, ui::YELLOW, "");
    add("Home", art::G_HEART, ui::PINK, "saves, quits the game");
    scr::list(ch, "PAUSED", it, 0, top, {}, "", { { art::G_CROSS, "open" }, { art::G_CIRCLE, "back to the game" } }, 2);
    ui::ctrl(3);
  } else if (which == "home") {
    std::vector<Item> it;
    const char *n[] = { "NES", "Master System", "Mega Drive", "Super NES", "Nintendo 64", "PlayStation" };
    int g[] = { 3, 262, 3, 6, 1, 2 };
    for (int i = 0; i < 6; i++) { Item x; x.text = n[i]; x.value = std::to_string(g[i]) + (g[i] == 1 ? " game" : " games"); x.valueInk = ui::GREY; x.icon = art::G_PAD; x.iconInk = ui::PINK; it.push_back(x); }
    Item s; s.text = "Settings"; s.icon = art::G_GEAR; s.iconInk = ui::YELLOW; s.gap = true; it.push_back(s);
    scr::list(ch, "CONSOLES", it, 3, top, homeInfo, homeInfo.empty() ? "" : "No controller yet: pair one now", { { art::G_CROSS, "open" }, { art::G_TRIANGLE, "settings" } }, 2);
  } else if (which == "games") {
    std::vector<Item> it;
    const char *n[] = { "Super Mario World", "The Legend of Zelda - A Link to the Past", "Super Metroid", "Donkey Kong Country", "F-Zero", "Street Fighter II Turbo", "Chrono Trigger", "Secret of Mana", "Yoshi's Island", "Kirby Super Star", "Mega Man X", "Contra III", "Final Fantasy VI", "EarthBound", "Star Fox", "Pilotwings", "Super Castlevania IV", "Mario Kart", "Tetris Attack", "Harvest Moon", "Breath of Fire", "Axelay" };
    for (auto s : n) { Item x; x.text = s; it.push_back(x); }
    scr::list(ch, "SUPER NES  22 games", it, 4, top, {}, "", { { art::G_CROSS, "play" }, { art::G_CIRCLE, "back" }, { art::G_SQUARE, "L1/R1 page" } });
  } else if (which == "settings") {
    std::vector<Item> it;
    auto add = [&](const char *a, uint8_t ic, int ink, const char *v) { Item x; x.text = a; x.icon = ic; x.iconInk = ink; x.value = v; x.valueInk = ui::GREY; it.push_back(x); };
    add("Picture", art::G_HEART, ui::PINK, "scaling, scanlines");
    add("Wi-Fi", art::G_WIFI3, ui::WHITE, "HomeNet");
    add("Controllers", art::G_PAD, ui::GREEN, "1 connected");
    add("System", art::G_GEAR, ui::YELLOW, "");
    add("About", art::G_TICK, ui::BLUE, "");
    scr::list(ch, "SETTINGS", it, 1, top, { "board: the shell, protocol 2", "SD card: 238 GB, 236 GB free" }, "", { { art::G_CROSS, "open" }, { art::G_CIRCLE, "back" } }, 2);
  } else if (which == "wifi") {
    std::vector<Item> it;
    const char *n[] = { "HomeNet", "HomeNet-5G", "Neighbours", "FRITZ!Box 7590", "Telekom_FON" };
    int b[] = { 3, 3, 2, 1, 0 }; bool lock[] = { true, true, true, true, false };
    for (int i = 0; i < 5; i++) { Item x; x.text = n[i]; x.icon = art::G_WIFI0 + b[i]; x.iconInk = ui::WHITE; if (lock[i]) { x.valueGlyph = art::G_LOCK; } it.push_back(x); }
    Item r; r.text = "Scan again"; r.gap = true; it.push_back(r);
    scr::list(ch, "CHOOSE A NETWORK", it, 0, top, {}, "", { { art::G_CROSS, "connect" }, { art::G_CIRCLE, "back" } });
  } else if (which == "keyboard") {
    scr::keyboard(ch, "PASSWORD FOR HomeNet", "hunter2", false, 0, 1, 4, "");
  } else if (which == "qr") {
    scr::qrPage(ch, "console", "cartridge", "http://192.168.4.1/");
  } else if (which == "tester") {
    scr::PadView a; a.on = true; a.name = "DualSense"; a.battery = 80; a.cross = true; a.l1 = true; a.up = true; a.lx = 100; a.ly = -40; a.rx = 0; a.ry = 0;
    a.circle = a.square = a.triangle = a.r1 = a.l2 = a.r2 = a.sel = a.start = a.home = a.down = a.left = a.right = false;
    scr::PadView b; b.on = false;
    scr::tester(ch, a, b);
  } else if (which == "pairing") {
    scr::pairing(ch, 52, { "DualSense Wireless Controller" }, "");
  } else if (which == "controllers") {
    std::vector<Item> it;
    auto add = [&](const char *a, uint8_t ic, int ink, const char *v, bool gap = false) { Item x; x.text = a; x.icon = ic; x.iconInk = ink; x.value = v; x.valueInk = ui::GREY; x.gap = gap; it.push_back(x); };
    add("Player 1", art::G_PAD, ui::GREEN, "DualSense  80%");
    add("Player 2", art::G_PAD, ui::GREY, "none");
    add("Pair a new controller", art::G_BT, ui::BLUE, "", true);
    add("Test the controllers", art::G_CROSS, ui::BLUE, "");
    add("Button mapping", art::G_SQUARE, ui::PINK, "");
    add("Swap players 1 and 2", art::G_RIGHT, ui::WHITE, "");
    add("Forget paired controllers", art::G_CIRCLE, ui::RED, "");
    scr::list(ch, "CONTROLLERS", it, 2, top, {}, "", { { art::G_CROSS, "open" }, { art::G_CIRCLE, "back" } });
  } else if (which == "message") {
    scr::message(ch, "switching to the Super NES", "about a minute");
  }
  ui::flush();

  printf("%u\n", g_ctrl);
  for (int i = 0; i < 8; i++) printf("%06X\n", g_pal[i]);
  for (int i = 0; i < 2048; i++) printf("%d %02X\n", g_glyphSet[i] ? 1 : 0, g_glyph[i]);
  for (int i = 0; i < 1200; i++) printf("%05X\n", g_cells[i]);
  return 0;
}
