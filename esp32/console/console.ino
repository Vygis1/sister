// console.ino - the front door: Wi-Fi, a web page, and six wires to an FPGA.
//
// See esp32/README.md for the wiring and docs/ARCHITECTURE.md for the division
// of labour. The short version: this picks what the board should BE and what it
// should run, and carries neither video nor audio -- 256x240 at 60 Hz is 22 MB/s
// and this chip's Wi-Fi is nowhere near that.
//
// --- joining a network -----------------------------------------------------
//
// It always brings up its own access point, and additionally joins a network if
// it has been told about one. Always, not "only if joining fails": an appliance
// whose control panel disappears when the house Wi-Fi hiccups is worse than
// useless, and on this chip both can run at once for nothing. Credentials are
// typed into the page and kept in NVS, so there is no file to edit and no second
// device involved.
//
//   1. Join the access point "console", password "cartridge"
//   2. Open http://192.168.4.1
//   3. Tell it your Wi-Fi as well, if you want it on the network
//
// --- what it can do --------------------------------------------------------
//
// Everything the shell can: say what the board currently is, install a core into
// the flash slot, and boot it. Cores come off an SD card when one is fitted --
// and there is no card wired yet, which is exactly why the page can also take a
// core straight from the browser.

#include <WiFi.h>
#include <HTTPClient.h>
#include <WebServer.h>
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

static const char *AP_SSID = "console";
static const char *AP_PASS = "cartridge";     // WPA2 wants eight characters

#if CONFIG_IDF_TARGET_ESP32S3
SPIClass fpgaBus(FSPI), sdBus(HSPI);
#else
SPIClass fpgaBus(VSPI), sdBus(HSPI);
#endif
FpgaLink fpga(fpgaBus, PIN_SCK, PIN_MISO, PIN_MOSI, PIN_CS, PIN_PROG_B, PIN_DONE);
WebServer server(80);
Preferences prefs;

bool haveCard = false;

// --- the PlayStation's disc -------------------------------------------------------
// An image on the card (.bin, raw 2352-byte sectors, one data track), served a
// sector at a time to the console image's drive (rtl/cd_feed.v): the board says
// which sector it wants next and how much room it has, this task reads that
// sector off the card and sends it. "disc /discs/crash.bin" over serial or
// POST /api/disc?path=... puts the disc in; "eject" takes it out.
// Two places the bytes can come from: a file on the card, or a URL on the
// PC's web server (its /api/disc/image, which honours HTTP ranges). The URL
// path fetches WINDOW sectors at a time into PSRAM ahead of the drive, since
// one HTTP round trip per sector would not keep up; the card path reads one
// sector at a time, which it can.
static File     discFile;
static String   discPath;                 // a card path, or an http:// URL
static bool     discHttp = false;
static volatile bool discIn = false;
static uint32_t discSectors = 0, discServed = 0, discMisses = 0, discIdle = 0, discFetches = 0;
static uint8_t *discBuf = nullptr;        // one sector, for the card path
static const uint32_t WINDOW = 128;       // sectors buffered ahead of the drive (295 kB in PSRAM)
static uint8_t *discWin = nullptr;        // WINDOW sectors, in PSRAM
static uint32_t winBase = 0, winCount = 0;
static HTTPClient discClient;
static WiFiClient discWifi;

// --- the disc, read the way a file is read ------------------------------------
//
// One connection, opened once and read FORWARD, with a window of sectors
// buffered ahead of the drive in PSRAM; a seek closes it and opens another at
// the new place. Nothing here waits for long: what has not arrived yet is
// simply not served this time round, and the drive asks again a moment later.
//
// It used to fetch a fixed 64-sector block per miss and insist on all of it
// inside four seconds, which over Wi-Fi shared with the frame stream failed
// constantly -- thousands of misses in a session, each one a stall the game
// saw as a drive that had stopped answering.
static WiFiClient *discStream = nullptr;
static uint32_t winBytes = 0;             // how much of the window has arrived

static bool discOpenAt(uint32_t lba) {
  discClient.end();
  discStream = nullptr;
  winBase = lba; winBytes = 0; winCount = 0;
  if (lba >= discSectors) return false;
  discClient.begin(discWifi, discPath);
  discClient.setReuse(true);
  discClient.addHeader("Range", "bytes=" + String((unsigned long long)lba * 2352) + "-");
  int code = discClient.GET();
  if (code != 206 && code != 200) { discClient.end(); return false; }
  discStream = discClient.getStreamPtr();
  discFetches++;
  return true;
}

// Take whatever has arrived, without waiting for anything.
static void discPump() {
  if (!discStream) return;
  const uint32_t cap = (uint32_t)WINDOW * 2352;
  for (int guard = 0; guard < 16 && winBytes < cap; guard++) {
    int avail = discStream->available();
    if (avail <= 0) break;
    int r = discStream->read(discWin + winBytes, min<uint32_t>((uint32_t)avail, cap - winBytes));
    if (r <= 0) break;
    winBytes += (uint32_t)r;
  }
  winCount = winBytes / 2352;
}

// The sector the drive wants, if it is here yet -- from the network stream...
static const uint8_t *discSectorAt(uint32_t lba) {
  // `!discStream` matters: an empty window still LOOKS like it covers sector 0
  // upwards, so without it nothing ever opened a connection at all
  if (!discStream || lba < winBase || lba >= winBase + WINDOW) {
    if (discStream && lba == winBase + winCount && (winBytes % 2352) == 0) {
      winBase = lba; winBytes = 0; winCount = 0;    // walked past the window: slide it, same connection
    } else if (!discOpenAt(lba)) {
      return nullptr;                               // a seek
    }
  }
  discPump();
  if (lba < winBase + winCount) return discWin + (lba - winBase) * 2352;
  return nullptr;
}

// ...or straight off the card, by a task of its own.
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
    if (!discIn || discHttp || !discWin) { vTaskDelay(10 / portTICK_PERIOD_MS); continue; }
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
  if (!xaPend || discHttp || millis() - xaLast < 4) return;
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
      if (discHttp) discPump(); else rdWant = st.lba;                  // idle time is read-ahead time
      vTaskDelay(1); continue;
    }
    const uint8_t *sec = discHttp ? discSectorAt(st.lba) : discSectorCard(st.lba);
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
// --- putting a disc image on the card, over the air, once -------------------------
//
// 632 MB does not belong on a Wi-Fi link every time the console reads a sector.
// This fetches the image to the card in one go, resuming where it left off if
// the connection drops, and after that the disc is a file on the card and the
// network has nothing to do with the game at all.
static String   fetchUrl, fetchPath, fetchErr;
static volatile bool fetchBusy = false;
static volatile bool listsStale = true;   // the card's listings need reading again (see refreshLists)
static volatile bool cardChanged = false; // ...and the TV menu's: a file came or went (menu.h rescans)
static volatile uint64_t fetchDone = 0, fetchTotal = 0;
static volatile uint32_t fetchStalls = 0;

