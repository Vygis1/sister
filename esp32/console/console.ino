// console.ino - the front door: six wires to an FPGA, an SD card, Bluetooth pads, a serial port.
//
// See esp32/README.md for the wiring and docs/ARCHITECTURE.md for the division of labour. The
// short version: this picks what the board should BE and what it should run, and carries
// neither video nor audio. There is no radio but Bluetooth: the Wi-Fi access point, the web
// page and its API were removed on 2026-10-12 -- on this chip Wi-Fi shares the one radio and
// the internal RAM with Bluetooth, and with both up a pad's buttons arrived late, stuck or not
// at all. Cores and games go onto the card in a PC; the menu reads the card.
//
// --- what it can do --------------------------------------------------------
//
// Everything the shell can: say what the board currently is, install a core from the card into
// the flash slot, and boot it. Pads over Bluetooth (pads.h), the menu on the TV (menu.h), the
// PlayStation's disc served sector by sector off the card, its XA audio decoded here.

#include <Preferences.h>
#include <SPI.h>
#include <SD.h>
#include "link.h"
#include "sdprobe.h"
#include "xa.h"
#include <esp_rom_crc.h>
#include <esp_heap_caps.h>

// --- wiring ------------------------------------------------------------------
// ESP32-S3. The bus names differ from the classic ESP32 -- FSPI and HSPI rather
// than VSPI and HSPI -- and a sketch written for the older part does not compile
// here. The pins are a choice rather than a constraint, because the S3 routes
// peripherals through a GPIO matrix: these avoid the strapping pins (0, 3, 45,
// 46) and the ones wired to the on-board flash and PSRAM (33-37), which on an
// 8 MB-PSRAM part are genuinely unavailable.
//
//   GPIO12 -> esp_sclk   U2 pin 7       GPIO11 -> esp_mosi   U2 pin 8
//   GPIO13 <- esp_miso   U2 pin 9       GPIO10 -> esp_cs_n   U2 pin 10
//   3V3 and GND          U2 pins 3, 61  -- NOT 63/64, those are VIN
#if CONFIG_IDF_TARGET_ESP32S3
static const int PIN_SCK = 12, PIN_MOSI = 11, PIN_MISO = 13, PIN_CS = 10;
#else
// The classic ESP32 (the LilyGO T8: ESP32-WROVER, Bluetooth Classic for the pads). Its
// PSRAM has GPIO 16/17 and the board's microSD slot GPIO 2/13/14/15, so the FPGA goes on
// VSPI's own pins:
//   GPIO18 -> esp_sclk   U2 pin 7       GPIO23 -> esp_mosi   U2 pin 8
//   GPIO19 <- esp_miso   U2 pin 9       GPIO5  -> esp_cs_n   U2 pin 10
//   GPIO32 -> PROGRAM_B                 GND -> U2 pin 61
static const int PIN_SCK = 18, PIN_MOSI = 23, PIN_MISO = 19, PIN_CS = 5;
#endif

// PROGRAM_B is soldered to the non-ground side of SW1, the core board's own
// program button -- it is not on any header. Pulling it low and releasing it
// restarts configuration from address 0, which is always the shell, so this is
// the way back from a core that hangs without reaching for the power lead.
//
// Driven LOW or left as an INPUT, never driven high. That is what makes it safe
// to share the net with a button a person can press: the two can never fight,
// and a reset of this chip cannot hold the FPGA in configuration.
//
// DONE is still -1. It is the FPGA_DONE net at the R1/D1 indicator LED; wiring
// it replaces a fixed wait with actually knowing configuration finished.
#if CONFIG_IDF_TARGET_ESP32S3
static const int PIN_PROG_B = 14, PIN_DONE = -1;
#else
static const int PIN_PROG_B = 32, PIN_DONE = -1;
#endif

// The card, when there is one. Well clear of the flash and PSRAM pins.
#if CONFIG_IDF_TARGET_ESP32S3
static const int PIN_SD_SCK = 5, PIN_SD_MISO = 6, PIN_SD_MOSI = 4, PIN_SD_CS = 7;
#else
// the T8 V1.7.1's own slot (its schematic: IO13 CS/D3, IO15 CMD, IO14 CLK, IO2 D0 -- not the
// 33/14/12/27 of the repo's old example; IO12 is the flash-voltage strap and is left alone)
static const int PIN_SD_SCK = 14, PIN_SD_MISO = 2, PIN_SD_MOSI = 15, PIN_SD_CS = 13;
#endif

#if CONFIG_IDF_TARGET_ESP32S3
SPIClass fpgaBus(FSPI), sdBus(HSPI);
#else
SPIClass fpgaBus(VSPI), sdBus(HSPI);
#endif
FpgaLink fpga(fpgaBus, PIN_SCK, PIN_MISO, PIN_MOSI, PIN_CS, PIN_PROG_B, PIN_DONE);
Preferences prefs;

bool haveCard = false;

// --- the PlayStation's disc -------------------------------------------------------
// An image on the card (.bin, raw 2352-byte sectors, one data track), served a
// sector at a time to the console image's drive (rtl/cd_feed.v): the board says
// which sector it wants next and how much room it has, this task reads that
// sector off the card and sends it. "disc /discs/crash.bin" over serial (or the menu)
// puts the disc in; "eject" takes it out.
static File     discFile;
static String   discPath;                 // a card path
static volatile bool discIn = false;
static uint32_t discSectors = 0, discServed = 0, discMisses = 0, discIdle = 0, discFetches = 0;
static uint8_t *discBuf = nullptr;        // one sector, for the card path
static const uint32_t WINDOW = 128;       // sectors buffered ahead of the drive (295 kB in PSRAM)
static uint8_t *discWin = nullptr;        // WINDOW sectors, in PSRAM
static uint32_t winBase = 0, winCount = 0;

