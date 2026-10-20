// card.h - the SD card, through whichever way it mounted: the T8's slot is wired to the ESP32's
// own SD bus (SDMMC slot 1: CLK 14, CMD 15, D0 2, D3 13 -- the pins the SPI driver used), and in
// that bus's one-bit mode the card reads with DMA and far less overhead per block than SPI's
// (measured 944 kB/s over SPI at 20 MHz). SPI stays the fallback: a card is in SPI mode from
// the first SPI command until its power goes, so after a firmware that used SPI it takes one
// power cycle before the SD bus can have it.
//
// Every SD.xxx in the firmware lands here (the #define below): the same calls either way.
#pragma once
#include <SD.h>
#include <SD_MMC.h>

class CardFS {
public:
  bool mmc = false;                 // mounted on the SD bus (else SPI)
  uint32_t mmcKhz = 0;
  fs::FS &fs() { return mmc ? static_cast<fs::FS &>(SD_MMC) : static_cast<fs::FS &>(::SD); }

  bool begin(uint8_t cs, SPIClass &spi, uint32_t hz) { mmc = false; return ::SD.begin(cs, spi, hz); }
  // the SD bus, one bit wide (the slot wires no D1/D2): 40 MHz if the card takes it, else 20
  bool beginMMC() {
    pinMode(13, INPUT_PULLUP);      // D3 high: the card answers in SD mode
    if (SD_MMC.begin("/sdcard", true, false, SDMMC_FREQ_HIGHSPEED)) { mmc = true; mmcKhz = SDMMC_FREQ_HIGHSPEED; return true; }
    SD_MMC.end();
    if (SD_MMC.begin("/sdcard", true, false, SDMMC_FREQ_DEFAULT)) { mmc = true; mmcKhz = SDMMC_FREQ_DEFAULT; return true; }
    SD_MMC.end();
    return false;
  }
  void end() { if (mmc) SD_MMC.end(); else ::SD.end(); mmc = false; }

  File open(const char *p, const char *mode = FILE_READ, bool create = false) { return fs().open(p, mode, create); }
  File open(const String &p, const char *mode = FILE_READ, bool create = false) { return fs().open(p, mode, create); }
  bool exists(const char *p) { return fs().exists(p); }
  bool exists(const String &p) { return fs().exists(p); }
  bool mkdir(const char *p) { return fs().mkdir(p); }
  bool mkdir(const String &p) { return fs().mkdir(p); }
  bool remove(const char *p) { return fs().remove(p); }
  bool remove(const String &p) { return fs().remove(p); }
  bool rmdir(const char *p) { return fs().rmdir(p); }
  bool rmdir(const String &p) { return fs().rmdir(p); }
  bool rename(const char *a, const char *b) { return fs().rename(a, b); }
  bool rename(const String &a, const String &b) { return fs().rename(a, b); }
  uint64_t totalBytes() { return mmc ? SD_MMC.totalBytes() : ::SD.totalBytes(); }
  uint64_t usedBytes() { return mmc ? SD_MMC.usedBytes() : ::SD.usedBytes(); }
  uint64_t cardSize() { return mmc ? SD_MMC.cardSize() : ::SD.cardSize(); }
};
static CardFS Card;
#define SD Card
