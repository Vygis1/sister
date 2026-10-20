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
#include <vector>
#include <SPI.h>
#include <SD.h>
#include "card.h"
#include <esp_task_wdt.h>
#ifndef SD_BUS_TRY
#define SD_BUS_TRY 0
#endif
#include "log.h"
#include "link.h"
#include "sdprobe.h"
#include "xa.h"
#include <esp_rom_crc.h>
#include <esp_heap_caps.h>
#include <mbedtls/base64.h>

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
ConsoleLog Log;                 // (log.h: quiet until "log on")

bool haveCard = false;

// --- the PlayStation's disc -------------------------------------------------------
// An image on the card (.bin, raw 2352-byte sectors, one data track), served a
// sector at a time to the console image's drive (rtl/cd_feed.v): the board says
// which sector it wants next and how much room it has, this task reads that
// sector off the card and sends it. "disc /discs/crash.bin" over serial (or the menu)
// puts the disc in; "eject" takes it out.
static const uint32_t XA_CTRL = 0x00080000;   // the console's register page (the drive's TOC, the XA FIFO)
static File     discFile;
static String   discPath;                 // a card path: a .bin, or a .cue naming its tracks
// A disc is a run of sectors laid end to end out of its files (a cue sheet's FILEs in order,
// as pc/cdaudio.py laid them): segments of (first LBA, count, which file, first sector in it),
// a PREGAP being silence that is in no file. The tracks' starts and kinds go to the drive as
// its table of contents (ps1_cdrom.v toc_*: console 0x5000 + 4 * entry) so GetTN / GetTD and
// Play know them, and an audio track's sectors reach it like any other -- it hears the audio
// by their lack of a sync pattern. Tekken 2's and MediEvil's music is in tracks 2 and up.
struct DiscSeg { uint32_t first, count, off; int8_t file; };
struct DiscTrack { uint8_t number; bool audio; uint32_t start; };
static std::vector<String>    discFiles;     // the files, by index (paths on the card)
static std::vector<DiscSeg>   discSegs;
static std::vector<DiscTrack> discTracks;
static int      discCurFile = -1;         // which of discFiles `discFile` is open on
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
  discFile = discCurFile >= 0 && discCurFile < (int)discFiles.size() ? SD.open(discFiles[discCurFile]) : File();
  rdFilePos = -1; discSick = 0;
  Log.println(discFile ? "disc: reopened the image" : "disc: the image will not open");
}
// the segment holding sector `lba` (nullptr past the end)
static const DiscSeg *discSegAt(uint32_t lba) {
  for (auto &g : discSegs) if (lba >= g.first && lba < g.first + g.count) return &g;
  return nullptr;
}