// --- the card reader ---------------------------------------------------------------
//
// Reading the card and sending a sector to the FPGA used to happen one after the
// other in the drive task: about 4 ms to read a sector at 8 MHz and 3.8 ms to
// clock it out at 5 MHz, so 128 sectors a second -- SLOWER than the real drive's
// 150 at double speed. No real game ever sees a drive that slow, and Crash did
// not survive it: with the processor on every clock (ps1_top cpu_fast, the
// default since 2026-09-28) it crashed into the BIOS's exception loop in its
// intro, every time, while the same boot fed from the PC went straight through.
//
// The card and the FPGA are on different SPI buses, so the two can overlap. This
// task keeps a ring of WINDOW sectors ahead of the sector the drive wants, and
// the drive task only sends. Measured: 260-odd sectors a second, bounded by the
// FPGA link, not the card.
//
// The ring: sector L lives in slot L % WINDOW, and ringLba[slot] says which
// sector is in it. The reader never runs more than AHEAD past rdWant, so the
// BEHIND sectors the drive has just moved beyond are still there: the XA task
// below decodes audio sectors the drive has already had.
static const uint32_t    BEHIND = 64, AHEAD = WINDOW - BEHIND;   // (XA: a sector can be 40 behind when its turn comes)
static volatile uint32_t rdWant = 0;          // the sector the drive wants next (set by the drive task)
static volatile bool     rdBusy = false;      // the reader is inside a card read
static uint32_t          rdNext = 0;          // the next sector the reader will read
static int64_t           rdFilePos = -1;      // where the file position is, in sectors (-1: unknown)
static uint32_t          ringLba[WINDOW];
static uint32_t          discSick = 0;

static void ringClear() {
  for (uint32_t i = 0; i < WINDOW; i++) ringLba[i] = 0xFFFFFFFF;
  rdNext = 0; rdFilePos = -1; rdWant = 0; discSick = 0;
}

static void discReopen() {
  if (discFile) discFile.close();
  discFile = SD.open(discPath);
  rdFilePos = -1; discSick = 0;
  Serial.println(discFile ? "disc: reopened the image" : "disc: the image will not open");
}

static void xaService();                       // (below, with the XA decoder)
static volatile bool xaTaskUp = false;
// XA in a task of its own, above loop() and the menu on core 1: in loop() it waited behind the
// web server, the pads and the menu, and the drive's 93 ms of sound ran out between visits
static void xaTask(void *) { xaTaskUp = true; for (;;) { xaService(); vTaskDelay(1); } }

static void cardReaderTask(void *) {
  for (;;) {
    if (!discIn || !discWin) { vTaskDelay(10 / portTICK_PERIOD_MS); continue; }
    uint32_t want = rdWant;
    // the drive went somewhere the ring does not hold: start reading there
    if (ringLba[want % WINDOW] != want && rdNext != want) rdNext = want;
    if (rdNext >= want + AHEAD || rdNext >= discSectors) { vTaskDelay(1); continue; }
    // up to 8 sectors in one read, contiguous in the ring and not past the limit
    uint32_t slot = rdNext % WINDOW;
    uint32_t n = 8;
    if (n > WINDOW - slot) n = WINDOW - slot;
    if (n > want + AHEAD - rdNext) n = want + AHEAD - rdNext;
    if (n > discSectors - rdNext) n = discSectors - rdNext;
    for (uint32_t k = 0; k < n; k++) ringLba[slot + k] = 0xFFFFFFFF;   // about to change under the drive
    rdBusy = true;
    if (!discIn) { rdBusy = false; continue; }                         // ejected in between
    if (!discFile) discReopen();
    bool ok = discFile;
    if (ok && rdFilePos != (int64_t)rdNext) {
      ok = discFile.seek((uint64_t)rdNext * 2352);
      rdFilePos = ok ? rdNext : -1;
    }
    uint32_t got = 0;
    if (ok) {
      // bytes, not sectors: a read can come back short (see the note that used to
      // be here -- a lost remainder offset every sector after it by a few bytes)
      uint8_t *dst = discWin + (size_t)slot * 2352;
      uint32_t want_bytes = n * 2352;
      for (int tries = 0; tries < 8 && got < want_bytes; tries++) {
        int r = discFile.read(dst + got, want_bytes - got);
        if (r <= 0) break;
        got += (uint32_t)r;
      }
      rdFilePos = (got == want_bytes) ? (int64_t)(rdNext + n) : -1;
    }
    rdBusy = false;
    uint32_t whole = got / 2352;
    if (whole == 0) {
      if (++discSick > 50) discReopen();
      vTaskDelay(1);
      continue;
    }
    discSick = 0;
    __sync_synchronize();                                              // the data before the label
    for (uint32_t k = 0; k < whole; k++) ringLba[slot + k] = rdNext + k;
    rdNext += whole;
  }
}

// Stop the reader touching the card (before closing, reopening or re-mounting).
static void readerPause() {
  discIn = false;
  for (int i = 0; i < 200 && rdBusy; i++) delay(1);
}

static const uint8_t *discSectorCard(uint32_t lba) {
  rdWant = lba;
  if (ringLba[lba % WINDOW] != lba) return nullptr;
  __sync_synchronize();
  return discWin + (size_t)(lba % WINDOW) * 2352;
}

// --- XA audio: decoded here, for the drive --------------------------------------------
//
// The drive queues the LBA of every XA audio sector the game lets through (console 0x13C:
// [31:27] how many, [23:0] the oldest; a write of 1 takes it), and plays 44.1 kHz stereo out
// of a 4096-sample FIFO filled through the window at 0x6000. 0x140 = {flushes [31:24], the
// game filters [16], samples in the FIFO [12:0]}: a new flush count -- a seek, a pause, a new
// read -- starts the decoder over, as the chip's does. The PC did this when it served the disc
// (pc/server.py XaPump); off the card nobody did, and Gran Turismo 2 played no music. xa.h is
// that decoder, checked word for word against it (tools/ps1/xatest.py).
static const uint32_t XA_CTRL = 0x00080000;
static const uint32_t XA_PEND = 16384;        // decoded words waiting for room in the FIFO
static uint32_t *xaPend = nullptr, *xaOut = nullptr;
// a sound group at a time through internal RAM (xa.h: PSRAM in the inner loop cost 28 ms a sector)
// (allocated after the menu's task: as static data they cost the menu the one piece of internal
// RAM its stack wants, and it did not start)
static uint8_t  *xaChIn = nullptr;
static uint32_t *xaChOut = nullptr;
// one sector into the pending ring at `head`; the words made
static uint32_t xaDecodeInto(xa::Decoder &dec, const uint8_t *sec, uint32_t head) {
  dec.begin(sec);
  uint32_t made = 0;
  for (int ci = 0; ci < 18; ci++) {
    memcpy(xaChIn, sec + 24 + ci * 128, 128);
    int n = dec.chunk(xaChIn, xaChOut);
    for (int i = 0; i < n; i++) xaPend[(head + made + i) % XA_PEND] = xaChOut[i];
    made += n;
  }
  return made;
}
static uint8_t  *xaSec = nullptr;             // the sector being decoded, copied out of the ring
static volatile uint32_t xaDecoded = 0, xaMissed = 0, xaPushed = 0;
static volatile uint32_t xaUs = 0, xaUsMax = 0;   // the last / longest decode of a sector, microseconds
static volatile uint32_t xaMissLba = 0, xaMissHeld = 0, xaMissWant = 0;   // the last miss: wanted, the slot's, the drive's