static void fetchTask(void *) {
  HTTPClient h; WiFiClient w;
  h.begin(w, fetchUrl);
  int code = h.sendRequest("HEAD");
  fetchTotal = (code == 200) ? (uint64_t)h.getSize() : 0;
  h.end();
  if (!fetchTotal) { fetchErr = "the server did not say how big it is"; fetchBusy = false; vTaskDelete(nullptr); return; }

  SD.mkdir("/discs");
  // what is already there is kept: a transfer this long should not start again
  // from nothing because the link hiccupped
  uint64_t have = 0;
  { File e = SD.open(fetchPath, FILE_READ); if (e) { have = e.size(); e.close(); } }
  if (have > fetchTotal) have = 0;
  fetchDone = have;
  File f = SD.open(fetchPath, have ? FILE_APPEND : FILE_WRITE);
  if (!f) { fetchErr = "cannot write " + fetchPath; fetchBusy = false; vTaskDelete(nullptr); return; }

  // INTERNAL ram, not PSRAM: the card driver hands the buffer to SPI DMA, which
  // cannot reach PSRAM, and the write comes back short -- which is exactly how
  // the first attempt died twelve megabytes in.
  const size_t bufsz = 8192;
  uint8_t *buf = (uint8_t *)malloc(bufsz);
  if (!buf) { fetchErr = "no room for a buffer"; fetchBusy = false; vTaskDelete(nullptr); return; }
  for (int attempt = 0; attempt < 5000 && fetchDone < fetchTotal && !fetchErr.length(); attempt++) {
    HTTPClient g; WiFiClient gw;
    { File e = SD.open(fetchPath, FILE_READ); if (e) { fetchDone = e.size(); e.close(); } }
    g.begin(gw, fetchUrl);
    g.addHeader("Range", "bytes=" + String((unsigned long long)fetchDone) + "-");
    int c = g.GET();
    if (c != 206 && c != 200) { g.end(); vTaskDelay(500 / portTICK_PERIOD_MS); continue; }
    WiFiClient *st = g.getStreamPtr();
    uint32_t idle = millis();
    while (fetchDone < fetchTotal) {
      int avail = st->available();
      if (avail <= 0) {
        if (millis() - idle > 8000) break;
        vTaskDelay(1); continue;
      }
      int r = st->read(buf, (size_t)avail < bufsz ? (size_t)avail : bufsz);
      if (r <= 0) break;
      // A card pauses for its own housekeeping -- erase blocks, wear levelling --
      // and a pause can last a good fraction of a second. Sixteen milliseconds
      // of patience called that a dead card and gave up 130 MB in; this waits
      // two seconds, and if it still will not take the bytes it reopens the
      // file and carries on from where it got to rather than throwing the
      // transfer away.
      size_t put = 0, tries = 0;
      while (put < (size_t)r && tries < 200) {
        size_t n = f.write(buf + put, (size_t)r - put);
        if (n == 0) { tries++; vTaskDelay(10 / portTICK_PERIOD_MS); } else { put += n; tries = 0; }
      }
      if (put < (size_t)r) {
        // How much actually landed is what the FILE says, not what write()
        // claimed: counting the accepted bytes left the file a few short at
        // every stall, and six stalls made the image six sectors shy -- every
        // sector after the first one shifted, so the disc would not read at all.
        f.close(); vTaskDelay(250 / portTICK_PERIOD_MS);
        { File e = SD.open(fetchPath, FILE_READ); fetchDone = e ? e.size() : fetchDone; if (e) e.close(); }
        f = SD.open(fetchPath, FILE_APPEND);
        if (!f) { fetchErr = "the card stopped answering at " + String((double)fetchDone, 0); }
        fetchStalls++;
        break;                        // out to the outer loop: reconnect and resume
      }
      fetchDone += (uint64_t)r;
      if ((fetchDone & 0xFFFFF) < (uint64_t)r) f.flush();
      idle = millis();
      // hand the processor back every chunk: this task and the web server sit
      // on the same core at the same priority, and a tight read-write loop
      // simply stops the page and every status query with it
      vTaskDelay(1);
    }
    g.end();
    if (fetchErr.length()) break;
  }
  f.close();
  if (buf) free(buf);
  // the last word on whether it is whole: the size on the card
  { File e = SD.open(fetchPath, FILE_READ); if (e) { fetchDone = e.size(); e.close(); } }
  if (fetchDone != fetchTotal && !fetchErr.length())
    fetchErr = "short by " + String((double)(fetchTotal - fetchDone), 0) + " bytes";
  fetchBusy = false;
  listsStale = true;                                     // a new image in /discs
  vTaskDelete(nullptr);
}

// --- checking the copy, block by block, and repairing what is wrong ---------------
//
// A byte count proves nothing: a card that pauses mid-write, a link that drops,
// a resume that starts in the wrong place all produce a file of the right
// length and the wrong contents, and the first thing that notices is the
// console failing to read its disc. So the image is checked a megabyte at a
// time against CRCs from the source, and any block that disagrees is fetched
// again and checked again.
static uint32_t crcTab[256];
static bool     crcReady = false;
static void crcInit() {
  for (uint32_t i = 0; i < 256; i++) {
    uint32_t c = i;
    for (int k = 0; k < 8; k++) c = (c & 1) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
    crcTab[i] = c;
  }
  crcReady = true;
}
static uint32_t crc32_of(const uint8_t *d, size_t n, uint32_t crc = 0) {
  if (!crcReady) crcInit();
  crc = ~crc;
  while (n--) crc = crcTab[(crc ^ *d++) & 0xFF] ^ (crc >> 8);
  return ~crc;
}

static String   verifyErr;
static volatile bool     verifyBusy = false;
static volatile uint32_t verifyTotal = 0, verifyChecked = 0, verifyBad = 0, verifyFixed = 0;