static void xaService();                       // (below, with the XA decoder)
static void discTocUpload();                   // (below, with the disc)
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
    // inside one segment of the disc: the file it is in, and no further than its end
    const DiscSeg *seg = discSegAt(rdNext);
    if (!seg) { vTaskDelay(1); continue; }
    if (n > seg->first + seg->count - rdNext) n = seg->first + seg->count - rdNext;
    for (uint32_t k = 0; k < n; k++) ringLba[slot + k] = 0xFFFFFFFF;   // about to change under the drive
    rdBusy = true;
    if (!discIn) { rdBusy = false; continue; }                         // ejected in between
    uint32_t got = 0;
    uint8_t *dst = discWin + (size_t)slot * 2352;
    uint32_t want_bytes = n * 2352;
    if (seg->file < 0) {                                               // a PREGAP: silence
      memset(dst, 0, want_bytes);
      got = want_bytes;
    } else {
      if (discCurFile != seg->file) { discCurFile = seg->file; discReopen(); }
      else if (!discFile) discReopen();
      bool ok = discFile;
      if (ok && rdFilePos != (int64_t)rdNext) {
        ok = discFile.seek((uint64_t)(seg->off + (rdNext - seg->first)) * 2352);
        rdFilePos = ok ? rdNext : -1;
      }
      if (ok) {
        // bytes, not sectors: a read can come back short (see the note that used to
        // be here -- a lost remainder offset every sector after it by a few bytes)
        for (int tries = 0; tries < 8 && got < want_bytes; tries++) {
          int r = discFile.read(dst + got, want_bytes - got);
          if (r <= 0) break;
          got += (uint32_t)r;
        }
        rdFilePos = (got == want_bytes) ? (int64_t)(rdNext + n) : -1;
      }
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
      if (k > 512) k = 512;                           // (2 kB: 1.6 ms of the link at a time, so a pad's word gets in between)
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
    if (!st.disc) { xaRun = false; fpga.cdDisc(true); discTocUpload(); vTaskDelay(1); continue; }   // the core was reset: tell it again, and its tracks
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

static uint32_t msfFrames(const String &t) {   // "mm:ss:ff" -> sectors
  int c1 = t.indexOf(':'), c2 = t.indexOf(':', c1 + 1);
  if (c1 < 0 || c2 < 0) return 0;
  return (uint32_t)t.substring(0, c1).toInt() * 4500 + (uint32_t)t.substring(c1 + 1, c2).toInt() * 75 + (uint32_t)t.substring(c2 + 1).toInt();
}
// The table of contents into the drive (pc/server.py upload_toc did this): track n's first
// sector with its audio bit (entry n), its start as mm:ss (entry 80h+n), the lead-out (0 / 80h),
// first and last track (FFh).
static void discTocUpload() {
  if (discTracks.empty()) return;
  const uint32_t TOC = XA_CTRL + 0x5000;
  for (auto &t : discTracks) {
    uint32_t n = t.number & 0x7F, s = (t.start + 150) / 75;
    fpga.busWrite(TOC + 4 * n, (t.audio ? 1u << 24 : 0) | t.start);
    fpga.busWrite(TOC + 4 * (0x80 | n), ((s / 60) << 6) | (s % 60));
  }
  uint32_t s = (discSectors + 150) / 75;
  fpga.busWrite(TOC + 4 * 0, discSectors);
  fpga.busWrite(TOC + 4 * 0x80, ((s / 60) << 6) | (s % 60));
  fpga.busWrite(TOC + 4 * 0xFF, ((uint32_t)discTracks.front().number << 8) | discTracks.back().number);
}
// A cue sheet into discFiles / discSegs / discTracks, as pc/cdaudio.py Disc._parse_cue lays a
// disc out: the FILEs end to end, each track starting at its INDEX 01, the INDEX 00 gap before
// it kept (it is in the file), a PREGAP as silence in no file. Only BINARY files: a cue naming
// MP3 or WAV audio is refused (the PC decoded those; the card holds raw tracks).
static bool discParseCue(const String &cuePath) {
  File cf = SD.open(cuePath);
  if (!cf || cf.size() > 16384) { if (cf) cf.close(); return false; }
  String cue = cf.readString(); cf.close();
  String dir = cuePath.substring(0, cuePath.lastIndexOf('/') + 1);
  struct T { DiscTrack t; int32_t i0, i1; uint32_t pregap; };
  std::vector<std::vector<T>> perFile;
  discFiles.clear(); discSegs.clear(); discTracks.clear();
  int at = 0;
  while (at < (int)cue.length()) {
    int nl = cue.indexOf('\n', at); if (nl < 0) nl = cue.length();
    String line = cue.substring(at, nl); line.trim(); at = nl + 1;
    String up = line; up.toUpperCase();
    if (up.startsWith("FILE ")) {
      int q1 = line.indexOf('"'), q2 = q1 >= 0 ? line.indexOf('"', q1 + 1) : -1;
      String name = (q1 >= 0 && q2 > q1) ? line.substring(q1 + 1, q2) : line.substring(5, line.lastIndexOf(' '));
      String kind = up.substring(up.lastIndexOf(' ') + 1);
      if (kind != "BINARY" && kind != "MOTOROLA") { Log.println("disc: " + name + " is " + kind + " -- only raw tracks play from the card"); return false; }
      int slash = name.lastIndexOf('/'); if (slash < 0) slash = name.lastIndexOf('\\');
      if (slash >= 0) name = name.substring(slash + 1);
      discFiles.push_back(dir + name);
      perFile.push_back({});
    } else if (up.startsWith("TRACK ") && !perFile.empty()) {
      int sp = up.indexOf(' ', 6);
      T t; t.t.number = (uint8_t)up.substring(6, sp).toInt(); t.t.audio = up.indexOf("AUDIO", sp) >= 0; t.t.start = 0; t.i0 = -1; t.i1 = -1; t.pregap = 0;
      perFile.back().push_back(t);
    } else if (up.startsWith("INDEX ") && !perFile.empty() && !perFile.back().empty()) {
      int sp = up.indexOf(' ', 6);
      int which = up.substring(6, sp).toInt(); String msf = up.substring(sp + 1); msf.trim();
      if (which == 0) perFile.back().back().i0 = (int32_t)msfFrames(msf);
      else if (which == 1) perFile.back().back().i1 = (int32_t)msfFrames(msf);
    } else if (up.startsWith("PREGAP ") && !perFile.empty() && !perFile.back().empty()) {
      String msf = up.substring(7); msf.trim();
      perFile.back().back().pregap = msfFrames(msf);
    }
  }
  if (discFiles.empty()) return false;
  uint32_t pos = 0;
  for (size_t fi = 0; fi < discFiles.size(); fi++) {
    File f = SD.open(discFiles[fi]);
    if (!f) { Log.println("disc: the cue names " + discFiles[fi] + ", which is not on the card"); return false; }
    uint32_t fsec = f.size() / 2352; f.close();
    uint32_t consumed = 0;
    auto &tracks = perFile[fi];
    for (size_t i = 0; i < tracks.size(); i++) {
      T &t = tracks[i];
      if (t.pregap) { discSegs.push_back({ pos, t.pregap, 0, -1 }); pos += t.pregap; }
      uint32_t startIn = t.i1 >= 0 ? (uint32_t)t.i1 : 0;
      if (startIn > consumed) { discSegs.push_back({ pos, startIn - consumed, consumed, (int8_t)fi }); pos += startIn - consumed; consumed = startIn; }
      t.t.start = pos;
      uint32_t endIn = fsec;
      if (i + 1 < tracks.size()) endIn = tracks[i + 1].i0 >= 0 ? (uint32_t)tracks[i + 1].i0 : (tracks[i + 1].i1 >= 0 ? (uint32_t)tracks[i + 1].i1 : fsec);
      if (endIn > consumed) { discSegs.push_back({ pos, endIn - consumed, consumed, (int8_t)fi }); pos += endIn - consumed; consumed = endIn; }
      discTracks.push_back(t.t);
    }
  }
  discSectors = pos;
  return !discTracks.empty();
}

static bool discInsert(const String &path) {
  // Open the new image BEFORE letting go of the one in the drive. The old order
  // stopped the drive first, so a path that was not on the card left the console
  // with no disc at all -- the BIOS sat at its logo (2026-09-30).
  String lo = path; lo.toLowerCase();
  if (lo.endsWith(".cue")) {
    if (!discParseCue(path)) return false;
  } else {
    File nf = SD.open(path);
    if (!nf) return false;
    uint32_t n = nf.size() / 2352; nf.close();
    discFiles.clear(); discSegs.clear(); discTracks.clear();
    discFiles.push_back(path);
    discSegs.push_back({ 0, n, 0, 0 });
    discTracks.push_back({ 1, false, 0 });
    discSectors = n;
  }
  readerPause();
  if (discFile) discFile.close();
  discCurFile = -1;
  if (!discWin) discWin = (uint8_t *)ps_malloc(WINDOW * 2352);
  if (!discWin) return false;
  winBase = 0; winCount = 0;
  ringClear();
  discPath = path;
  discRemember(path);
  discServed = 0; discMisses = 0; discIdle = 0; discFetches = 0;
  fpga.cdDisc(true);
  discTocUpload();
  discIn = true;
  if (discTracks.size() > 1) Log.printf("disc: %u tracks, %u sectors, %u files\n", (unsigned)discTracks.size(), (unsigned)discSectors, (unsigned)discFiles.size());
  return true;
}
static void discEject() {
  readerPause();
  fpga.cdDisc(false);
  if (discFile) discFile.close();
  discCurFile = -1;
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
// (the menu's progress screen while a core goes in: set by menu.h; fraction 0..1)
static void (*installShow)(float fraction) = nullptr;
// A core into a slot: base, its offset in the 6 MB past the shell (0: the slot at 2 MB, 0x300000:
// the one at 5 MB); erased, its first sectors the menu has erased already in the background.
static bool installCard(File &f, uint32_t base = 0, uint32_t erased = 0) {
  static uint8_t want[PAGE], got[PAGE];
  // the shell from version 6: pages four bits a clock, each 64 kB block checked by the board's own
  // checksum (no page read back over the link); from version 7, a block's 16 kB pieces into the
  // board's buffer and programmed by the board page after page (no round trip a page)
  Status ist = fpga.status();
  bool fast = ist.alive && ist.core == 0 && ist.version >= 6 && fpga.quadWired();
  bool fast7 = fast && ist.version >= 7;
  static uint8_t *blk = nullptr;
  if (fast && !blk) blk = (uint8_t *)heap_caps_malloc(SECTOR, MALLOC_CAP_SPIRAM);
  if (!blk) fast = fast7 = false;
  uint32_t t0 = millis();
  uint32_t length = f.size();
  if (length == 0 || base + length > SLOT_SIZE) {
    job.error = "that image is " + String(length) + " bytes; it does not fit the slot";
    return false;
  }
  uint32_t pages = (length + PAGE - 1) / PAGE;
  uint32_t sectors = (length + SECTOR - 1) / SECTOR, redone = 0;
  const uint32_t per = SECTOR / PAGE;
  // every sector erased first, in order (unless the menu has already) -- the shell's screen takes
  // the image's size from these -- then each written and checked, and erased again and rewritten
  // only if it came back wrong
  job.stage = "erasing"; job.total = sectors; job.done = 0;
  for (uint32_t sec = erased; sec < sectors; sec++) {
    if (!fpga.eraseSector(base + sec * SECTOR) && !fpga.eraseSector(base + sec * SECTOR)) {
      job.error = "the flash never finished erasing sector " + String(sec);
      return false;
    }
    job.done = sec + 1;
    if (installShow && (sec & 3) == 3) installShow(0.3f * (sec + 1) / sectors);
  }
  uint32_t t1 = millis();
  job.stage = "writing"; job.total = pages; job.done = 0;
  for (uint32_t sec = 0; sec < sectors; sec++) {
    uint32_t p0 = sec * per, p1 = min(pages, p0 + per);
    bool good = false;
    for (int tries = 0; tries < 3 && !good; tries++) {
      if (tries) {
        redone++;
        if (!fpga.eraseSector(base + sec * SECTOR) && !fpga.eraseSector(base + sec * SECTOR)) continue;
      }
      f.seek(p0 * PAGE);
      if (fast) {
        // the block from the card in one read; then onto the flash; the board's checksum of it
        memset(blk, 0xFF, SECTOR);
        f.read(blk, (p1 - p0) * PAGE);
        if (fast7) {
          bool ok = true;
          for (uint32_t k = 0; k < 4 && ok; k++) {
            uint32_t q0 = p0 + k * 64;
            if (q0 >= p1) break;
            int n = (int)min<uint32_t>(64, p1 - q0);
            fpga.bufWriteQuad(0, blk + k * 16384, n * PAGE);
            ok = fpga.progPages(base + q0 * PAGE, n);
          }
          if (!ok) { Log.printf("install: block %u never finished programming%s", sec, "\n"); continue; }
        } else {
          for (uint32_t i = p0; i < p1; i++) fpga.writePageQuad(base + i * PAGE, blk + (i - p0) * PAGE, PAGE);
        }
        vTaskDelay(1);   // (a block's pages are ~0.3 s of polling: let the idle task run)
        uint64_t s = 0;
        good = fpga.sumBlock(SLOT_BASE + base + sec * SECTOR, s) && s == FpgaLink::sumOf(blk, SECTOR);
        if (!good) Log.printf("install: block %u checksum wrong, again%s", sec, "\n");
        continue;
      }
      for (uint32_t i = p0; i < p1; i++) {
        size_t r = f.read(want, PAGE);
        for (size_t k = r; k < PAGE; k++) want[k] = 0xFF;
        fpga.writePage(base + i * PAGE, want, PAGE);
      }
      f.seek(p0 * PAGE);
      good = true;
      for (uint32_t i = p0; i < p1 && good; i++) {
        size_t r = f.read(want, PAGE);
        for (size_t k = r; k < PAGE; k++) want[k] = 0xFF;
        if (!fpga.readPage(SLOT_BASE + base + i * PAGE, got) && !fpga.readPage(SLOT_BASE + base + i * PAGE, got)) good = false;
        else if (memcmp(want, got, PAGE)) {
          good = false;
          Log.printf("install: page %u wrong, sector %u again%s", i, sec, "\n");
        }
      }
    }
    if (!good) {
      job.error = "sector " + String(sec) + " would not write right three times -- the core is NOT installed";
      return false;
    }
    job.done = p1;
    if (installShow) installShow(0.3f + 0.7f * p1 / pages);
  }
  if (redone) Log.printf("install: %u sector(s) written again%s", redone, "\n");
  Log.printf("install: %u kB at +%u kB, erase %u ms (%u done before), write and check %u ms (%s)%s", (unsigned)(length / 1024),
             (unsigned)(base / 1024), (unsigned)(t1 - t0), (unsigned)erased, (unsigned)(millis() - t1),
             fast7 ? "the board programs each block" : fast ? "quad, checked by block" : "a bit a clock, read back", "\n");
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
      prefs.begin("menu", false); prefs.putString("slot", cardCore); prefs.putUInt("size", f.size());
      prefs.putString("s0core", cardCore); prefs.putUInt("s0size", f.size()); prefs.putUInt("s0erased", 0); prefs.end();
    }
    f.close();
  }
  job.busy = false;
  vTaskDelete(nullptr);
}

