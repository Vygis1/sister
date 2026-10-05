// preview.cpp - the menu's own drawing code (esp32/console/menu.h, its screen and
// draw() parts, cut out by tools/menu_preview/preview.py) compiled on the PC against
// a stand-in for Arduino's String and the FPGA link; prints the 40 x 30 cells it
// would send, for preview.py to render as osd.v draws them.
#include <string>
#include <vector>
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <algorithm>

struct String {
  std::string s;
  String() {}
  String(const char *c) : s(c ? c : "") {}
  String(const std::string &x) : s(x) {}
  String(char c) : s(1, c) {}
  String(int v) : s(std::to_string(v)) {}
  String(unsigned v) : s(std::to_string(v)) {}
  String(long v) : s(std::to_string(v)) {}
  String(unsigned long v) : s(std::to_string(v)) {}
  String(unsigned long long v) : s(std::to_string(v)) {}
  unsigned length() const { return s.size(); }
  char operator[](unsigned i) const { return s[i]; }
  String substring(unsigned a) const { return s.substr(a); }
  String substring(unsigned a, unsigned b) const { return s.substr(a, b - a); }
  String operator+(const String &o) const { return s + o.s; }
  String operator+(const char *o) const { return s + o; }
  String operator+(int v) const { return s + std::to_string(v); }
  String operator+(unsigned v) const { return s + std::to_string(v); }
  String operator+(size_t v) const { return s + std::to_string(v); }
  String &operator+=(const String &o) { s += o.s; return *this; }
  bool operator==(const char *o) const { return s == o; }
};
static String operator+(const char *a, const String &b) { return String(a) + b; }

struct Status { bool alive; uint8_t version, core; bool busy; };
struct Fpga {
  uint8_t core = 'S';
  uint32_t cells[1200];
  Status status() { return Status{ true, 1, core, false }; }
  void busWrite(uint32_t a, const uint32_t *w, size_t n) { if (a == 0x00072000) memcpy(cells, w, n * 4); }
  void busWrite(uint32_t, uint32_t) {}
} fpga;
static bool haveCard = true;

struct Machine { const char *name, *core; uint8_t id; uint32_t limit; };
static const Machine MACHINES[] = {
  { "NES", "nes", 'N', 0 }, { "Master System", "sms", 'S', 0 }, { "Mega Drive", "md", 'M', 0 },
  { "Nintendo 64", "n64", '6', 0 }, { "PlayStation", "ps1", 'P', 0 },
};
static const int NMACH = 5;
static int machineOfCore(uint8_t id) { for (int i = 0; i < NMACH; i++) if (MACHINES[i].id == id) return i; return -1; }
static const uint32_t OSD_CELLS = 0x00072000, OSD_CTRL = 0x00070004;
struct Game { String path, name; int8_t m; uint32_t size; };
static std::vector<Game> lists[NMACH];
static std::vector<int> consoles;

#include "cut.h"

int main(int argc, char **argv) {
  const char *names[] = { "Alex Kidd in Miracle World (USA) (Rev-A)", "After Burner (USA)", "Alien Syndrome (USA)",
    "Altered Beast (USA)", "Battletoads in Battlemaniacs (Brazil)", "California Games (USA, Europe)",
    "Castle of Illusion Starring Mickey Mouse (USA, Europe)", "Columns (USA, Europe)", "Double Dragon (USA, Europe)",
    "Fantasy Zone (USA)", "Golden Axe (USA, Europe)", "Hang-On (USA, Europe)", "Kenseiden (USA, Europe)",
    "Lord of the Sword (USA, Europe)", "Out Run (USA, Europe)", "Phantasy Star (USA, Europe) (Rev-A)",
    "Psycho Fox (USA, Europe)", "R-Type (USA, Europe)", "Shinobi (USA, Europe)", "Sonic The Hedgehog (USA, Europe)",
    "Space Harrier (USA, Europe)", "Wonder Boy III - The Dragon's Trap (USA, Europe)", "Ys - The Vanished Omens (USA, Europe)" };
  for (int i = 0; i < 3; i++) lists[0].push_back({ "", "nes game", 0, 0 });
  for (auto n : names) lists[1].push_back({ "", n, 1, 0 });
  for (int i = 0; i < 239; i++) lists[1].push_back({ "", "more", 1, 0 });
  for (int i = 0; i < 3; i++) lists[2].push_back({ "", "md game", 2, 0 });
  lists[3].push_back({ "", "Super Mario 64", 3, 0 });
  for (int i = 0; i < 2; i++) lists[4].push_back({ "", "disc", 4, 0 });
  for (int m = 0; m < NMACH; m++) consoles.push_back(m);
  std::string which = argc > 1 ? argv[1] : "consoles";
  if (which == "consoles") { level = 0; sel = 1; gameIn = true; draw(); }
  else if (which == "games") { level = 1; cur = 1; sel = 4; note = "loaded Alex Kidd in Miracle World"; draw(); }
  else if (which == "message") { message("switching to the Nintendo 64", "this takes about a minute"); }
  for (int i = 0; i < 1200; i++) printf("%03x\n", (unsigned)fpga.cells[i] & 0xFFF);
}