// one block of the image, straight into the file at its own offset
static bool refetchBlock(File &f, uint32_t idx, uint32_t block, uint32_t len, uint8_t *buf, size_t bufsz) {
  uint64_t from = (uint64_t)idx * block;
  HTTPClient g; WiFiClient gw;
  g.begin(gw, fetchUrl);
  g.addHeader("Range", "bytes=" + String((unsigned long long)from) + "-" + String((unsigned long long)(from + len - 1)));
  int c = g.GET();
  if (c != 206 && c != 200) { g.end(); return false; }
  WiFiClient *st = g.getStreamPtr();
  if (!f.seek(from)) { g.end(); return false; }
  uint32_t got = 0, idle = millis();
  while (got < len) {
    int avail = st->available();
    if (avail <= 0) { if (millis() - idle > 8000) break; vTaskDelay(1); continue; }
    int r = st->read(buf, (size_t)avail < bufsz ? (size_t)avail : bufsz);
    if (r <= 0) break;
    uint32_t n = (got + (uint32_t)r > len) ? len - got : (uint32_t)r;
    size_t put = 0, tries = 0;
    while (put < n && tries < 200) {
      size_t w = f.write(buf + put, n - put);
      if (w == 0) { tries++; vTaskDelay(10 / portTICK_PERIOD_MS); } else { put += w; tries = 0; }
    }
    if (put < n) { g.end(); return false; }
    got += n; idle = millis(); vTaskDelay(1);
  }
  g.end(); f.flush();
  return got == len;
}

static void verifyTask(void *) {
  verifyErr = ""; verifyChecked = 0; verifyBad = 0; verifyFixed = 0; verifyTotal = 0;
  // the list of block CRCs from the source
  String crcUrl = fetchUrl; crcUrl.replace("/image", "/crc32");
  HTTPClient h; WiFiClient w;
  h.begin(w, crcUrl);
  if (h.GET() != 200) { verifyErr = "cannot read the checksums"; h.end(); verifyBusy = false; vTaskDelete(nullptr); return; }
  String body = h.getString(); h.end();
  int n1 = body.indexOf('\n'), n2 = body.indexOf('\n', n1 + 1);
  if (n1 < 0 || n2 < 0) { verifyErr = "the checksums did not parse"; verifyBusy = false; vTaskDelete(nullptr); return; }
  uint64_t want = strtoull(body.substring(0, n1).c_str(), nullptr, 10);
  uint32_t block = (uint32_t)strtoul(body.substring(n1 + 1, n2).c_str(), nullptr, 10);
  String list = body.substring(n2 + 1);
  uint32_t nblocks = (uint32_t)((want + block - 1) / block);
  uint32_t *crcs = (uint32_t *)ps_malloc(nblocks * 4);
  if (!crcs) { verifyErr = "no room for the checksums"; verifyBusy = false; vTaskDelete(nullptr); return; }
  { int p = 0; for (uint32_t i = 0; i < nblocks; i++) {
      int c = list.indexOf(',', p);
      crcs[i] = (uint32_t)strtoul((c < 0 ? list.substring(p) : list.substring(p, c)).c_str(), nullptr, 16);
      if (c < 0) break; p = c + 1; } }
  verifyTotal = nblocks;

  File f = SD.open(fetchPath, "r+");
  if (!f) { verifyErr = "cannot open " + fetchPath; free(crcs); verifyBusy = false; vTaskDelete(nullptr); return; }
  if (f.size() != want) { verifyErr = "the file is " + String((double)f.size(), 0) + " bytes, not " + String((double)want, 0); }

  const size_t bufsz = 8192;
  uint8_t *buf = (uint8_t *)malloc(bufsz);
  for (uint32_t i = 0; i < nblocks && !verifyErr.length(); i++) {
    uint32_t len = (uint32_t)((i + 1) * (uint64_t)block <= want ? block : want - (uint64_t)i * block);
    for (int attempt = 0; attempt < 3; attempt++) {
      if (!f.seek((uint64_t)i * block)) { verifyErr = "seek failed"; break; }
      uint32_t crc = 0, got = 0;
      while (got < len) {
        size_t nread = f.read(buf, (len - got) < bufsz ? (len - got) : bufsz);
        if (nread == 0) break;
        crc = crc32_of(buf, nread, crc);
        got += nread;
      }
      vTaskDelay(1);
      if (got == len && crc == crcs[i]) break;              // this block is good
      verifyBad++;
      if (attempt == 2) { verifyErr = "block " + String(i) + " will not come good"; break; }
      if (!refetchBlock(f, i, block, len, buf, bufsz)) { vTaskDelay(500 / portTICK_PERIOD_MS); continue; }
      verifyFixed++;
    }
    verifyChecked = i + 1;
  }
  f.close(); free(buf); free(crcs);
  verifyBusy = false;
  vTaskDelete(nullptr);
}

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
  File nf;
  if (!path.startsWith("http://")) {
    nf = SD.open(path);
    if (!nf) return false;
  }
  readerPause();
  if (discFile) discFile.close();
  discHttp = path.startsWith("http://");
  if (discHttp) {
    // An http:// image needs the network to be up. Asked for one before it is
    // -- which is what the boot-time restore below used to do with a remembered
    // URL -- HTTPClient takes a semaphore the TCP/IP stack has not created yet,
    // FreeRTOS asserts, and the chip reboots. Forever: the crash happens in
    // setup(), so loop() never runs and the serial console never appears, which
    // leaves no way in at all. Refuse instead of reaching for the stack.
    if (WiFi.status() != WL_CONNECTED) return false;
    HTTPClient h; WiFiClient w;
    h.begin(w, path);
    int code = h.sendRequest("HEAD");
    if (code != 200) { h.end(); return false; }
    discSectors = (uint32_t)(h.getSize() / 2352);
    h.end();
    if (!discWin) discWin = (uint8_t *)ps_malloc(WINDOW * 2352);
    if (!discWin) return false;
    winBase = 0; winCount = 0;
  } else {
    discFile = nf;
    discSectors = discFile.size() / 2352;
    if (!discWin) discWin = (uint8_t *)ps_malloc(WINDOW * 2352);
    if (!discWin) return false;
    winBase = 0; winCount = 0; winBytes = 0;
    ringClear();
  }
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

// --- why a join failed ------------------------------------------------------------
//
// WiFi.status() only ever says "not connected", which covers a wrong password, a
// network that was not there, and a router that accepted the password and then
// timed out the handshake. Those are three different problems and the chip knows
// which one it hit -- the reason code arrives with the disconnect event, and is
// thrown away unless somebody catches it.
volatile int lastWifiReason = 0;

static const char *wifiReasonText(int r) {
  switch (r) {
    case 15:  return "four-way handshake timed out -- almost always the wrong password";
    case 201: return "no access point with that name was found -- check the spelling and the case";
    case 202: return "authentication failed -- the wrong password";
    case 203: return "association failed -- the router refused the connection";
    case 204: return "handshake timed out";
    case 205: return "connection failed";
    case 2:   return "authentication expired";
    case 3:   return "the router deauthenticated us";
    case 4:   return "association expired";
    case 8:   return "the router disassociated us (it may have moved us to another band)";
    case 0:   return "no reason recorded yet";
    default:  return "see esp_wifi_types.h for this reason code";
  }
}
SdProbe sdInfo;          // what the card itself said, filesystem aside
String  sdWhy;           // one line explaining the state, for the page