static const uint8_t *discSectorBehind(uint32_t lba) {
  if (!discWin || ringLba[lba % WINDOW] != lba) return nullptr;
  __sync_synchronize();
  return discWin + (size_t)(lba % WINDOW) * 2352;
}

// Called from loop() on core 1, every few milliseconds while the drive task says a PlayStation
// runs with a disc from the card. Not a task of its own: a stack must come out of internal RAM,
// which the menu and Bluetooth leave in pieces (created after the menu it failed one boot in
// two). Not the drive task on core 0: Bluetooth and Wi-Fi preempt it there, and the disc feed
// fell to 100 sectors a second. Not the card reader: it sits in card reads, and the queue's
// sectors were 75-120 old -- gone from the ring -- by the time it looked.
static volatile bool xaRun = false;           // set by the drive task: the PlayStation core is up, a disc in
static xa::Decoder xaDec;
static int      xaGen = -1;
static uint32_t xaHead = 0, xaTail = 0;       // xaPend is a ring: words [xaTail, xaHead)
static uint32_t xaLast = 0;

static void xaService() {
  if (!xaRun) { xaGen = -1; return; }
  if (!xaPend || millis() - xaLast < 4) return;
  xaLast = millis();
  xa::Decoder &dec = xaDec; int &gen = xaGen; uint32_t &head = xaHead, &tail = xaTail;
  {
    uint32_t st = fpga.busRead(XA_CTRL + 0x140);
    int g = st >> 24; bool filt = (st >> 16) & 1; uint32_t level = st & 0x1FFF;
    if (g != gen) { gen = g; dec.reset(); head = tail = 0; }
    uint32_t q = fpga.busRead(XA_CTRL + 0x13C);
    while ((q >> 27) && head - tail <= XA_PEND - xa::MAX_OUT) {
      uint32_t lba = q & 0xFFFFFF;
      fpga.busWrite(XA_CTRL + 0x13C, 1);
      // (copied out, then the label looked at again: a reader running ahead could have
      // started on that slot while it was being copied)
      uint8_t *sec = xaSec;
      const uint8_t *src = discSectorBehind(lba);
      bool have = src != nullptr;
      if (have) { memcpy(sec, src, 2352); __sync_synchronize(); have = ringLba[lba % WINDOW] == lba; }
      if (!have) { xaMissed++; xaMissLba = lba; xaMissHeld = ringLba[lba % WINDOW]; xaMissWant = rdWant; }
      else if (dec.accept(sec, filt)) {
        uint32_t t0 = micros();
        head += xaDecodeInto(dec, sec, head);
        xaUs = micros() - t0; if (xaUs > xaUsMax) xaUsMax = xaUs;
        xaDecoded++;
      }
      q = fpga.busRead(XA_CTRL + 0x13C);
    }
    int room = 4096 - (int)level - 32;
    if (room > 0 && head != tail) {
      uint32_t k = head - tail;
      if (k > (uint32_t)room) k = room;
      if (k > 1024) k = 1024;
      uint32_t t = tail % XA_PEND;
      if (k > XA_PEND - t) k = XA_PEND - t;           // (one contiguous stretch a write)
      fpga.busWriteFast(XA_CTRL + 0x6000, xaPend + t, k);
      tail += k; xaPushed += k;
    }
  }
}

static void discTask(void *) {
  for (;;) {
    if (!discIn) { xaRun = false; vTaskDelay(20 / portTICK_PERIOD_MS); continue; }
    CdStatus st = fpga.cdStatus();
    if (!st.alive || st.core != CORE_PS1_ID) { xaRun = false; vTaskDelay(50 / portTICK_PERIOD_MS); continue; }
    if (!st.disc) { xaRun = false; fpga.cdDisc(true); vTaskDelay(1); continue; }   // the core was reset: tell it again
    xaRun = true;
    if (!st.running || st.room == 0 || st.lba >= discSectors) {
      discIdle++;
      rdWant = st.lba;                                                 // idle time is read-ahead time
      vTaskDelay(1); continue;
    }
    const uint8_t *sec = discSectorCard(st.lba);
    if (!sec) { discMisses++; vTaskDelay(1); continue; }
    fpga.cdSector(st.lba, sec);
    discServed++;
    // The link to the FPGA is polled, not interrupt-driven, so a drive that
    // wants sector after sector would keep this core busy for ever now that the
    // card is read elsewhere -- the idle task starves and the task watchdog
    // restarts the chip (it did, every eight seconds). A tick every eight
    // sectors costs a millisecond in thirty.
    if ((discServed & 7) == 0) vTaskDelay(1);
  }
}
static volatile bool listsStale = true;   // the card's listings need reading again
static volatile bool cardChanged = false; // the TV menu's: a file came or went (menu.h rescans)

// The disc outlives a reset. The ESP32 reboots whenever it is reflashed or the
// FPGA is reloaded, and a console that came back to an empty drive just sat in
// the BIOS -- which is what "it will not boot any more" looked like.
static void discRemember(const String &path) {
  Preferences p;
  if (p.begin("disc", false)) { p.putString("path", path); p.end(); }
}
static String discRecall() {
  Preferences p; String v = "";
  if (p.begin("disc", true)) { v = p.getString("path", ""); p.end(); }
  return v;
}