static void serviceSerial(bool inUpload);

#include "pc.h"
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

// why the chip last reset, and what the PC's disk task was doing then (RTC memory survives a reset that is
// not a power cut): "state" prints them -- a reboot with the log off left nothing to go on (2026-10-19)
RTC_NOINIT_ATTR static char lastStep[40];
RTC_NOINIT_ATTR static uint32_t lastStepMagic, lastStepArg, bootCount;
static esp_reset_reason_t resetWhy;
static const char *resetName(esp_reset_reason_t r) {
  switch (r) {
    case ESP_RST_POWERON: return "power on"; case ESP_RST_EXT: return "reset pin"; case ESP_RST_SW: return "software";
    case ESP_RST_PANIC: return "CRASH (panic)"; case ESP_RST_INT_WDT: return "interrupt watchdog"; case ESP_RST_TASK_WDT: return "task watchdog";
    case ESP_RST_WDT: return "other watchdog"; case ESP_RST_DEEPSLEEP: return "deep sleep"; case ESP_RST_BROWNOUT: return "BROWNOUT (power dipped)";
    case ESP_RST_SDIO: return "SDIO"; default: return "unknown";
  }
}
static void noteStep() {                   // (the main loop: the disk task's step, kept for after a reset)
  const char *s = (const char *)pc::step;
  strncpy(lastStep, s ? s : "?", sizeof lastStep - 1); lastStep[sizeof lastStep - 1] = 0;
  lastStepArg = pc::stepArg; lastStepMagic = 0x51E9u;
}