// --- one job at a time, reported while it runs --------------------------------
// Installing a core is a minute of flash erases and thousands of page writes. An
// HTTP request that simply blocked for that long would look like a hang and time
// out in most browsers, so the work reports progress and the page asks.
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
static String romListScan() {
  String j = "[";
  if (haveCard) {
    File dir = SD.open("/roms");
    while (dir) {
      File e = dir.openNextFile();
      if (!e) break;
      String n = String(e.name());
      int slash = n.lastIndexOf('/');
      if (slash >= 0) n = n.substring(slash + 1);
      // Everything except the dotfiles a desktop leaves behind. Which machine a
      // ROM belongs to is decided by its CONTENTS when it is loaded -- an iNES
      // header, "SEGA" at $100 -- so the extension is not authority here and
      // filtering on it would only reject things that work.
      if (!e.isDirectory() && n.length() && n[0] != '.') {
        if (j.length() > 1) j += ",";
        j += "{\"name\":\"" + jsonEscape(n) +
             "\",\"size\":" + String((uint32_t)e.size()) + "}";
      }
      e.close();
    }
    if (dir) dir.close();
  }
  return j + "]";
}

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

// The two listings, kept. Reading them off the card is one openNextFile() per
// file, and with 272 games in /roms that took 8.5 seconds -- on every call to
// /api/state, which the page makes all the time, so the page looked hung.
// They only change when something is uploaded, which marks them stale.
static String romCache, coreCache, discCache;
// Disc images in /discs: the ones the drive can take (raw 2352-byte sectors).
static String discListScan() {
  String j = "[";
  if (haveCard) {
    File dir = SD.open("/discs");
    while (dir) {
      File e = dir.openNextFile();
      if (!e) break;
      String n = String(e.name());
      int slash = n.lastIndexOf('/');
      if (slash >= 0) n = n.substring(slash + 1);
      String low = n; low.toLowerCase();
      if (!e.isDirectory() && n[0] != '.' && low.endsWith(".bin")) {
        if (j.length() > 1) j += ",";
        j += "{\"name\":\"" + jsonEscape(n) + "\",\"size\":" + String((double)e.size(), 0) + "}";
      }
      e.close();
    }
    if (dir) dir.close();
  }
  return j + "]";
}
// One scan at a time: the boot-time scan below and a page asking for /api/state
// must not both walk the card and both write the caches. Whoever loses just
// uses what is cached (empty at first) and the page asks again.
static SemaphoreHandle_t listsLock = nullptr;
static void refreshLists() {
  if (!listsStale || !listsLock || xSemaphoreTake(listsLock, 0) != pdTRUE) return;
  listsStale = false;
  String r = romListScan(), c = coreListScan(), d = discListScan();
  romCache = r; coreCache = c; discCache = d;
  xSemaphoreGive(listsLock);
}
// At boot, off the web server's back: the first scan takes seconds on a card
// full of games, and the first page load should not be the one that waits.
static void listTask(void *) { refreshLists(); vTaskDelete(nullptr); }
static String romListJson()  { refreshLists(); return romCache; }
static String coreListJson() { refreshLists(); return coreCache; }

// --- the API -------------------------------------------------------------------
static void apiState() {
  Status s = fpga.status();
  String j = "{";
  j += "\"alive\":"    + String(s.alive ? "true" : "false");
  j += ",\"version\":" + String(s.version);
  j += ",\"core\":"    + String(s.core);
  j += ",\"busy\":"    + String(s.busy ? "true" : "false");
  j += ",\"card\":"    + String(haveCard ? "true" : "false");
  j += ",\"cardWhy\":\"" + jsonEscape(sdWhy) + "\"";
  j += ",\"roms\":" + romListJson();
  j += ",\"ap\":\""    + WiFi.softAPIP().toString() + "\"";
  j += ",\"sta\":\""   + (WiFi.status() == WL_CONNECTED
                          ? WiFi.localIP().toString() : String("")) + "\"";
  j += ",\"ssid\":\""  + jsonEscape(WiFi.SSID()) + "\"";
  j += ",\"rssi\":"    + String(WiFi.status() == WL_CONNECTED ? WiFi.RSSI() : 0);
  j += ",\"job\":{\"busy\":" + String(job.busy ? "true" : "false");
  j += ",\"stage\":\"" + jsonEscape(job.stage) + "\"";
  j += ",\"done\":"    + String(job.done);
  j += ",\"total\":"   + String(job.total);
  j += ",\"error\":\"" + jsonEscape(job.error) + "\"}";
  j += ",\"cores\":"   + coreListJson();
  refreshLists();
  j += ",\"discs\":" + discCache;
  j += ",\"disc\":{\"in\":" + String(discIn ? "true" : "false");
  j += ",\"path\":\"" + jsonEscape(discPath) + "\"";
  j += ",\"sectors\":" + String(discSectors);
  j += ",\"served\":"  + String(discServed);
  j += ",\"misses\":"  + String(discMisses) + "}";
  j += ",\"fetch\":{\"busy\":" + String(fetchBusy ? "true" : "false")
     + ",\"done\":" + String((double)fetchDone, 0) + ",\"total\":" + String((double)fetchTotal, 0)
     + ",\"stalls\":" + String(fetchStalls) + ",\"error\":\"" + fetchErr + "\"}";
  j += ",\"verify\":{\"busy\":" + String(verifyBusy ? "true" : "false")
     + ",\"checked\":" + String(verifyChecked) + ",\"blocks\":" + String(verifyTotal)
     + ",\"bad\":" + String(verifyBad) + ",\"fixed\":" + String(verifyFixed)
     + ",\"error\":\"" + verifyErr + "\"}";
  j += "}";
  server.send(200, "application/json", j);
}

static void apiScan() {
  int n = WiFi.scanNetworks();
  String j = "[";
  for (int i = 0; i < n && i < 20; i++) {
    if (j.length() > 1) j += ",";
    j += "{\"ssid\":\"" + jsonEscape(WiFi.SSID(i)) + "\",\"rssi\":" +
         String(WiFi.RSSI(i)) + ",\"open\":" +
         String(WiFi.encryptionType(i) == WIFI_AUTH_OPEN ? "true" : "false") + "}";
  }
  WiFi.scanDelete();
  server.send(200, "application/json", j + "]");
}