static bool discInsert(const String &path) {
  // Open the new image BEFORE letting go of the one in the drive. The old order
  // stopped the drive first, so a path that was not on the card left the console
  // with no disc at all -- the BIOS sat at its logo (2026-09-30).
  File nf = SD.open(path);
  if (!nf) return false;
  readerPause();
  if (discFile) discFile.close();
  discFile = nf;
  discSectors = discFile.size() / 2352;
  if (!discWin) discWin = (uint8_t *)ps_malloc(WINDOW * 2352);
  if (!discWin) return false;
  winBase = 0; winCount = 0;
  ringClear();
  discPath = path;
  discRemember(path);
  discServed = 0; discMisses = 0; discIdle = 0; discFetches = 0;
  fpga.cdDisc(true);
  discIn = true;
  return true;
}
static void discEject() {
  readerPause();
  fpga.cdDisc(false);
  if (discFile) discFile.close();
  discPath = "";
  discRemember("");
}

SdProbe sdInfo;          // what the card itself said, filesystem aside
String  sdWhy;           // one line explaining the state

// --- one job at a time, reported while it runs --------------------------------
// Installing a core is a minute of flash erases and thousands of page writes; the work
// reports its progress (the menu and the serial console show it).
struct Job {
  volatile bool     busy = false;
  volatile uint32_t done = 0, total = 0;
  String            stage, error;
} job;

static String jsonEscape(const String &s) {
  String o;
  for (unsigned i = 0; i < s.length(); i++) {
    char c = s[i];
    if (c == '"' || c == '\\') { o += '\\'; o += c; }
    else if (c == '\n') o += "\\n";
    else if ((unsigned char)c >= 0x20) o += c;
  }
  return o;
}

// --- installing a core --------------------------------------------------------
// Erase only the sectors the image will occupy, write it, then read every page
// back. The verify is not optional: a core that half wrote and a core that is
// fine look identical right up until the board tries to configure from it, and
// at that point the only symptom is a board that does not come back.
// A running CRC32 of what was sent, so the read-back has something to compare
// against without needing to rewind the source. That matters: a core from the
// card is a File and could be seeked, but a core from the browser is an upload
// that has already gone by. One checksum covers both.
static uint32_t crc32(uint32_t crc, const uint8_t *p, size_t n) {
  crc = ~crc;
  while (n--) {
    crc ^= *p++;
    for (int k = 0; k < 8; k++) crc = (crc >> 1) ^ (0xEDB88320u & (-(int32_t)(crc & 1)));
  }
  return ~crc;
}

static bool installFrom(Stream &src, uint32_t length) {
  static uint8_t page[PAGE], got[PAGE];
  uint32_t sent = 0, back = 0;

  if (length == 0 || length > SLOT_SIZE) {
    job.error = "that image is " + String(length) + " bytes; the slot is 6 MB";
    return false;
  }

  uint32_t sectors = (length + SECTOR - 1) / SECTOR;
  job.stage = "erasing"; job.total = sectors; job.done = 0;
  for (uint32_t i = 0; i < sectors; i++) {
    if (!fpga.eraseSector(i * SECTOR)) {
      job.error = "the flash never finished erasing sector " + String(i);
      return false;
    }
    job.done = i + 1;
  }

  uint32_t pages = (length + PAGE - 1) / PAGE;
  job.stage = "writing"; job.total = pages; job.done = 0;
  for (uint32_t i = 0; i < pages; i++) {
    uint32_t want = (i == pages - 1) ? (length - i * PAGE) : PAGE;
    uint32_t have = 0, t0 = millis();
    while (have < want && millis() - t0 < 8000)
      have += src.readBytes((char *)page + have, want - have);
    if (have < want) { job.error = "the image ended early"; return false; }
    for (uint32_t k = want; k < PAGE; k++) page[k] = 0xFF;

    if (!fpga.writePage(i * PAGE, page, PAGE)) {
      job.error = "the flash never finished writing page " + String(i);
      return false;
    }
    sent = crc32(sent, page, PAGE);
    job.done = i + 1;
  }

  // Read it all back. Cheap next to the write, and the only thing standing
  // between a bad install and a board that will not configure.
  //
  // This block used to be the comment above and nothing else -- it set the
  // stage to "verifying", flushed, and returned true. An install that silently
  // wrote nothing would have reported success, which is exactly the failure the
  // comment claims to prevent.
  //
  // Reads are ABSOLUTE addresses while writes are slot-relative, so the slot
  // base goes back on here. Getting that wrong would verify the shell's own
  // image against the core and fail every time.
  job.stage = "verifying"; job.total = pages; job.done = 0;
  for (uint32_t i = 0; i < pages; i++) {
    if (!fpga.readPage(SLOT_BASE + i * PAGE, got)) {
      job.error = "could not read page " + String(i) + " back";
      return false;
    }
    back = crc32(back, got, PAGE);
    job.done = i + 1;
  }
  if (sent != back) {
    job.error = "what came back does not match what was written -- the core is "
                "NOT installed";
    return false;
  }
  src.flush();
  return true;
}