void setup() {
  resetWhy = esp_reset_reason();
  if (resetWhy == ESP_RST_POWERON || lastStepMagic != 0x51E9u) { bootCount = 0; lastStep[0] = 0; }
  bootCount++;
  // The task watchdog logs and carries on instead of resetting the chip: a reset in the middle of a
  // game is what left the PC's disk image with a broken directory entry on the card (2026-10-18) --
  // a stall is found from the log (and pc::watch's step), a damaged card is worse
  esp_task_wdt_init(5, false);
  // Small allocations to PSRAM too. By default everything under 4 kB comes out of internal
  // RAM, and the menu's strings broke it into pieces: minutes after boot 9 kB was free with
  // nothing over 3 kB (2026-10-10, T8 with a DualShock 4 in). Bluetooth and task stacks still
  // take internal RAM: they ask for it by name.
  heap_caps_malloc_extmem_enable(64);
  // 2 Mbaud (the CH9102 and the UART both take it): files onto the card ran at 6.5 kB/s at
  // 115200. Room for two 4 kB blocks of "U blk" while the card writes the one before.
  Serial.setRxBufferSize(12288);
  Serial.begin(2000000);
  delay(300);
#if CONFIG_IDF_TARGET_ESP32S3
  Log.println("\nconsole: ESP32-S3 front door");
#else
  Log.println("\nconsole: ESP32 (T8) front door");
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
#if !CONFIG_IDF_TARGET_ESP32S3
  fpga.quadPins(22, 21);                           // (the T8's WP and HD: quad writes' extra wires)
#endif

  SdDiagnosis sd{};
#if !CONFIG_IDF_TARGET_ESP32S3
  // The SD bus first (card.h), before any SPI command: one of those leaves the card in SPI mode
  // until its power goes.
  if (SD_BUS_TRY && SD.beginMMC()) {
    haveCard = true; sdInfo.responded = true;
    Log.printf("card: on the SD bus, one bit, %u kHz%s", (unsigned)SD.mmcKhz, "\n");
  } else
#endif
  {
  sdBus.begin(PIN_SD_SCK, PIN_SD_MISO, PIN_SD_MOSI, PIN_SD_CS);
  // Ask the card what it is BEFORE asking the filesystem anything. A failed
  // mount and a disconnected card are the same bit out of SD.begin(), and they
  // are a reformat and a soldering iron respectively -- see sdprobe.h.
  sd = sdDiagnose(sdBus, PIN_SD_SCK, PIN_SD_MISO, PIN_SD_MOSI, PIN_SD_CS);
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
  if (haveCard) Log.printf("card: over SPI (the SD bus did not take it: once the card has been in SPI mode it needs a power cycle)%s", "\n");
  }
  // CORE 0, not 1: reading the card blocks inside the SPI driver, and on the
  // same core as loop() that starves the web server and the serial console
  // together -- the board goes completely deaf while the drive is being fed,
  // which looked exactly like a crash.
  xaOut  = (uint32_t *)ps_malloc(xa::MAX_OUT * 4);
  xaSec  = (uint8_t *)ps_malloc(2352);
  xaPend = (xaOut && xaSec) ? (uint32_t *)ps_malloc(XA_PEND * 4) : nullptr;   // (xaPend set: XA on)
  if (!xaPend) Log.println("xa: no PSRAM for the decoder: no CD audio");
  xaDec.reset();
  xTaskCreatePinnedToCore(discTask, "disc", 8192, nullptr, 2, nullptr, 0);
  // the card reader on the OTHER core: the two buses then work at once (see
  // cardReaderTask). It spends its waits blocked in the SD driver, not spinning,
  // so loop() on this core still gets its turn.
  xTaskCreatePinnedToCore(cardReaderTask, "cardread", 8192, nullptr, 1, nullptr, 1);
  // the disc that was in goes back in
  { String was = discRecall();
    if (was.length()) {
      Log.println("disc: putting " + was + " back in");
      if (!discInsert(was)) Log.println("disc: ...but it would not open");
    } }
  sdWhy = SD.mmc ? String("on the SD bus (one bit, ") + String(SD.mmcKhz / 1000) + " MHz) -- mounted" : sdProbeSummary(sdInfo, haveCard);
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
  Log.println("SD: " + sdWhy);
  if (sd.verdict) Log.println("    " + String(sd.verdict));
  if (!SD.mmc) Log.println(String("    MISO idles ") +
                 (sd.misoHigh ? "HIGH (module has power)"
                              : "LOW (no power, or not connected)"));
  // Only when the CARD did not answer. Gating this on "did it mount" was wrong:
  // a card that responds perfectly and merely carries a filesystem this chip
  // cannot read would get a confident lecture about its wiring being wrong.
  // A diagnostic that fires on the wrong condition is worse than none, because
  // it sends you to check the thing that is already fine.
  if (!sdInfo.responded) {
    Log.print(pinMap);
    sdPinReport(PIN_SD_SCK, PIN_SD_MISO, PIN_SD_MOSI, PIN_SD_CS);
    if (sdRailFloating(PIN_SD_MOSI, PIN_SD_SCK, PIN_SD_MISO, PIN_SD_CS))
      Log.println("    => the module IS wired to these four pins and has NO "
                     "POWER. Its supply rail is floating, which is why the pins "
                     "drag each other around. Check VCC and GND at the module.");
    else
      Log.println("    => these pins are genuinely unconnected - the wires "
                     "are not reaching the module at all.");
  }

  Status s = fpga.status();
  Log.printf("FPGA: %s", s.alive ? "answering" : "NOT ANSWERING");
  if (!s.alive) Log.print("\n" + bootPins);
  if (s.alive) Log.printf(", protocol %u, core %u", s.version, s.core);
  Log.println();

  menu::begin();
  xaChIn  = (uint8_t *)heap_caps_malloc(128, MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
  xaChOut = (uint32_t *)heap_caps_malloc(xa::MAX_CHUNK * 4, MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
  if (!xaChIn || !xaChOut) { Log.println("xa: no internal RAM for the decoder: no CD audio"); xaPend = nullptr; }
  if (xaPend && xTaskCreatePinnedToCore(xaTask, "xa", 6144, nullptr, 2, nullptr, 1) != pdPASS)
    Log.println("xa: no task (it runs from loop() instead)");
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
// --- a file onto the card from the PC ----------------------------------------------------
// "U open <path> <size>", then "U <base64>" lines (up to 189 bytes each), then "U close"; each is
// answered "= ok", "= done" (the size reached) or "= error ...". pc/pad.py passes U lines through
// and waits for the answer (tools/sdput.py). A homebrew ROM, a core: the card stays in the board.
// Faster: "U blk <offset> <n> <crc32>" (hex) and then n raw bytes (n <= 4096). A block that is
// not at the file's end, or whose CRC is wrong, is dropped with what follows it and answered
// "= error at <end>" (serviceSerial); the PC sends again from there. pc/pad.py's "X" does this.
static File     putFile;
static uint32_t putLeft = 0, putPos = 0;
static uint8_t  blkBuf[4096];
static uint32_t blkWant = 0, blkGot = 0, blkOfs = 0, blkCrc = 0, blkT = 0;
static bool     blkSkip = false;
static void putWrite(const uint8_t *buf, size_t n);
static String   putDisc;                 // the disc that was in, to put back
static void putLine(String a) {
  if (a.startsWith("open ")) {
    int sp = a.lastIndexOf(' ');
    if (sp < 6) { Serial.println("= error usage: U open <path> <size>"); return; }
    String path = a.substring(5, sp); path.trim();
    uint32_t size = strtoul(a.c_str() + sp + 1, nullptr, 10);
    if (!haveCard) { Serial.println("= error no card"); return; }
    if (putFile) putFile.close();
    if (discIn) { putDisc = discPath; readerPause(); }      // (the drive's reader off the card meanwhile)
    int slash = path.lastIndexOf('/');
    if (slash > 0) SD.mkdir(path.substring(0, slash));
    putFile = SD.open(path, FILE_WRITE);
    if (!putFile) { Serial.println("= error cannot create " + path); return; }
    putLeft = size; putPos = 0;
    Serial.println("= ok");
    return;
  }
  if (a.startsWith("crc ")) {                      // "U crc <path>" -> "= <crc32> <size>" (hex): the check
    String path = a.substring(4); path.trim();
    File f = SD.open(path);
    if (!f) { Serial.println("= error no such file"); return; }
    uint32_t crc = 0, size = 0; int r;
    while ((r = f.read(blkBuf, sizeof(blkBuf))) > 0) { crc = crc32(crc, blkBuf, r); size += r; }
    f.close();
    cardChanged = true;                            // (a file just arrived: the menu reads the card again)
    Serial.printf("= %08x %x\n", (unsigned)crc, (unsigned)size);
    return;
  }
  if (a.startsWith("blk ")) {
    char *e = nullptr;
    blkOfs = strtoul(a.c_str() + 4, &e, 16);
    uint32_t n = strtoul(e, &e, 16);
    blkCrc = strtoul(e, &e, 16);
    if (n == 0 || n > sizeof(blkBuf)) { Serial.println("= error block size"); return; }
    blkWant = n; blkGot = 0; blkT = millis();       // (serviceSerial gathers the bytes)
    return;
  }
  if (a == "close") {
    if (putFile) putFile.close();
    putLeft = 0; listsStale = true;
    if (putDisc.length()) { discInsert(putDisc); putDisc = ""; }
    Serial.println("= ok");
    return;
  }
  if (!putFile) { Serial.println("= error no file open"); return; }
  uint8_t buf[192]; size_t n = 0;
  if (mbedtls_base64_decode(buf, sizeof(buf), &n, (const uint8_t *)a.c_str(), a.length()) != 0) {
    Serial.println("= error bad base64"); return;
  }
  putWrite(buf, n);
}

// n bytes at the file's end, from a "U" line or a "U blk" block
static void putWrite(const uint8_t *buf, size_t n) {
  if (putFile.write(buf, n) != n) { Serial.println("= error write failed"); return; }
  putPos += n;
  putLeft = putLeft > n ? putLeft - n : 0;
  if (putLeft == 0) {
    putFile.close(); listsStale = true;
    if (putDisc.length()) { discInsert(putDisc); putDisc = ""; }
    Serial.println("= done");
  } else Serial.println("= ok");
}

static void serialCommand(String c) {
  c.trim();
  if (c.length() > 2 && c[0] == 'U' && c[1] == ' ') { putLine(c.substring(2)); return; }
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
  if (c.startsWith("time ")) {                      // "time <seconds since 1970, local time>": the clock (and the DS1302)
    menu::clockSet((time_t)strtoul(c.c_str() + 5, nullptr, 10));
    return;
  }
  if (c == "state") {
    Serial.printf("  last reset: %s (boot %u since power on)%s%s\n", resetName(resetWhy), (unsigned)bootCount,
                  lastStep[0] && resetWhy != ESP_RST_POWERON ? "; the PC disk task was in " : "", lastStep[0] && resetWhy != ESP_RST_POWERON ? lastStep : "");
    {
      time_t t = menu::clockNow(); struct tm tm; gmtime_r(&t, &tm);
      Serial.printf("  clock %04d-%02d-%02d %02d:%02d:%02d (%s)\n", tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday, tm.tm_hour, tm.tm_min, tm.tm_sec,
                    menu::clkModule ? "the DS1302" : "no DS1302: counting from 2000-01-01");
    }
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
  } else if (c.startsWith("quaddrive ")) {           // "quaddrive 0-3": the quad data pins' drive (0 weakest)
    fpga.quadDrive(c.substring(10).toInt());
    Serial.printf("  quad data pins at drive %d\n", (int)c.substring(10).toInt());
  } else if (c == "quadtest") {
    // the quad wires: 256 words through the menu image's highlight register (written quad, read back a
    // bit at a time) at three clocks, the wrong bits counted by wire (bit % 4: 0 MOSI, 1 MISO, 2 WP
    // GPIO22, 3 HD GPIO21); then 256 kB quad into its image memory (the menu sends its images again)
    Status st = fpga.status();
    if (!fpga.quadWired() || !st.alive || st.core != 0 || st.version < 5) Serial.println("  quadtest: needs the menu image, version 5, and the wires");
    else {
      const uint32_t hzs[3] = { 5000000, 8000000, 10000000 };
      for (uint32_t hz : hzs) {
        int bad = 0, lane[4] = { 0, 0, 0, 0 }, patBad[4] = { 0, 0, 0, 0 };
        for (int i = 0; i < 256; i++) {
          // (patterns by quarter: none switching, all four together, one wire at a time, random)
          int pat = i / 64;
          uint32_t w = pat == 0 ? 0 : pat == 1 ? ((i & 1) ? 0x03FF03FFu : 0x00F000F0u) : pat == 2 ? (0x00110011u << (i & 3)) : esp_random();
          w &= 0x03FF03FF;
          fpga.busWriteQuad(0x00090020, &w, 1, hz);
          uint32_t r = fpga.busRead(0x00090020);
          if (r != w) {
            bad++;
            uint32_t x = r ^ w;
            for (int k = 0; k < 32; k++) if (x >> k & 1) lane[k & 3]++;
            patBad[pat]++;
            if (bad <= 3) Serial.printf("    %8u Hz: wrote %08x read %08x\n", (unsigned)hz, (unsigned)w, (unsigned)r);
          }
        }
        Serial.printf("  quadtest %8u Hz: %d of 256 words wrong; wrong bits by wire: MOSI %d, MISO %d, WP %d, HD %d\n",
                      (unsigned)hz, bad, lane[0], lane[1], lane[2], lane[3]);
        Serial.printf("    by pattern (64 each): none switching %d, all four together %d, one at a time %d, random %d\n", patBad[0], patBad[1], patBad[2], patBad[3]);
      }
      static uint32_t blk[1024];
      for (int i = 0; i < 1024; i++) blk[i] = 0x5A5A5A5Au ^ (uint32_t)i;
      uint32_t t0 = micros();
      for (int k = 0; k < 64; k++) fpga.busWriteQuad(0x000D0000 + 4096 * (k & 15), blk, 1024);
      uint32_t us = micros() - t0;
      Serial.printf("  quadtest: 256 kB in %u us, %u kB/s\n", (unsigned)us, (unsigned)(256000ull * 1000 / us));
      menu::freshBoard(); menu::draw();
    }
  } else if (c == "linkbench") {
    // 256 kB of picture words to the menu image's picture (its top band, over and over), a few
    // clocks and a few block sizes: kB/s each. The menu is drawn again after.
    static uint32_t blk[1024];
    for (int i = 0; i < 1024; i++) blk[i] = 0x11111111u * (i & 1);
    fpga.busWrite(0x00090010, 0); fpga.busWrite(0x00090014, (16u << 16) | 640u);
    const uint32_t hzs[4] = { 5000000, 10000000, 11430000, 13330000 };
    for (uint32_t hz : hzs)
      for (int words : { 256, 1024 }) {
        uint32_t t0 = micros();
        for (int k = 0; k < (256 * 1024) / (words * 4); k++) fpga.busWriteAt(0x00091000, blk, words, hz);
        uint32_t us = micros() - t0;
        Serial.printf("  %8u Hz, %4d words a frame: %u kB/s\n", hz, words, (unsigned)(256000ull * 1000 / us));
      }
    gfx::forget(); menu::draw();
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
#if !CONFIG_IDF_TARGET_ESP32S3
  fpga.quadPins(22, 21);                           // (the T8's WP and HD: quad writes' extra wires)
#endif
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
    if (mhz && !SD.mmc) { SD.end(); haveCard = SD.begin(PIN_SD_CS, sdBus, mhz * 1000000); listsStale = true; }
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
  } else if (c.startsWith("kb ")) {
    // kb <hex> ...: bytes to the PC's keyboard (PS/2 set 2: pc/pad.py's keyboard window sends these)
    int i = 3;
    while (i < (int)c.length()) {
      while (i < (int)c.length() && c[i] == ' ') i++;
      int j = i;
      while (j < (int)c.length() && c[j] != ' ') j++;
      if (j > i) pc::key((uint8_t)strtoul(c.substring(i, j).c_str(), nullptr, 16));
      i = j;
    }
  } else if (c.startsWith("pcboot ")) {
    // pcboot <image>: the PC (the board must be the PC core already) started on that disk image
    String path = c.substring(7); path.trim();
    String e = pc::start(path, menu::stream, menu::NES_PRG, menu::NES_CART_BANK);
    // (as a game started from the menu: the menu closed and told a game is running -- else it opens
    // itself over the PC's picture when the core comes up and keeps it covered)
    if (!e.length()) { menu::gameIn = true; menu::gameName = "PC"; menu::open_ = false; menu::osd(0); }
    Serial.println(e.length() ? "  pcboot: " + e : String("  pcboot: running ") + path);
  } else if (c == "pcgrab") {
    // the PC's screen, out of its DDR3 frame (pc_fb.v): "G <w> <h>", then a line a row,
    // "G<y> <base64 of the row's RGB565>" -- tools/pc/pcgrab.py makes a picture of it
    uint32_t st = fpga.busRead(pc::STAT), w = st & 0x7FF, h = (st >> 16) & 0x3FF;
    if (w > 1024) w = 1024;
    Serial.printf("G %u %u\n", (unsigned)w, (unsigned)h);
    static uint8_t row[2048]; static unsigned char b64[2800];
    uint32_t lines = (w + 7) / 8;
    for (uint32_t y = 0; y < h; y++) {
      for (uint32_t i = 0; i < lines; i++) {
        fpga.busWrite(pc::PAGE + 0x7030, 0x800000 + y * 128 + i);
        for (int k = 0; k < 4; k++) { uint32_t v = fpga.busRead(pc::PAGE + 0x7034 + 4 * k); memcpy(row + i * 16 + 4 * k, &v, 4); }
      }
      size_t ol = 0;
      mbedtls_base64_encode(b64, sizeof b64, &ol, row, lines * 16);
      b64[ol] = 0;
      Serial.printf("G%u %s\n", (unsigned)y, (const char *)b64);
    }
    Serial.println("G end");
  } else if (c == "pctime") {
    // where the PC's disk requests' time goes: per request, on average
    uint32_t n = pc::nReq ? pc::nReq : 1;
    Serial.printf("  pc disk: %u requests, %u sectors (%.1f a request); a request: waiting for it %u us, cache hits %u, read %u us, link %u us%s",
                  (unsigned)pc::nReq, (unsigned)pc::served, (double)pc::served / n, (unsigned)(pc::usGap / n),
                  (unsigned)pc::cHits, (unsigned)(pc::usRead / n), (unsigned)(pc::usLink / n), "\n");
    Serial.printf("  gaps <0.1 ms %u, <0.5 %u, <1 %u, <2 %u, <5 %u, <10 %u, <20 %u, <50 %u, more %u\n", (unsigned)pc::gapHist[0], (unsigned)pc::gapHist[1],
                  (unsigned)pc::gapHist[2], (unsigned)pc::gapHist[3], (unsigned)pc::gapHist[4], (unsigned)pc::gapHist[5], (unsigned)pc::gapHist[6],
                  (unsigned)pc::gapHist[7], (unsigned)pc::gapHist[8]);
  } else if (c == "pcstat") {
    uint32_t st = fpga.busRead(pc::STAT), dbg = fpga.busRead(pc::DBG), irq = fpga.busRead(pc::PAGE + 0x701C);
    Serial.printf("  pc: %s, picture %u x %u, CS:IP %04X:%04X, %u sectors read, %u written, IRQ0 %u, IRQ1 %u%s", pc::on ? "running" : "off",
                  (unsigned)(st & 0x7FF), (unsigned)((st >> 16) & 0x3FF), (unsigned)(dbg >> 16), (unsigned)(dbg & 0xFFFF),
                  (unsigned)pc::served, (unsigned)pc::written, (unsigned)(irq >> 16), (unsigned)(irq & 0xFFFF), "\n");
  } else if (c.startsWith("sdbench")) {
    // sdbench [path]: a file read through in 16 kB pieces, as the loader reads a cartridge
    String path = c.length() > 8 ? c.substring(8) : String("/cores/n64.bin");
    path.trim();
    File f = SD.open(path);
    if (!f) { Serial.println("  cannot open " + path); return; }
    static uint8_t *b = (uint8_t *)heap_caps_malloc(16384, MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
    uint32_t t0 = millis(), got = 0, n;
    while (got < 8u * 1024 * 1024 && (n = f.read(b, 16384)) > 0) got += n;
    uint32_t ms = millis() - t0;
    f.close();
    Serial.printf("  sdbench %s: %u kB in %u ms, %u kB/s (%s)\n", path.c_str(), (unsigned)(got / 1024), (unsigned)ms,
                  (unsigned)(ms ? got / ms : 0), SD.mmc ? "the SD bus" : "SPI");
  } else if (c == "pads") {
    // the two players as this chip sees them, and the words last written to JOY1 / JOY2
    pads::Player p[2]; pads::view(p);
    for (int i = 0; i < 2; i++)
      Serial.printf("  player %d: %s %s%s, JOY%d = %08x\n", i + 1, p[i].on ? "on" : "off",
                    p[i].name, p[i].bt ? " (Bluetooth)" : "", i + 1, (unsigned)pads::last[i]);
#if PADS_BT
    for (int i = 0; i < 2; i++)
      Serial.printf("  BT slot %d: %s\n", i, !pads::slot[i] ? "empty" :
                    (String(pads::slot[i]->isConnected() ? "connected" : "gone") +
                     (pads::slot[i]->isGamepad() ? ", gamepad, " : ", NOT a gamepad, ") +
                     pads::slot[i]->getModelName().c_str()).c_str());
#endif
    Serial.printf("  console %u, %s, swap %d\n", pads::which, pads::there ? "there" : "not there", pads::swapPlayers);
  } else if (c == "log on" || c == "log off") {
    Log.on = c.endsWith("on");
    Serial.println(Log.on ? "  logging on (until a reset)" : "  logging off");
  } else if (c == "vgrab" || c.startsWith("vgrab ")) {
    // vgrab [step]: the picture the core sends to HDMI (console_top's line_grab: not in the PS1 or N64
    // images), every step-th line: "V 640 480 <step>", then "V<y> <base64 of the line's RGB565>" --
    // tools/vgrab.py makes a picture of it
    int step = c.length() > 6 ? c.substring(6).toInt() : 1;
    if (step < 1) step = 1;
    const uint32_t LG = 0x80000 + 0x1F0;
    Serial.printf("V 640 480 %d\n", step);
    static uint8_t row[1280]; static unsigned char b64[1800];
    for (uint32_t y = 0; y < 480; y += step) {
      fpga.busWrite(LG, y);
      uint32_t t0 = millis();
      while (!(fpga.busRead(LG) & 1) && millis() - t0 < 100) delay(1);
      if (!(fpga.busRead(LG) & 1)) { Serial.printf("V no line %u (no grabber in this image?)\n", (unsigned)y); break; }
      for (uint32_t k = 0; k < 320; k++) {
        fpga.busWrite(LG + 4, k);
        uint32_t v = fpga.busRead(LG + 4);
        memcpy(row + 4 * k, &v, 4);
      }
      size_t ol = 0;
      mbedtls_base64_encode(b64, sizeof b64, &ol, row, sizeof row);
      b64[ol] = 0;
      Serial.printf("V%u %s\n", (unsigned)y, (const char *)b64);
    }
    Serial.println("V end");
  } else if (c == "quad off" || c == "quad on") {
    menu::quadOff = c == "quad off";
    Serial.printf("  loads %s" "\n", menu::quadOff ? "a bit at a time (quad off)" : "quad when the board takes it");
  } else if (c.startsWith("bulk ")) {
    // bulk <hz>: the bulk transfers' clock by hand (menu.h sets it from the image's clock at each load)
    uint32_t hz = c.substring(5).toInt();
    if (hz >= 1000000 && hz <= 20000000) fpga.setBulkHz(hz);
    Serial.printf("  bulk transfers at %u Hz" "\n", (unsigned)fpga.bulkHz());
  } else if (c.startsWith("rm ")) {
    // rm <path>: a file off the card (not one the PC is running from)
    String path = c.substring(3); path.trim();
    if (pc::on) Serial.println("  rm: the PC is running a disk -- start another game first");
    else Serial.printf("  rm %s: %s" "\n", path.c_str(), SD.remove(path) ? "removed" : "FAILED (no such file?)");
  } else if (c == "ds") {
    // the DS1302's own registers, twice two seconds apart: is it there, running (seconds bit 7 clear),
    // ticking, and what does it hold (it keeps time over a power cut only with a good coin cell)
    for (int k = 0; k < 2; k++) {
      uint8_t r[8]; menu::dsRead(r);
      Serial.printf("  DS1302: %02x %02x %02x %02x %02x %02x %02x %02x  (sec min hour date month wday year wp)%s\n",
                    r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7], (r[0] & 0x80) ? " -- HALTED" : "");
      if (!k) delay(2000);
    }
  } else if (c.startsWith("pcread ")) {
    // pcread <path> [lba]: the sector as the PC's disk task would read it (a plain open, no cache)
    String a = c.substring(7); a.trim();
    int sp = a.lastIndexOf(' '); uint32_t lba = 0;
    if (sp > 0 && a.substring(sp + 1).toInt() >= 0 && isDigit(a[sp + 1])) { lba = a.substring(sp + 1).toInt(); a = a.substring(0, sp); }
    File f = SD.open(a, "r");
    if (!f) Serial.printf("  pcread: cannot open %s" "\n", a.c_str());
    else {
      uint8_t b[512]; bool sk = f.seek((uint64_t)lba * 512); int got = f.read(b, 512);
      Serial.printf("  pcread %s sector %u: size %u, seek %s, read %d:", a.c_str(), (unsigned)lba, (unsigned)f.size(), sk ? "ok" : "FAILED", got);
      for (int i = 0; i < 16; i++) Serial.printf(" %02x", b[i]);
      Serial.printf(" ... %02x %02x" "\n", b[510], b[511]);
      f.close();
    }
  } else if (c == "pclink") {
    // the ESP32-to-FPGA link checked on the PC core: 4 kB into its disk buffer, quad (the fast way, as the
    // disk task sends sectors) and a bit at a time, each read back word by word
    if (pc::on) Serial.println("  pclink: the PC is running a disk -- stop it first (start another game)");
    else {
      // (the pattern in internal RAM, as the disk task's buffer: the quad write sends from it; taken for the test only)
      uint32_t *pat = (uint32_t *)heap_caps_malloc(4096, MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
      uint32_t *back = (uint32_t *)heap_caps_malloc(4096, MALLOC_CAP_SPIRAM);
      if (!pat || !back) Serial.println("  pclink: no memory");
      for (int pass = 0; pat && back && pass < 2; pass++) {
        bool quad = pass == 0 && fpga.quadWired();
        int bad = 0, lane[4] = { 0, 0, 0, 0 };
        for (int rep = 0; rep < 8; rep++) {
          for (int i = 0; i < 1024; i++) pat[i] = esp_random();
          if (quad) fpga.busWriteQuad(pc::DSK_BUF, pat, 1024); else fpga.busWriteFast(pc::DSK_BUF, pat, 1024);
          for (int i = 0; i < 1024; i++) back[i] = fpga.busRead(pc::DSK_BUF + 4 * i);
          for (int i = 0; i < 1024; i++) if (back[i] != pat[i]) {
            if (bad < 3) Serial.printf("    word %d: wrote %08x read %08x\n", i, (unsigned)pat[i], (unsigned)back[i]);
            bad++; uint32_t x = back[i] ^ pat[i]; for (int b = 0; b < 32; b++) if (x >> b & 1) lane[b & 3]++;
          }
        }
        Serial.printf("  pclink %s: %d of 8192 words wrong (wrong bits by wire: 0 %d, 1 %d, 2 %d, 3 %d)\n",
                      quad ? "quad (4 wires)" : (pass == 0 ? "single (no quad wires found)" : "single"), bad, lane[0], lane[1], lane[2], lane[3]);
      }
      free(pat); free(back);
    }
  } else if (c.startsWith("ls ")) {
    // ls <folder>: what is on the card there (a game's path for "play")
    String dir = c.substring(3); dir.trim();
    File d = SD.open(dir);
    int n = 0;
    while (d) {
      File e = d.openNextFile();
      if (!e) break;
      Serial.printf("  %s%s %u\n", e.name(), e.isDirectory() ? "/" : "", (unsigned)e.size());
      e.close();
      if (++n >= 200) break;
    }
    if (d) d.close();
    Serial.printf("  (%d)\n", n);
  } else if (c.startsWith("play ")) {
    // play <path>: a game started exactly as the menu starts it (its console installed if need be) -- for
    // testing every core from the PC
    String path = c.substring(5); path.trim();
    int s1 = path.indexOf('/', 1), s2 = s1 >= 0 ? path.indexOf('/', s1 + 1) : -1;
    String folder = (s1 >= 0 && s2 > s1) ? path.substring(s1 + 1, s2) : String("");
    int m = path.startsWith("/discs/") ? 4 : menu::machineOfFolder(folder);
    File f = SD.open(path);
    if (m < 0 || !f) { Serial.printf("  play: no %s (or no console for '%s')\n", path.c_str(), folder.c_str()); if (f) f.close(); }
    else {
      static String keepPath, keepName;
      keepPath = path;
      keepName = path.substring(path.lastIndexOf('/') + 1); keepName = keepName.substring(0, keepName.lastIndexOf('.'));
      menu::Game g = { keepPath.c_str(), keepName.c_str(), (int8_t)m, (uint32_t)f.size() };
      f.close();
      menu::playGame(g);
      Serial.printf("  play: %s on %s%s%s\n", path.c_str(), menu::MACHINES[m].name, menu::note.length() ? " -- " : "", menu::note.c_str());
    }
  } else if (c == "boot" || c == "core") {
    fpga.boot(true);
    Serial.println("  booting the core");
  } else if (c == "shell") {
    pc::stop();
    fpga.forceShell();
    Serial.println(PIN_PROG_B >= 0 ? "  pulled PROGRAM_B, back in the shell"
                                   : "  PROGRAM_B is not wired");
  } else if (c.length()) {
    Serial.println("  state | cores | install <name> | boot | shell | log on|off");
  }
}

void loop() {
  pads::poll();
  pc::watch();
  noteStep();
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
  // A bad "U blk" (wrong CRC, wrong offset, bytes that stopped coming): whatever follows is the
  // rest of the PC's blocks, not lines, so it is all dropped until the line has been quiet for
  // 300 ms, and only then one "= error at <end>": the PC sends again from there.
  if (blkWant && millis() - blkT > 1000) { blkWant = 0; blkSkip = true; blkT = millis(); }
  if (blkSkip) {
    while (Serial.available()) { Serial.read(blkBuf, sizeof(blkBuf)); blkT = millis(); }
    if (millis() - blkT < 300) return;
    blkSkip = false; serLine = "";
    Serial.printf("= error at %x\n", (unsigned)putPos);
  }
  while (Serial.available()) {
    if (blkWant) {                                // a "U blk" block's raw bytes
      blkGot += Serial.read(blkBuf + blkGot, blkWant - blkGot);
      if (blkGot < blkWant) continue;
      uint32_t n = blkWant; blkWant = 0;
      if (!putFile || blkOfs != putPos || crc32(0, blkBuf, n) != blkCrc) {
        blkSkip = true; blkT = millis(); return;
      }
      putWrite(blkBuf, n);
      continue;
    }
    char ch = Serial.read();
    if (ch == char(10) || ch == char(13)) {
      if (serLine.length()) {
        if (!inUpload || serLine[0] == 'P') serialCommand(serLine);   // (a pad line: at once)
        else if (heldN < 4) heldCmd[heldN++] = serLine;               // (the rest: after it)
        serLine = "";
      }
    } else if (serLine.length() < 256) {        // (a U line: 252 characters of base64)
      serLine += ch;
    }
  }
}
