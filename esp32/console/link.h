// link.h - the client half of the FPGA protocol in docs/ARCHITECTURE.md.
//
// Every exchange is one chip-select frame: a command byte, then payload. The
// board's reply comes back on MISO in the same frame, one byte behind the byte
// that asked for it -- so a reply is read by clocking an extra byte out, which
// is what `transfer` does anyway.
//
// Byte 0 out is always a fixed signature, sent before the board has been told
// what is wanted. That is the whole trick for bring-up: one byte proves the
// clock arrives, chip select frames the transfer and MISO gets back, without
// the board having to understand anything.

#pragma once
#include <Arduino.h>
#include <SPI.h>

enum : uint8_t {
  CMD_PING         = 0x01,
  CMD_STATUS       = 0x02,
  CMD_FLASH_ERASE  = 0x10,   // one 64 kB sector
  CMD_FLASH_WRITE  = 0x11,   // one 256-byte page
  CMD_FLASH_READ   = 0x12,   // fetch a page into the board's buffer
  CMD_FLASH_PAGE   = 0x13,   // and dump it back
  CMD_BOOT         = 0x20,   // 0 = the shell, 1 = the core
  // the PlayStation console image only (cd_feed.v): its disc comes over this wire
  CMD_CD_STATUS    = 0x30,   // what sector the drive wants next, and how much room it has
  CMD_CD_SECTOR    = 0x31,   // 3 bytes of LBA, then the raw 2352-byte sector
  CMD_CD_DISC      = 0x32,   // 1 byte: 1 = a disc is in the drive, 0 = the tray is empty
  CMD_BUS_WRITE    = 0x40,   // a console image's register bus: address, then words
  CMD_BUS_READ     = 0x41,   // address, 4 bytes while it reads, the word
  CMD_BUS_RDBLK    = 0x42,   // the same, word after word while chip select stays low
};

static const uint8_t CORE_PS1_ID = 0x50;   // 'P': the byte the PlayStation image answers as its core

static const uint8_t LINK_SIGNATURE = 0xA5;

// The flash: the shell keeps the bottom 2 MB and the core gets the other 6.
static const uint32_t SLOT_BASE = 2u * 1024 * 1024;
static const uint32_t SLOT_SIZE = 6u * 1024 * 1024;
static const size_t   PAGE = 256;
static const uint32_t SECTOR = 64u * 1024;

struct Status {
  bool    alive;
  uint8_t version;
  uint8_t core;        // 0 = the shell, otherwise the console id
  bool    busy;
};

struct CdStatus {
  bool     alive;
  uint8_t  core;
  bool     disc;       // the drive believes a disc is in
  bool     running;    // it is reading or seeking: keep the sectors coming
  uint8_t  room;       // how many more sectors it can take now
  uint32_t lba;        // the one it wants next
};

class FpgaLink {
public:
  FpgaLink(SPIClass &bus, int sck, int miso, int mosi, int cs,
           int progB = -1, int done = -1)
    : spi_(bus), sck_(sck), miso_(miso), mosi_(mosi), cs_(cs),
      prog_(progB), done_(done) {}

  void begin(uint32_t hz = 10000000) {
    settings_ = SPISettings(hz, MSBFIRST, SPI_MODE0);
    lock_ = xSemaphoreCreateMutex();
    spi_.begin(sck_, miso_, mosi_, cs_);
    pinMode(cs_, OUTPUT);
    digitalWrite(cs_, HIGH);
    // PROGRAM_B is driven low to reconfigure and released otherwise. Held as an
    // input the rest of the time rather than driven high, so that a reset of
    // this chip cannot hold the FPGA down.
    if (prog_ >= 0) pinMode(prog_, INPUT);
    if (done_ >= 0) pinMode(done_, INPUT);
  }

  // --- the last resort ---------------------------------------------------
  // Restarts configuration from address 0, which is always the shell. This is
  // what makes a bad core survivable without unplugging anything.
  void forceShell() {
    if (prog_ < 0) return;
    pinMode(prog_, OUTPUT);
    digitalWrite(prog_, LOW);
    delayMicroseconds(500);
    pinMode(prog_, INPUT);
    waitForDone(3000);
  }

  bool waitForDone(uint32_t ms) {
    if (done_ < 0) { delay(ms > 1500 ? 1500 : ms); return true; }
    uint32_t t0 = millis();
    while (millis() - t0 < ms) {
      if (digitalRead(done_)) return true;
      delay(1);
    }
    return false;
  }

