// shim: the card is a folder (GFX_CARD: /menu/logos -> GFX_CARD/menu_logos, /menu/icons -> GFX_CARD/menu_icons)
#pragma once
#include <cstdio>
#include <string>
class File {
 public:
  FILE *f = nullptr;
  explicit operator bool() const { return f != nullptr; }
  int read(uint8_t *b, size_t n) { return f ? (int)fread(b, 1, n, f) : 0; }
  void close() { if (f) fclose(f); f = nullptr; }
};
struct SDCard {
  File open(const char *p) {
    std::string s = p; const std::string pre = "/menu/logos/", pre2 = "/menu/icons/";
    if (s.rfind(pre, 0) == 0) s = std::string(GFX_CARD) + "/menu_logos/" + s.substr(pre.size());
    else if (s.rfind(pre2, 0) == 0) s = std::string(GFX_CARD) + "/menu_icons/" + s.substr(pre2.size());
    File x; x.f = fopen(s.c_str(), "rb"); return x;
  }
};
static SDCard SD;