// From the card, where the image can be read again: a 64 kB sector at a time --
// erased, its 256 pages written, every one read back and compared with the file, and
// the whole sector done again (up to three times) if any page is wrong. Seen on the
// board: one page in ten thousand never programmed, or programmed with a few bits
// wrong (some 0 -> 1, which a program cannot do: the bytes arrived wrong). Either way
// a whole install used to fail its CRC at the end and leave the board in the shell
// with no picture; now the bad sector is simply written again.
static bool installCard(File &f) {
  static uint8_t want[PAGE], got[PAGE];
  uint32_t length = f.size();
  if (length == 0 || length > SLOT_SIZE) {
    job.error = "that image is " + String(length) + " bytes; the slot is 6 MB";
    return false;
  }
  uint32_t pages = (length + PAGE - 1) / PAGE;
  uint32_t sectors = (length + SECTOR - 1) / SECTOR, redone = 0;
  const uint32_t per = SECTOR / PAGE;
  // every sector erased first, in order -- the shell's screen takes the image's
  // size from these -- then each written and read back, and erased again and
  // rewritten only if it came back wrong
  job.stage = "erasing"; job.total = sectors; job.done = 0;
  for (uint32_t sec = 0; sec < sectors; sec++) {
    if (!fpga.eraseSector(sec * SECTOR) && !fpga.eraseSector(sec * SECTOR)) {
      job.error = "the flash never finished erasing sector " + String(sec);
      return false;
    }
    job.done = sec + 1;
  }
  job.stage = "writing"; job.total = pages; job.done = 0;
  for (uint32_t sec = 0; sec < sectors; sec++) {
    uint32_t p0 = sec * per, p1 = min(pages, p0 + per);
    bool good = false;
    for (int tries = 0; tries < 3 && !good; tries++) {
      if (tries) {
        redone++;
        if (!fpga.eraseSector(sec * SECTOR) && !fpga.eraseSector(sec * SECTOR)) continue;
      }
      f.seek(p0 * PAGE);
      for (uint32_t i = p0; i < p1; i++) {
        size_t r = f.read(want, PAGE);
        for (size_t k = r; k < PAGE; k++) want[k] = 0xFF;
        fpga.writePage(i * PAGE, want, PAGE);
      }
      f.seek(p0 * PAGE);
      good = true;
      for (uint32_t i = p0; i < p1 && good; i++) {
        size_t r = f.read(want, PAGE);
        for (size_t k = r; k < PAGE; k++) want[k] = 0xFF;
        if (!fpga.readPage(SLOT_BASE + i * PAGE, got) && !fpga.readPage(SLOT_BASE + i * PAGE, got)) good = false;
        else if (memcmp(want, got, PAGE)) {
          good = false;
          Serial.printf("install: page %u wrong, sector %u again\n", i, sec);
        }
      }
    }
    if (!good) {
      job.error = "sector " + String(sec) + " would not write right three times -- the core is NOT installed";
      return false;
    }
    job.done = p1;
  }
  if (redone) Serial.printf("install: %u sector(s) written again\n", redone);
  job.stage = "verified";
  return true;
}

// --- the SD card --------------------------------------------------------------
// Games live beside the cores. A console that can change which machine it is
// but cannot hold a single cartridge is only half an appliance, and the card has
// 238 GB on it.
static String coreListScan() {
  String j = "[";
  if (haveCard) {
    File dir = SD.open("/cores");
    while (dir) {
      File e = dir.openNextFile();
      if (!e) break;
      String n = String(e.name());
      if (!e.isDirectory() && n.endsWith(".bin")) {
        int slash = n.lastIndexOf('/');
        if (slash >= 0) n = n.substring(slash + 1);
        if (j.length() > 1) j += ",";
        j += "{\"name\":\"" + jsonEscape(n.substring(0, n.length() - 4)) +
             "\",\"size\":" + String((uint32_t)e.size()) + "}";
      }
      e.close();
    }
    if (dir) dir.close();
  }
  return j + "]";
}

// --- installing from the card --------------------------------------------------
static String cardCore;

static void installTask(void *) {
  File f = SD.open("/cores/" + cardCore + ".bin");
  if (!f) job.error = "no such core on the card";
  else {
    if (installCard(f)) {
      job.stage = "done";
      // (what the slot holds, for the menu: it installs only when this differs)
      prefs.begin("menu", false); prefs.putString("slot", cardCore); prefs.putUInt("size", f.size()); prefs.end();
    }
    f.close();
  }
  job.busy = false;
  vTaskDelete(nullptr);
}

static void serviceSerial(bool inUpload);

#include "pads.h"
#include "menu.h"

static String bootPins;

// The FPGA link's four wires with pulls only (nothing driven, so nothing can fight the
// FPGA): each one HIGH / LOW / floating, as a line.
static String linkPins() {
  const int pins[4] = { PIN_SCK, PIN_MOSI, PIN_MISO, PIN_CS };
  const char *names[4] = { "sclk", "mosi", "miso", "cs_n" };
  String out;
  for (int i = 0; i < 4; i++) {
    gpio_reset_pin((gpio_num_t)pins[i]);
    pinMode(pins[i], INPUT_PULLUP);   delay(5); bool up = digitalRead(pins[i]);
    pinMode(pins[i], INPUT_PULLDOWN); delay(5); bool dn = digitalRead(pins[i]);
    pinMode(pins[i], INPUT);
    out += String("  ") + names[i] + " (GPIO" + pins[i] + ") " +
           ((up && !dn) ? "floating" : (up && dn) ? "held HIGH" : (!up && !dn) ? "held LOW" : "odd") + "\n";
  }
  return out;
}                      // what the pins saw at power-up (the "pins" command)