  // --- the PlayStation's disc --------------------------------------------------
  CdStatus cdStatus() {
    uint8_t rx[10];
    frame(CMD_CD_STATUS, nullptr, 0, rx, sizeof(rx));
    CdStatus s{};
    s.alive   = (rx[0] == LINK_SIGNATURE);
    s.core    = rx[2];
    s.disc    = rx[4] & 1;
    s.running = rx[5] & 1;
    s.room    = rx[6];
    s.lba     = (uint32_t(rx[7]) << 16) | (uint32_t(rx[8]) << 8) | rx[9];
    return s;
  }
  void cdDisc(bool in) { uint8_t v = in ? 1 : 0; frame(CMD_CD_DISC, &v, 1, nullptr, 0); }
  // one raw sector in one frame: the LBA it is, then its 2352 bytes. The board
  // takes it only if it is the LBA it asked for, so a stale one is harmless.
  void cdSector(uint32_t lba, const uint8_t *raw) {
    xSemaphoreTake(lock_, portMAX_DELAY);
    spi_.beginTransaction(settings_);
    digitalWrite(cs_, LOW);
    spi_.transfer(CMD_CD_SECTOR);
    spi_.transfer((lba >> 16) & 0xFF);
    spi_.transfer((lba >> 8) & 0xFF);
    spi_.transfer(lba & 0xFF);
    spi_.writeBytes(raw, 2352);
    digitalWrite(cs_, HIGH);
    spi_.endTransaction();
    xSemaphoreGive(lock_);
  }

  Status status() {
    uint8_t rx[4];
    frame(CMD_STATUS, nullptr, 0, rx, sizeof(rx));
    Status s{};
    s.alive   = (rx[0] == LINK_SIGNATURE);
    s.version = rx[1];
    s.core    = rx[2];
    s.busy    = rx[3] & 1;
    return s;
  }

  bool busy() { return status().busy; }

  bool waitIdle(uint32_t ms) {
    uint32_t t0 = millis();
    while (millis() - t0 < ms) {
      if (!busy()) return true;
      delayMicroseconds(200);
    }
    return false;
  }

  // Wait for an operation that has just been ASKED FOR to finish.
  //
  // Not the same as waitIdle, and the difference cost 91 kB out of the middle
  // of a core image. waitIdle asks "is it busy?" and a board that has been given
  // a command but has not started it yet truthfully answers no -- so the caller
  // concludes the write is done, sends the next page, and the flash controller
  // drops the one still in its hand. Nothing reports an error: every page
  // "succeeds" and a stretch of the image is simply never programmed, reading
  // back as erased.
  //
  // It only appears when the caller can get back around the loop faster than
  // the board can start. Reading the card at 4 MHz was slow enough to hide it;
  // at 20 MHz it lost 365 consecutive pages.
  //
  // So: watch it become busy FIRST, and only then wait for it to stop. A page
  // program is about half a millisecond and a status round trip is about ten
  // microseconds, so busy is always observable. If it never goes busy, the
  // command was not accepted -- which is a failure worth reporting rather than
  // a success worth inventing.
  bool waitDone(uint32_t ms) {
    uint32_t t0 = millis();
    bool started = false;
    while (millis() - t0 < 5) {
      if (busy()) { started = true; break; }
    }
    if (!started) return false;
    return waitIdle(ms);
  }

  // --- the flash ----------------------------------------------------------
  // Erase is one 64 kB sector, so the caller clears exactly what it is about to
  // write. Erasing the whole 6 MB slot would be tidier and spends three minutes
  // clearing space nothing is going to use.
  bool eraseSector(uint32_t offset) {
    uint8_t a[3] = { (uint8_t)(offset >> 16), (uint8_t)(offset >> 8),
                     (uint8_t)offset };
    frame(CMD_FLASH_ERASE, a, sizeof(a), nullptr, 0);
    return waitDone(10000);
  }

  bool writePage(uint32_t offset, const uint8_t *data, size_t n) {
    uint8_t hdr[3] = { (uint8_t)(offset >> 16), (uint8_t)(offset >> 8),
                       (uint8_t)offset };
    xSemaphoreTake(lock_, portMAX_DELAY);
    spi_.beginTransaction(settings_);
    digitalWrite(cs_, LOW);
    spi_.transfer(CMD_FLASH_WRITE);
    for (uint8_t b : hdr) spi_.transfer(b);
    for (size_t i = 0; i < PAGE; i++) spi_.transfer(i < n ? data[i] : 0xFF);
    digitalWrite(cs_, HIGH);
    spi_.endTransaction();
    xSemaphoreGive(lock_);
    return waitDone(100);
  }

  // Two commands, because the flash needs time between them and there is no way
  // to wait inside a frame: READ fetches the page into the board's buffer, PAGE
  // dumps it back. The address is absolute -- reads are not slot-relative,
  // because a read cannot damage anything and being able to look at the shell's
  // own image is the only independent check of what is really in the chip.
  bool readPage(uint32_t addr, uint8_t *out) {
    uint8_t a[3] = { (uint8_t)(addr >> 16), (uint8_t)(addr >> 8), (uint8_t)addr };
    frame(CMD_FLASH_READ, a, sizeof(a), nullptr, 0);
    // The same race applies to a read: believing a fetch finished before it
    // started hands back whatever the page buffer held from last time, which
    // during a verify means comparing an image against itself one page late.
    if (!waitDone(100)) return false;

    xSemaphoreTake(lock_, portMAX_DELAY);
    spi_.beginTransaction(settings_);
    digitalWrite(cs_, LOW);
    spi_.transfer(CMD_FLASH_PAGE);
    spi_.transfer(0x00);                  // the board's own header byte
    for (size_t i = 0; i < PAGE; i++) out[i] = spi_.transfer(0x00);
    digitalWrite(cs_, HIGH);
    spi_.endTransaction();
    xSemaphoreGive(lock_);
    return true;
  }