static void apiJoin() {
  String ssid = server.arg("ssid"), pass = server.arg("pass");
  if (!ssid.length()) { server.send(400, "text/plain", "no network given"); return; }

  prefs.begin("net", false);
  prefs.putString("ssid", ssid);
  prefs.putString("pass", pass);
  prefs.end();

  // The access point stays up throughout. Losing the control panel while
  // testing a password would mean losing the way to correct it.
  WiFi.begin(ssid.c_str(), pass.c_str());
  uint32_t t0 = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - t0 < 12000) delay(200);

  if (WiFi.status() == WL_CONNECTED)
    server.send(200, "text/plain", WiFi.localIP().toString());
  else
    server.send(502, "text/plain", "could not join that network");
}

static void apiForget() {
  prefs.begin("net", false);
  prefs.clear();
  prefs.end();
  WiFi.disconnect(false, true);
  server.send(200, "text/plain", "ok");
}

static void apiBoot() {
  fpga.boot(server.arg("core") == "1");
  server.send(200, "text/plain", "ok");
}

static void apiShell() {
  fpga.forceShell();
  server.send(200, "text/plain",
              PIN_PROG_B >= 0 ? "ok" : "PROGRAM_B is not wired - power-cycle instead");
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

static void apiInstallCard() {
  if (job.busy)  { server.send(409, "text/plain", "already busy"); return; }
  if (!haveCard) { server.send(409, "text/plain", "no card fitted"); return; }
  cardCore = server.arg("core");
  job.busy = true; job.error = ""; job.stage = "starting"; job.done = job.total = 0;
  // (the task's stack comes out of internal RAM, which the menu, Bluetooth and the XA decoder
  // leave in pieces: when it is not there, say so -- unchecked, the job stayed "starting" and
  // busy for ever, and every install after it was refused. Picking a game installs from inside
  // the menu's own task when the card's core differs from the slot's, which always works.)
  if (xTaskCreatePinnedToCore(installTask, "install", 8192, nullptr, 1, nullptr, 1) != pdPASS) {
    job.busy = false; job.stage = ""; job.error = "no memory for the install task: pick a game of that console in the menu instead";
    server.send(503, "text/plain", job.error); return;
  }
  server.send(200, "text/plain", "ok");
}

// --- adding a core to the card's library ----------------------------------------
//
// Uploading to the FLASH installs one core and replaces whatever was there.
// Uploading to the CARD adds to the library, so the machine can be changed again
// later without a computer. They are different operations and the difference is
// worth a separate endpoint.
//
// Without this, every rebuilt core means unplugging the card, carrying it to a
// PC and carrying it back -- which rather undoes the point of the thing being
// standalone.
static void serviceSerial(bool inUpload);
static void serviceDuringUpload();     // (below: the pads and the serial port, kept going)

static File    libFile;
static uint32_t libBytes;               // this upload's own count (job.done is shared)
static bool    libFailed;
static String  libName;
static String  libPath;
static bool    libIsRom;

static void onLibraryUpload() {
  HTTPUpload &u = server.upload();

  if (u.status == UPLOAD_FILE_START) {
    libFailed = false;
    if (!haveCard) { libFailed = true; job.error = "no card fitted"; return; }
    libName = u.filename;
    // A core is a bitstream and goes in /cores as <name>.bin, because that is
    // the one directory and one extension the core listing looks at. A game
    // keeps whatever name and extension it arrived with, because nothing here
    // decides what machine it is from its name -- the loader reads the bytes.
    if (libIsRom) {
      SD.mkdir("/roms");
      libPath = "/roms/" + libName;
      // (a name with a folder in it -- "ps1/Some Disc.bin" -- gets the folder made)
      int slash = libPath.lastIndexOf('/');
      if (slash > 5) SD.mkdir(libPath.substring(0, slash));
    } else {
      if (libName.endsWith(".bin"))
        libName = libName.substring(0, libName.length() - 4);
      SD.mkdir("/cores");
      libPath = "/cores/" + libName + ".bin";
    }
    SD.remove(libPath);
    libFile = SD.open(libPath, FILE_WRITE);
    if (!libFile) { libFailed = true; job.error = "could not create " + libPath; }
    job.stage = libIsRom ? "saving the game to the card" : "saving to the card";
    job.done = 0; job.total = 0; libBytes = 0;

  } else if (u.status == UPLOAD_FILE_WRITE && !libFailed) {
    // A short write is not necessarily a failure. The card disappears into an
    // internal erase now and then and takes what it can in the meantime, so the
    // remainder is offered again rather than treated as the end of the world.
    size_t done = 0;
    for (int tries = 0; done < u.currentSize && tries < 200; tries++) {
      size_t n = libFile.write(u.buf + done, u.currentSize - done);
      done += n;
      if (n == 0) delay(2);
    }
    if (done < u.currentSize) {
      libFailed = true;
      job.error = "the card stopped accepting data after " +
                  String((uint32_t)job.done / 1024) + " kB (" +
                  String((double)(SD.totalBytes() - SD.usedBytes()) / 1048576.0, 0) +
                  " MB free, " + String(ESP.getFreeHeap() / 1024) + " kB heap)";
      libFile.close();
      SD.remove(libPath);
      return;
    }
    job.done += u.currentSize; libBytes += u.currentSize;
    serviceDuringUpload();
    // Every 64 kB. FatFs keeps a sector buffer and a dirty FAT; left alone
    // across a megabyte of streaming those turn into one enormous flush at the
    // end, and the writes before it start failing short.
    if ((libBytes & 0xFFFF) < u.currentSize) libFile.flush();

  } else if (u.status == UPLOAD_FILE_END) {
    listsStale = true; cardChanged = true;               // a file came or went
    if (libFile) {
      libFile.flush();
      uint32_t wrote = libFile.size();
      libFile.close();
      // A core that is short is a core that will not configure, and it looks
      // exactly like a good one in a directory listing. Delete it rather than
      // leave something installable that cannot work.
      if (wrote != libBytes) {
        libFailed = true;
        job.error = "wrote " + String(wrote) + " of " + String(libBytes) +
                    " bytes - removed the partial file";
        SD.remove(libPath);
      }
    }
    if (!libFailed) job.stage = "on the card";
  }
}

// --- a file to the card a piece at a time ------------------------------------------------
// POST /api/put?path=/roms/ps1/X.bin&off=N with one file part: those bytes, written at N.
// A whole disc in one upload over this chip's Wi-Fi (shared with Bluetooth) failed part way
// and started again from nothing; a piece that fails is sent again by itself, and
// GET /api/stat?path= says how far a file got, so a stopped copy carries on.
// GET /api/crc?path=&off=&len= is the CRC-32 of what the card holds there, for the sender
// to check each piece against what it sent.
static File     putFile;
static bool     putFailed;
static String   putPath, putErr;
static uint32_t putOff, putBytes;

static bool putPathOk(const String &p) {
  return (p.startsWith("/roms/") || p.startsWith("/cores/")) && p.indexOf("..") < 0;
}

static void onPutUpload() {
  HTTPUpload &u = server.upload();
  if (u.status == UPLOAD_FILE_START) {
    putFailed = false; putErr = ""; putBytes = 0;
    putPath = server.arg("path"); putOff = (uint32_t)strtoul(server.arg("off").c_str(), nullptr, 10);
    if (!haveCard)            { putFailed = true; putErr = "no card fitted"; return; }
    if (!putPathOk(putPath))  { putFailed = true; putErr = "the path must be under /roms or /cores"; return; }
    // the folders on the way (one level at a time: SD.mkdir does not make parents)
    for (int i = 1; (i = putPath.indexOf('/', i)) > 0; i++) SD.mkdir(putPath.substring(0, i));
    if (putOff == 0) { SD.remove(putPath); putFile = SD.open(putPath, FILE_WRITE); }
    else {
      putFile = SD.open(putPath, "r+");
      if (putFile && putFile.size() < putOff) { putFile.close(); putFailed = true; putErr = "the file is shorter than the offset"; return; }
      if (putFile) putFile.seek(putOff);
    }
    if (!putFile) { putFailed = true; putErr = "could not open " + putPath; }
  } else if (u.status == UPLOAD_FILE_WRITE && !putFailed) {
    size_t done = 0;
    for (int tries = 0; done < u.currentSize && tries < 200; tries++) {   // (the card pauses to erase now and then)
      size_t n = putFile.write(u.buf + done, u.currentSize - done);
      done += n;
      if (n == 0) delay(2);
    }
    putBytes += done;
    serviceDuringUpload();
    if (done < u.currentSize) { putFailed = true; putErr = "the card stopped taking data"; putFile.close(); }
  } else if (u.status == UPLOAD_FILE_END) {
    if (putFile) { putFile.flush(); putFile.close(); }
    listsStale = true; cardChanged = true;
  } else if (u.status == UPLOAD_FILE_ABORTED) {
    if (putFile) putFile.close();
    putFailed = true; putErr = "the upload was cut off";
  }
}

static void putReply() {
  if (putFailed) { server.send(500, "text/plain", putErr); return; }
  File f = SD.open(putPath);
  uint32_t size = f ? (uint32_t)f.size() : 0;
  if (f) f.close();
  server.send(200, "application/json", "{\"wrote\":" + String(putBytes) + ",\"size\":" + String(size) + "}");
}

static void statReply() {
  String p = server.arg("path");
  if (!haveCard || !putPathOk(p)) { server.send(400, "text/plain", "bad path"); return; }
  File f = SD.open(p);
  if (!f) { server.send(200, "application/json", "{\"size\":-1}"); return; }
  uint32_t size = (uint32_t)f.size(); f.close();
  server.send(200, "application/json", "{\"size\":" + String(size) + "}");
}

static void crcReply() {
  String p = server.arg("path");
  uint32_t off = (uint32_t)strtoul(server.arg("off").c_str(), nullptr, 10);
  uint32_t len = (uint32_t)strtoul(server.arg("len").c_str(), nullptr, 10);
  if (!haveCard || !putPathOk(p)) { server.send(400, "text/plain", "bad path"); return; }
  File f = SD.open(p);
  if (!f) { server.send(404, "text/plain", "no such file"); return; }
  if (off > f.size()) { f.close(); server.send(400, "text/plain", "offset past the end"); return; }
  if (len == 0 || off + len > f.size()) len = f.size() - off;
  f.seek(off);
  static uint8_t *buf = nullptr;
  if (!buf) buf = (uint8_t *)ps_malloc(32768);
  if (!buf) { f.close(); server.send(500, "text/plain", "no memory"); return; }
  uint32_t crc = 0, left = len;
  while (left) {
    int n = f.read(buf, left < 32768 ? left : 32768);
    if (n <= 0) break;
    crc = esp_rom_crc32_le(crc, buf, n);
    left -= n;
  }
  f.close();
  if (left) { server.send(500, "text/plain", "the card would not read it all"); return; }
  char hex[12]; snprintf(hex, sizeof hex, "%08x", (unsigned)crc);
  server.send(200, "application/json", "{\"crc\":\"" + String(hex) + "\",\"len\":" + String(len) + "}");
}

// --- installing from the browser -----------------------------------------------
// Straight through to the flash as the upload arrives, rather than buffering two
// megabytes in RAM this chip would rather spend on something else. There is no
// SD card wired yet, so on day one this is the only way to get a core in.
static uint32_t upPage, upFill;
static uint8_t  upBuf[PAGE];
static bool     upFailed;

static void onUpload() {
  HTTPUpload &u = server.upload();

  if (u.status == UPLOAD_FILE_START) {
    job.busy = true; job.error = ""; job.stage = "erasing";
    job.done = 0; job.total = 0;
    upPage = upFill = 0;
    upFailed = false;
    // The size is not known in advance, so the whole slot's worth of sectors
    // cannot be erased up front without erasing 6 MB. Erase lazily instead: the
    // first page of each sector clears that sector, just before it is needed.
    job.stage = "writing";

  } else if (u.status == UPLOAD_FILE_WRITE && !upFailed) {
    size_t i = 0;
    while (i < u.currentSize) {
      size_t take = PAGE - upFill;
      if (take > u.currentSize - i) take = u.currentSize - i;
      memcpy(upBuf + upFill, u.buf + i, take);
      upFill += take;
      i += take;

      if (upFill == PAGE) {
        uint32_t off = upPage * PAGE;
        if ((off % SECTOR) == 0 && !fpga.eraseSector(off)) {
          job.error = "the flash never finished erasing at " + String(off);
          upFailed = true;
          return;
        }
        if (!fpga.writePage(off, upBuf, PAGE)) {
          job.error = "the flash never finished writing page " + String(upPage);
          upFailed = true;
          return;
        }
        upPage++;
        job.done = upPage;
        upFill = 0;
      }
    }

  } else if (u.status == UPLOAD_FILE_END) {
    if (!upFailed && upFill) {
      uint32_t off = upPage * PAGE;
      for (uint32_t k = upFill; k < PAGE; k++) upBuf[k] = 0xFF;
      if ((off % SECTOR) == 0) fpga.eraseSector(off);
      if (fpga.writePage(off, upBuf, PAGE)) upPage++;
    }
    job.total = upPage;

    // Read it all back before anyone is allowed to boot it.
    if (!upFailed) {
      job.stage = "verifying";
      job.done = 0;
      // Nothing to compare against any more -- the upload has been consumed --
      // so check the one thing that must be true of any configuration image:
      // the sync word is in the first page, and the slot is not simply erased.
      static uint8_t got[PAGE];
      if (!fpga.readPage(SLOT_BASE, got)) {
        job.error = "could not read the slot back";
      } else {
        bool sync = false;
        for (int k = 0; k + 3 < (int)PAGE; k++)
          if (got[k] == 0xAA && got[k+1] == 0x99 &&
              got[k+2] == 0x55 && got[k+3] == 0x66) { sync = true; break; }
        if (!sync)
          job.error = "no bitstream sync word in the slot after writing";
        else
          job.stage = "done";
      }
      job.done = job.total;
    }
    job.busy = false;
  }
}

extern const char PAGE_HTML[] PROGMEM;

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
  // nothing over 3 kB, Wi-Fi could not get a packet buffer and the chip fell off the network
  // (2026-10-10, T8 with a DualShock 4 in). Wi-Fi, Bluetooth and task stacks still take
  // internal RAM: they ask for it by name.
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
  // 20 MHz, not the library's default 4. At 4 MHz the card cannot absorb an
  // upload as fast as Wi-Fi delivers it, and the write fails partway through a
  // couple of megabytes -- which presents as "the card is full" on a card with
  // 238 GB free.
  // 8 MHz, not 20: the card answers its init at 20 over these jumpers, and then
  // drops bytes on a sustained write -- a 632 MB disc image died at twelve and
  // then at seventeen megabytes. Reads for the drive need 300 kB/s; this gives
  // several times that with margin.
#if CONFIG_IDF_TARGET_ESP32S3
  haveCard = sdInfo.responded && SD.begin(PIN_SD_CS, sdBus, 8000000);
#else
  // (the T8: its card is in its own slot on the board, not on jumpers -- 20 MHz. Double-speed
  // discs need ~700 kB/s, which 8 MHz could barely give; an upload is checked piece by piece)
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
  listsLock = xSemaphoreCreateMutex();
  xTaskCreatePinnedToCore(listTask, "lists", 8192, nullptr, 1, nullptr, 1);
  // A disc on the CARD can go back in now. One served over http:// cannot:
  // Wi-Fi is not up until further down, so that one is put back after the join.
  { String was = discRecall();
    if (was.length() && !was.startsWith("http://")) {
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
    Serial.println("    cores can still be uploaded from the page");
  }

  WiFi.onEvent([](WiFiEvent_t, WiFiEventInfo_t info) {
    lastWifiReason = info.wifi_sta_disconnected.reason;
  }, ARDUINO_EVENT_WIFI_STA_DISCONNECTED);

  // Both at once, always. See the note at the top of this file.
  WiFi.mode(WIFI_AP_STA);
  WiFi.softAP(AP_SSID, AP_PASS);
  Serial.printf("access point \"%s\", password \"%s\", at %s\n",
                AP_SSID, AP_PASS, WiFi.softAPIP().toString().c_str());

  prefs.begin("net", true);
  String ssid = prefs.getString("ssid", "");
  String pass = prefs.getString("pass", "");
  prefs.end();
  if (ssid.length()) {
    Serial.printf("joining %s...\n", ssid.c_str());
    WiFi.begin(ssid.c_str(), pass.c_str());
    uint32_t t0 = millis();
    // Fifteen seconds, not ten. A router that is doing band steering or WPA2/WPA3
    // negotiation can take its time, and a timeout that is merely too short
    // reports itself as a failure to connect.
    while (WiFi.status() != WL_CONNECTED && millis() - t0 < 15000) delay(200);
    if (WiFi.status() != WL_CONNECTED)
      Serial.println("  reason: " + String(wifiReasonText(lastWifiReason)) +
                     " (code " + String(lastWifiReason) + ")");
    Serial.println(WiFi.status() == WL_CONNECTED
                   ? "joined, also reachable at " + WiFi.localIP().toString()
                   : String("could not join - the access point is still up"));
#if !CONFIG_IDF_TARGET_ESP32S3
    // On the T8 the access point is not free: it shares the radio and the internal RAM with
    // Bluetooth, and with a pad in the network barely worked. Joined, it goes; it stays (as
    // above) when the home network cannot be reached.
    if (WiFi.status() == WL_CONNECTED) {
      WiFi.softAPdisconnect(true);
      WiFi.mode(WIFI_STA);
      Serial.println("access point off (joined the home network)");
    }
#endif
  }

  // The network exists now, so a remembered http:// image can go back in.
  { String was = discRecall();
    if (was.length() && was.startsWith("http://") && !discIn) {
      Serial.println("disc: putting " + was + " back in");
      if (!discInsert(was)) Serial.println("disc: ...but it would not open - put it back by hand");
    } }

  Status s = fpga.status();
  Serial.printf("FPGA: %s", s.alive ? "answering" : "NOT ANSWERING");
  if (!s.alive) Serial.print("\n" + bootPins);
  if (s.alive) Serial.printf(", protocol %u, core %u", s.version, s.core);
  Serial.println();

  server.on("/", []{ server.send_P(200, "text/html", PAGE_HTML); });
  server.on("/api/state",   apiState);
  server.on("/api/scan",    apiScan);
  server.on("/api/join",    HTTP_POST, apiJoin);
  server.on("/api/forget",  HTTP_POST, apiForget);
  server.on("/api/boot",    HTTP_POST, apiBoot);
  server.on("/api/shell",   HTTP_POST, apiShell);
  server.on("/api/install", HTTP_POST, apiInstallCard);
  server.on("/api/disc",    HTTP_POST, []{
    String path = server.arg("path");
    if (!haveCard && !path.startsWith("http://")) { server.send(409, "application/json", "{\"error\":\"no card\"}"); return; }
    if (!discInsert(path)) { server.send(404, "application/json", "{\"error\":\"no such file\"}"); return; }
    server.send(200, "application/json", "{\"ok\":true,\"sectors\":" + String(discSectors) + "}");
  });
  server.on("/api/disc/fetch", HTTP_POST, []{
    if (fetchBusy) { server.send(409, "text/plain", "already fetching"); return; }
    if (!haveCard) { server.send(409, "text/plain", "no card fitted"); return; }
    fetchUrl  = server.arg("url");
    fetchPath = server.hasArg("path") ? server.arg("path") : String("/discs/disc.bin");
    if (!fetchUrl.length()) { server.send(400, "text/plain", "no url"); return; }
    fetchErr = ""; fetchDone = 0; fetchTotal = 0; fetchStalls = 0; fetchBusy = true;
    xTaskCreatePinnedToCore(fetchTask, "discfetch", 8192, nullptr, 1, nullptr, 1);
    server.send(200, "application/json", "{\"ok\":true}");
  });
  server.on("/api/disc/verify", HTTP_POST, []{
    if (verifyBusy || fetchBusy) { server.send(409, "text/plain", "busy"); return; }
    if (server.hasArg("url"))  fetchUrl  = server.arg("url");
    if (server.hasArg("path")) fetchPath = server.arg("path");
    if (!fetchUrl.length() || !fetchPath.length()) { server.send(400, "text/plain", "need url and path"); return; }
    verifyBusy = true;
    xTaskCreatePinnedToCore(verifyTask, "discverify", 8192, nullptr, 1, nullptr, 1);
    server.send(200, "application/json", "{\"ok\":true}");
  });
  server.on("/api/eject",   HTTP_POST, []{ discEject(); server.send(200, "application/json", "{\"ok\":true}"); });
  server.on("/api/library", HTTP_POST,
            []{ server.send(libFailed ? 500 : 200, "text/plain",
                            libFailed ? job.error : "saved"); },
            []{ libIsRom = false; onLibraryUpload(); });
  server.on("/api/roms",    HTTP_POST,
            []{ server.send(libFailed ? 500 : 200, "text/plain",
                            libFailed ? job.error : "saved"); },
            []{ libIsRom = true;  onLibraryUpload(); });
  server.on("/api/put",  HTTP_POST, putReply, onPutUpload);
  server.on("/api/stat", HTTP_GET,  statReply);
  server.on("/api/crc",  HTTP_GET,  crcReply);
  // Fetching a game back off the card is what lets the Ethernet side load it
  // into a running console: the card holds it, the register bus delivers it.
  server.on("/api/rom", HTTP_GET, []{
    if (!haveCard) { server.send(409, "text/plain", "no card fitted"); return; }
    String n = server.arg("name");
    if (n.indexOf("..") >= 0 || n.indexOf('/') >= 0) {
      server.send(400, "text/plain", "bad name");
      return;
    }
    File f = SD.open("/roms/" + n);
    if (!f) { server.send(404, "text/plain", "no such game"); return; }
    server.sendHeader("Content-Length", String((uint32_t)f.size()));
    server.streamFile(f, "application/octet-stream");
    f.close();
  });
  server.on("/api/upload",  HTTP_POST,
            []{ server.send(200, "text/plain", job.error.length() ? job.error : "ok"); },
            onUpload);
  server.begin();
  Serial.println("web server up");
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
// Everything the page can do, typed into the serial port. Not a toy: the page
// lives on this chip's own access point, so testing it from a desktop means
// taking that desktop off its network. This is the way to exercise an install
// from the card without doing that -- and when something goes wrong at three in
// the morning it is the interface that still works.
//
//   state              what the board is, and what is on the card
//   cores              the core library on the card
//   install <name>     write a core from the card into the flash slot
//   boot / shell       start the installed core / go back to the shell
//   scan               the networks this chip can see, with their exact spelling
//   wifi <ssid> <pass> join a network and remember it
//
// The password is never printed back. It goes into NVS and stays there; echoing
// it would put it in every log and scrollback that ever captured this port.
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
    // (internal RAM first: Wi-Fi's buffers come out of it, and beside Bluetooth it is short)
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
    Serial.println("  " + coreListJson());
  } else if (c.startsWith("disc ")) {
    String path = c.substring(5); path.trim();
    if (!haveCard && !path.startsWith("http://")) { Serial.println("  no card"); return; }
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
                   String(discIdle) + " idle polls, " + String(discFetches) + " fetches; image " + discPath + " (" + String(discSectors) + " sectors)");
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
  } else if (c == "wstatus") {
    int st = WiFi.status();
    Serial.println("  status " + String(st) +
                   (st == WL_CONNECTED ? " connected, IP " + WiFi.localIP().toString()
                                       : " not connected"));
    Serial.println("  last disconnect: " + String(wifiReasonText(lastWifiReason)) +
                   " (code " + String(lastWifiReason) + ")");
  } else if (c == "scan") {
    int n = WiFi.scanNetworks();
    if (n <= 0) { Serial.println("  nothing found"); return; }
    for (int i = 0; i < n; i++)
      Serial.println("  " + String(WiFi.RSSI(i)) + " dBm  \"" + WiFi.SSID(i) + "\"");
    WiFi.scanDelete();
  } else if (c.startsWith("wifi ")) {
    // Split at the LAST space: a network name is allowed to contain spaces and
    // a WPA password is not allowed to end with one, so this is the split that
    // cannot get a legal name wrong.
    String rest = c.substring(5);
    int sp = rest.lastIndexOf(' ');
    if (sp <= 0) { Serial.println("  wifi <ssid> <password>"); return; }
    String ssid = rest.substring(0, sp), pass = rest.substring(sp + 1);
    prefs.begin("net", false);
    prefs.putString("ssid", ssid);
    prefs.putString("pass", pass);
    prefs.end();
    // Stop any attempt already in flight first. A station that is mid-retry
    // refuses a new configuration outright -- "sta is connecting, cannot set
    // config" -- so a corrected password would be stored but silently not
    // applied, and the retry would keep failing with the OLD one. That looks
    // exactly like the new password being wrong too.
    WiFi.disconnect();
    delay(200);
    WiFi.begin(ssid.c_str(), pass.c_str());
    Serial.println("  joining \"" + ssid + "\" (" + pass.length() +
                   "-character password stored, not shown)");
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
  server.handleClient();
  pads::poll();
  if (!xaTaskUp) xaService();                     // (normally its own task: see setup)

  serviceSerial(false);
}

// The serial port and the pads, kept going from inside an upload. server.handleClient() does
// not come back until a request is done, and a piece of a disc takes ~15 s to arrive: the pad
// lines pc/pad.py sends ten times a second overflowed the port and came out as nonsense
// commands, Bluetooth went unread, and the menu could not be opened while a game was copied.
static String serLine;                  // (the line being gathered: the loop and uploads share it)
static String heldCmd[4];               // commands that came in during an upload, for the loop
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
static void serviceDuringUpload() {
  static uint32_t t = 0;
  if (millis() - t < 4) return;
  t = millis();
  pads::poll();
  serviceSerial(true);
}