void setup() {
  // Small allocations to PSRAM too. By default everything under 4 kB comes out of internal
  // RAM, and the menu's strings broke it into pieces: minutes after boot 9 kB was free with
  // nothing over 3 kB (2026-10-10, T8 with a DualShock 4 in). Bluetooth and task stacks still
  // take internal RAM: they ask for it by name.
  heap_caps_malloc_extmem_enable(64);
  Serial.begin(115200);
  delay(300);
#if CONFIG_IDF_TARGET_ESP32S3
  Serial.println("\nconsole: ESP32-S3 front door");
#else
  Serial.println("\nconsole: ESP32 (T8) front door");
#endif

  // Before ANY peripheral claims a pin. Once SPI owns them through the GPIO
  // matrix they read back what the peripheral drives, not what is wired to
  // them, and the answer becomes confidently wrong.
  String pinMap = sdScanPins();
  bootPins = pinMap;

  // 5 MHz, not 10.
  //
  // esp_link brings the SPI clock into the board's 50 MHz domain through a
  // synchroniser and finds its edges by comparison, which needs a comfortable
  // number of system clocks per half-period. At 10 MHz that is two and a half,
  // and the module's own header admits the ceiling is "near 12 MHz" -- so 10 was
  // sitting just under a limit rather than well below one.
  //
  // It mostly worked, which is the problem. Installing a core is tens of
  // thousands of transactions, and a missed edge in one of them corrupts a
  // command rather than announcing itself: the board reports the operation
  // started and finished, and a page is simply never programmed. Eight blank
  // pages out of seven thousand, scattered, with every write "successful".
  //
  // At 5 MHz there are five system clocks per half-period. The install takes a
  // few seconds longer and stops losing pages.
  fpga.begin(5000000);

  sdBus.begin(PIN_SD_SCK, PIN_SD_MISO, PIN_SD_MOSI, PIN_SD_CS);
  // Ask the card what it is BEFORE asking the filesystem anything. A failed
  // mount and a disconnected card are the same bit out of SD.begin(), and they
  // are a reformat and a soldering iron respectively -- see sdprobe.h.
  SdDiagnosis sd = sdDiagnose(sdBus, PIN_SD_SCK, PIN_SD_MISO, PIN_SD_MOSI, PIN_SD_CS);
  sdInfo = sd.probe;
  // 8 MHz, not 20: the card answers its init at 20 over these jumpers, and then
  // drops bytes on a sustained write -- a 632 MB disc image died at twelve and
  // then at seventeen megabytes. Reads for the drive need 300 kB/s; this gives
  // several times that with margin.
#if CONFIG_IDF_TARGET_ESP32S3
  haveCard = sdInfo.responded && SD.begin(PIN_SD_CS, sdBus, 8000000);
#else
  // (the T8: its card is in its own slot on the board, not on jumpers -- 20 MHz. Double-speed
  // discs need ~700 kB/s, which 8 MHz could barely give)
  haveCard = sdInfo.responded && SD.begin(PIN_SD_CS, sdBus, 20000000);
  if (!haveCard && sdInfo.responded) haveCard = SD.begin(PIN_SD_CS, sdBus, 8000000);
#endif
  // CORE 0, not 1: reading the card blocks inside the SPI driver, and on the
  // same core as loop() that starves the web server and the serial console
  // together -- the board goes completely deaf while the drive is being fed,
  // which looked exactly like a crash.
  xaOut  = (uint32_t *)ps_malloc(xa::MAX_OUT * 4);
  xaSec  = (uint8_t *)ps_malloc(2352);
  xaPend = (xaOut && xaSec) ? (uint32_t *)ps_malloc(XA_PEND * 4) : nullptr;   // (xaPend set: XA on)
  if (!xaPend) Serial.println("xa: no PSRAM for the decoder: no CD audio");
  xaDec.reset();
  xTaskCreatePinnedToCore(discTask, "disc", 8192, nullptr, 2, nullptr, 0);
  // the card reader on the OTHER core: the two buses then work at once (see
  // cardReaderTask). It spends its waits blocked in the SD driver, not spinning,
  // so loop() on this core still gets its turn.
  xTaskCreatePinnedToCore(cardReaderTask, "cardread", 8192, nullptr, 1, nullptr, 1);
  // the disc that was in goes back in
  { String was = discRecall();
    if (was.length()) {
      Serial.println("disc: putting " + was + " back in");
      if (!discInsert(was)) Serial.println("disc: ...but it would not open");
    } }
  sdWhy = sdProbeSummary(sdInfo, haveCard);
  if (haveCard) {
    // The filesystem's own view, which is NOT the same as the card's. The probe
    // reads the capacity out of the CSD -- what the silicon says it holds -- and
    // the driver reads it out of the boot sector. When those disagree, writes
    // fail partway with "disk full" on a card that is plainly not full, and the
    // card's own number is the one that misleads you.
    uint64_t total = SD.totalBytes(), used = SD.usedBytes();
    sdWhy += ", filesystem sees " + String((double)total / 1073741824.0, 1) +
             " GB, " + String((double)(total - used) / 1073741824.0, 1) + " GB free";
  }
  Serial.println("SD: " + sdWhy);
  if (sd.verdict) Serial.println("    " + String(sd.verdict));
  Serial.println(String("    MISO idles ") +
                 (sd.misoHigh ? "HIGH (module has power)"
                              : "LOW (no power, or not connected)"));
  // Only when the CARD did not answer. Gating this on "did it mount" was wrong:
  // a card that responds perfectly and merely carries a filesystem this chip
  // cannot read would get a confident lecture about its wiring being wrong.
  // A diagnostic that fires on the wrong condition is worse than none, because
  // it sends you to check the thing that is already fine.
  if (!sdInfo.responded) {
    Serial.print(pinMap);
    sdPinReport(PIN_SD_SCK, PIN_SD_MISO, PIN_SD_MOSI, PIN_SD_CS);
    if (sdRailFloating(PIN_SD_MOSI, PIN_SD_SCK, PIN_SD_MISO, PIN_SD_CS))
      Serial.println("    => the module IS wired to these four pins and has NO "
                     "POWER. Its supply rail is floating, which is why the pins "
                     "drag each other around. Check VCC and GND at the module.");
    else
      Serial.println("    => these pins are genuinely unconnected - the wires "
                     "are not reaching the module at all.");
  }

  Status s = fpga.status();
  Serial.printf("FPGA: %s", s.alive ? "answering" : "NOT ANSWERING");
  if (!s.alive) Serial.print("\n" + bootPins);
  if (s.alive) Serial.printf(", protocol %u, core %u", s.version, s.core);
  Serial.println();

  menu::begin();
  xaChIn  = (uint8_t *)heap_caps_malloc(128, MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
  xaChOut = (uint32_t *)heap_caps_malloc(xa::MAX_CHUNK * 4, MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
  if (!xaChIn || !xaChOut) { Serial.println("xa: no internal RAM for the decoder: no CD audio"); xaPend = nullptr; }
  if (xaPend && xTaskCreatePinnedToCore(xaTask, "xa", 6144, nullptr, 2, nullptr, 1) != pdPASS)
    Serial.println("xa: no task (it runs from loop() instead)");
  pads::begin();
  menu::menuButton = []() { bool m = pads::menuPressed; pads::menuPressed = false; return m; };
}

// --- the same commands, over USB --------------------------------------------------
//
// Typed into the serial port: the way to exercise an install from the card, and when
// something goes wrong at three in the morning the interface that still works.
//
//   state              what the board is, and what is on the card
//   cores              the core library on the card
//   install <name>     write a core from the card into the flash slot
//   boot / shell       start the installed core / go back to the shell
static void serialCommand(String c) {
  c.trim();
  if (c.length() && c[0] == 'P') { pads::usbLine(c); return; }   // the PC's pad (pc/pad.py): quietly
  // a board register, for the PC's tools (pc/pad.py passes these through): "R addr" -> "= value",
  // "W addr value" -> "= ok" (hex)
  if (c.length() > 2 && (c[0] == 'R' || c[0] == 'W' || c[0] == 'D') && c[1] == ' ') {
    if (job.busy) { Serial.println("= busy"); return; }
    char *e = nullptr;
    uint32_t a = strtoul(c.c_str() + 2, &e, 16);
    if (c[0] == 'R') Serial.printf("= %08x\n", (unsigned)fpga.busRead(a));
    else if (c[0] == 'D') {
      // a block: "D addr n" -> "= " and n words in hex on one line (read at the link's speed,
      // so a ring that moves on is caught in one piece)
      uint32_t n = strtoul(e, nullptr, 16);
      if (n == 0 || n > 16384) n = 16384;
      uint32_t *w = (uint32_t *)ps_malloc(n * 4);
      if (!w) { Serial.println("= nomem"); return; }
      fpga.busReadBlock(a, w, n);
      Serial.print("= ");
      char hx[9];
      for (uint32_t i = 0; i < n; i++) { snprintf(hx, sizeof(hx), "%08x", (unsigned)w[i]); Serial.print(hx); }
      Serial.println();
      free(w);
    }
    else { uint32_t v = strtoul(e, nullptr, 16); fpga.busWrite(a, v); Serial.println("= ok"); }
    return;
  }
  if (c == "state") {
    // (internal RAM first: Bluetooth's buffers come out of it, and it is short)
    Serial.printf("  internal RAM %u free, largest piece %u, lowest ever %u; PSRAM %u free\n",
                  (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL),
                  (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT),
                  (unsigned)heap_caps_get_minimum_free_size(MALLOC_CAP_INTERNAL),
                  (unsigned)heap_caps_get_free_size(MALLOC_CAP_SPIRAM));
    // (not while a core is being installed: a status frame in the middle of the
    // flash traffic is the one thing seen to spoil an install's read-back)
    if (job.busy) { Serial.println("  job: " + job.stage + " " + job.done + "/" + job.total); return; }
    Status st = fpga.status();
    Serial.println("  FPGA " + String(st.alive ? "answering" : "SILENT") +
                   ", protocol " + st.version + ", core " + st.core +
                   (st.busy ? ", busy" : ", idle"));
    Serial.println("  card: " + sdWhy);
    Serial.printf("  XA: %u sectors decoded, %u not in the ring, %u samples sent\n",
                  (unsigned)xaDecoded, (unsigned)xaMissed, (unsigned)xaPushed);
    Serial.printf("  XA decode: %u us a sector (longest %u)\n", (unsigned)xaUs, (unsigned)xaUsMax);
    Serial.printf("  XA last miss: sector %u, its slot held %d, the drive wanted %u\n",
                  (unsigned)xaMissLba, (int)xaMissHeld, (unsigned)xaMissWant);
    if (job.busy || job.stage.length())
      Serial.println("  job: " + job.stage + " " + job.done + "/" + job.total +
                     (job.error.length() ? ("  ERROR: " + job.error) : ""));
  } else if (c == "xabench") {
    // the XA decoder's speed on this chip: a 37.8 kHz stereo sector of noise, ten times
    static xa::Decoder d; d.reset();
    uint8_t *sec = (uint8_t *)malloc(2352); uint32_t *out = (uint32_t *)ps_malloc(xa::MAX_OUT * 4);
    if (sec && out && xaChIn && xaChOut) {
      for (int i = 0; i < 2352; i++) sec[i] = (uint8_t)(i * 37 + 11);
      sec[19] = 0x01;
      for (int ci = 0; ci < 18; ci++) for (int b = 0; b < 8; b++) sec[24 + ci * 128 + 4 + b] = (uint8_t)((b & 3) << 4 | 8);
      uint32_t t0 = micros(); int n = 0;
      for (int k = 0; k < 10; k++) {
        d.begin(sec); n = 0;
        for (int ci = 0; ci < 18; ci++) { memcpy(xaChIn, sec + 24 + ci * 128, 128); n += d.chunk(xaChIn, xaChOut); }
      }
      Serial.printf("  xabench: %u us a sector (%d words), CPU %u MHz\n", (unsigned)((micros() - t0) / 10), n, (unsigned)getCpuFrequencyMhz());
    }
    free(sec); free(out);
  } else if (c == "linkraw") {
    // a status frame's raw bytes at several clocks and both clock phases (the signature
    // A5 first, when all is well)
    const uint32_t hzs[5] = { 250000, 1000000, 2000000, 5000000, 8000000 };
    for (int m = 0; m < 2; m++)
      for (uint32_t hz : hzs) {
        fpgaBus.beginTransaction(SPISettings(hz, MSBFIRST, m ? SPI_MODE1 : SPI_MODE0));
        digitalWrite(PIN_CS, LOW);
        uint8_t rx[5];
        rx[0] = fpgaBus.transfer(CMD_STATUS);
        for (int i = 1; i < 5; i++) rx[i] = fpgaBus.transfer(0x00);
        digitalWrite(PIN_CS, HIGH);
        fpgaBus.endTransaction();
        Serial.printf("  mode %d %7u Hz: %02X %02X %02X %02X %02X\n", m, hz, rx[0], rx[1], rx[2], rx[3], rx[4]);
        delay(5);
      }
  } else if (c == "linkprobe") {
    // the link's wires with the FPGA held in configuration (PROGRAM_B low: its pins let
    // go), then after it has loaded again -- which of the two is pulling a wire
    Serial.println("FPGA running:");
    Serial.print(linkPins());
    if (PIN_PROG_B >= 0) {
      pinMode(PIN_PROG_B, OUTPUT); digitalWrite(PIN_PROG_B, LOW); delay(50);
      Serial.println("FPGA held in configuration (PROGRAM_B low):");
      Serial.print(linkPins());
      pinMode(PIN_PROG_B, INPUT);
      delay(8000);
      Serial.println("FPGA loaded again (8 s later):");
      Serial.print(linkPins());
    }
    fpga.begin(5000000);
    Status st = fpga.status();
    Serial.printf("  status: %s, protocol %u, core %u\n", st.alive ? "answering" : "SILENT", st.version, st.core);
  } else if (c == "pins") {
    Serial.print(bootPins);
  } else if (c == "cores") {
    Serial.println("  " + coreListScan());
  } else if (c.startsWith("disc ")) {
    String path = c.substring(5); path.trim();
    if (!haveCard) { Serial.println("  no card"); return; }
    if (discInsert(path)) Serial.println("  disc in: " + path + ", " + String(discSectors) + " sectors");
    else Serial.println("  cannot open " + path);
  } else if (c == "eject") {
    discEject(); Serial.println("  ejected");
  } else if (c == "disc") {
    CdStatus st = fpga.cdStatus();
    Serial.println("  drive: " + String(st.alive ? "answering" : "SILENT") + ", core " + String(st.core) +
                   (st.disc ? ", disc in" : ", no disc") + (st.running ? ", reading" : ", idle") +
                   ", wants LBA " + String(st.lba) + ", room " + String(st.room));
    Serial.println("  served " + String(discServed) + " sectors, " + String(discMisses) + " card misses, " +
                   String(discIdle) + " idle polls; image " + discPath + " (" + String(discSectors) + " sectors)");
  } else if (c.startsWith("cardtest")) {
    // cardtest <lba> <count> [MHz]: read that stretch of the disc image straight
    // off the card and report what came back, to tell a card or wiring that drops
    // data from one that is merely slow. Ejects the disc for the duration (the
    // drive task must not read the card at the same time), re-mounts the card at
    // the clock asked for, and puts the disc back after. The CRC32 is of the
    // whole stretch, for comparing with the same bytes of the image on the PC.
    uint32_t lba = 0, n = 256, mhz = 0;
    sscanf(c.c_str(), "cardtest %u %u %u", &lba, &n, &mhz);
    String was = discPath;
    readerPause();
    if (discFile) discFile.close();
    if (mhz) { SD.end(); haveCard = SD.begin(PIN_SD_CS, sdBus, mhz * 1000000); listsStale = true; }
    File f = haveCard ? SD.open(was.length() ? was : String("/discs/crash2.bin")) : File();
    if (!f) { Serial.println("  cannot open the image" + String(haveCard ? "" : " (the card did not mount)")); }
    else {
      // (on the heap: static, it was 18 kB of the RAM the Bluetooth stack needs)
      static uint8_t *buf = (uint8_t *)malloc(8 * 2352);
      static const size_t BUFSZ = 8 * 2352;
      uint32_t crc = 0xFFFFFFFF, got = 0, shorts = 0, fails = 0, t0 = millis();
      bool seekOk = f.seek((uint64_t)lba * 2352);
      uint32_t left = n * 2352;
      while (seekOk && left) {
        uint32_t want = left > BUFSZ ? BUFSZ : left;
        int r = f.read(buf, want);
        if (r <= 0) { if (++fails > 20) break; continue; }
        if ((uint32_t)r < want) shorts++;
        for (int i = 0; i < r; i++) {
          crc ^= buf[i];
          for (int k = 0; k < 8; k++) crc = (crc >> 1) ^ (0xEDB88320 & (0u - (crc & 1)));
        }
        got += r; left -= r;
      }
      uint32_t ms = millis() - t0;
      Serial.printf("  %s: %u of %u bytes from LBA %u, %u short reads, %u failed reads, %u ms (%u kB/s), crc32 %08x\n",
                    seekOk ? "read" : "SEEK FAILED", got, n * 2352, lba, shorts, fails, ms,
                    ms ? got / ms : 0, ~crc);
      f.close();
    }
    if (was.length()) discInsert(was);
  } else if (c.startsWith("verify ")) {
    // verify <core>: every page of the slot against the card's file, and where they differ
    String n = c.substring(7); n.trim();
    File f = SD.open("/cores/" + n + ".bin");
    if (!f) { Serial.println("  no such core on the card"); return; }
    static uint8_t want[PAGE], got[PAGE];
    uint32_t pages = (f.size() + PAGE - 1) / PAGE, bad = 0, bytes = 0, failed = 0;
    for (uint32_t i = 0; i < pages; i++) {
      size_t r = f.read(want, PAGE);
      for (size_t k = r; k < PAGE; k++) want[k] = 0xFF;
      if (!fpga.readPage(SLOT_BASE + i * PAGE, got)) { failed++; continue; }
      int diff = 0, first = -1;
      for (int k = 0; k < (int)PAGE; k++) if (want[k] != got[k]) { if (first < 0) first = k; diff++; }
      if (diff) {
        bad++; bytes += diff;
        if (bad <= 12) Serial.printf("  page %u: %d bytes differ, first at %d: wrote %02X read %02X\n", i, diff, first, want[first], got[first]);
      }
    }
    f.close();
    Serial.printf("  %u pages, %u differ (%u bytes), %u reads failed\n", pages, bad, bytes, failed);
  } else if (c.startsWith("install ")) {
    if (job.busy)  { Serial.println("  already busy"); return; }
    if (!haveCard) { Serial.println("  no card"); return; }
    cardCore = c.substring(8); cardCore.trim();
    job.busy = true; job.error = ""; job.stage = "starting";
    if (xTaskCreate(installTask, "install", 8192, nullptr, 1, nullptr) != pdPASS) {
      job.busy = false; job.stage = "";
      Serial.println("  no memory for the install task: pick a game of that console in the menu instead");
      return;
    }
    Serial.println("  installing " + cardCore + " from the card");
  } else if (c == "boot" || c == "core") {
    fpga.boot(true);
    Serial.println("  booting the core");
  } else if (c == "shell") {
    fpga.forceShell();
    Serial.println(PIN_PROG_B >= 0 ? "  pulled PROGRAM_B, back in the shell"
                                   : "  PROGRAM_B is not wired");
  } else if (c.length()) {
    Serial.println("  state | cores | install <name> | boot | shell");
  }
}

void loop() {
  pads::poll();
  if (!xaTaskUp) xaService();                     // (normally its own task: see setup)

  serviceSerial(false);
}

// The serial port, a line at a time. (inUpload is a relic of the web uploads: always false now.)
static String serLine;                  // (the line being gathered)
static String heldCmd[4];               // commands held back, for the loop
static int    heldN = 0;
static void serviceSerial(bool inUpload) {
  if (!inUpload)
    for (int i = 0; i < heldN; i++) serialCommand(heldCmd[i]);
  if (!inUpload) heldN = 0;
  while (Serial.available()) {
    char ch = Serial.read();
    if (ch == char(10) || ch == char(13)) {
      if (serLine.length()) {
        if (!inUpload || serLine[0] == 'P') serialCommand(serLine);   // (a pad line: at once)
        else if (heldN < 4) heldCmd[heldN++] = serLine;               // (the rest: after it)
        serLine = "";
      }
    } else if (serLine.length() < 64) {
      serLine += ch;
    }
  }
}