  // --- the console image's register bus (rtl/esp_bus.v) ------------------------
  // The same bus the PC drives over Ethernet: cartridges, pads, the menu's text.
  // A write frame carries any number of words to consecutive addresses; a read is
  // one word, after four bytes in which the board fetches it.
  void busWrite(uint32_t addr, const uint32_t *w, size_t n) {
    xSemaphoreTake(lock_, portMAX_DELAY);
    spi_.beginTransaction(settings_);
    digitalWrite(cs_, LOW);
    spi_.transfer(CMD_BUS_WRITE);
    spi_.transfer(addr >> 24); spi_.transfer(addr >> 16); spi_.transfer(addr >> 8); spi_.transfer(addr);
    for (size_t i = 0; i < n; i++) {
      spi_.transfer(w[i]); spi_.transfer(w[i] >> 8); spi_.transfer(w[i] >> 16); spi_.transfer(w[i] >> 24);
    }
    digitalWrite(cs_, HIGH);
    spi_.endTransaction();
    xSemaphoreGive(lock_);
  }
  void busWrite(uint32_t addr, uint32_t v) { busWrite(addr, &v, 1); }

  uint32_t busRead(uint32_t addr) {
    uint8_t r[4];
    xSemaphoreTake(lock_, portMAX_DELAY);
    spi_.beginTransaction(settings_);
    digitalWrite(cs_, LOW);
    spi_.transfer(CMD_BUS_READ);
    spi_.transfer(addr >> 24); spi_.transfer(addr >> 16); spi_.transfer(addr >> 8); spi_.transfer(addr);
    for (int i = 0; i < 4; i++) spi_.transfer(0);
    for (int i = 0; i < 4; i++) r[i] = spi_.transfer(0);
    digitalWrite(cs_, HIGH);
    spi_.endTransaction();
    xSemaphoreGive(lock_);
    return r[0] | (r[1] << 8) | (r[2] << 16) | ((uint32_t)r[3] << 24);
  }

  // n words from addr up, in one frame (rtl/esp_bus.v CMD_BUS_RDBLK)
  void busReadBlock(uint32_t addr, uint32_t *out, size_t n) {
    xSemaphoreTake(lock_, portMAX_DELAY);
    spi_.beginTransaction(settings_);
    digitalWrite(cs_, LOW);
    spi_.transfer(CMD_BUS_RDBLK);
    spi_.transfer(addr >> 24); spi_.transfer(addr >> 16); spi_.transfer(addr >> 8); spi_.transfer(addr);
    for (int i = 0; i < 4; i++) spi_.transfer(0);
    for (size_t k = 0; k < n; k++) {
      uint32_t b0 = spi_.transfer(0), b1 = spi_.transfer(0), b2 = spi_.transfer(0), b3 = spi_.transfer(0);
      out[k] = b0 | (b1 << 8) | (b2 << 16) | (b3 << 24);
    }
    digitalWrite(cs_, HIGH);
    spi_.endTransaction();
    xSemaphoreGive(lock_);
  }

  // No reply is possible: the chip stops being the thing that was listening.
  void boot(bool core) {
    uint8_t tx = core ? 1 : 0;
    frame(CMD_BOOT, &tx, 1, nullptr, 0);
  }

private:
  void frame(uint8_t cmd, const uint8_t *tx, size_t txn,
             uint8_t *rx, size_t rxn) {
    xSemaphoreTake(lock_, portMAX_DELAY);
    spi_.beginTransaction(settings_);
    digitalWrite(cs_, LOW);
    uint8_t r = spi_.transfer(cmd);
    if (rx && rxn) rx[0] = r;
    for (size_t i = 0; i < txn; i++) {
      r = spi_.transfer(tx[i]);
      if (rx && i + 1 < rxn) rx[i + 1] = r;
    }
    for (size_t i = txn + 1; i < rxn; i++) rx[i] = spi_.transfer(0x00);
    digitalWrite(cs_, HIGH);
    spi_.endTransaction();
    xSemaphoreGive(lock_);
  }

  SPIClass   &spi_;
  SPISettings settings_;
  SemaphoreHandle_t lock_ = nullptr;   // one transfer at a time, from whichever task
  int sck_, miso_, mosi_, cs_, prog_, done_;
};
