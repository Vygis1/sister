// pc.h - the ESP32's side of the PC core (rtl/pc_top.v): what starts it, its hard disk, its keyboard.
//
// A "game" for the PC is a hard-disk image in /roms/pc (tools/pc/mkdisk.sh makes one: FreeDOS and
// Doom), with its configuration beside it (<name>.cfg, tools/pc/pccfg.py: the CMOS and the disk's
// identify data, written into the core before the CPU runs). The BIOS and the VGA BIOS are
// /pc/boot0.rom and /pc/boot1.rom (Bochs's, LGPL: in 486Tang's tools/).
//
// The disk: pc_disk.v asks for a piece -- up to eight sectors from a sector -- and this task, which
// looks every millisecond, reads it from the image into the core's buffer (one quad write) and says
// done; a write the other way round. The image stays open while the PC runs.
//
// The CD-ROM drive (the core's secondary IDE channel): cdrom.h, MiSTer's ATAPI code, served by the same
// task; the disc is the cue sheet named as the image (/roms/pc/rayman.img -> /roms/pc/rayman.cue), its
// bin files beside it. Its CD audio goes into the core's 44.1 kHz FIFO a sector at a time.
//
// The keyboard: bytes (PS/2 set 2 scan codes, make and F0 break) from the PC -- pc/pad.py's keyboard
// window -- through the serial console ("kb <hex> ..."), and the controller's buttons as the keys
// Doom wants, while no menu is up.
#pragma once
#include <Arduino.h>

namespace pc {

static const uint32_t PAGE = 0x00080000, CTRL = PAGE + 0x7000, KBD = PAGE + 0x7004, MGMT_A = PAGE + 0x7008,
                      MGMT_D = PAGE + 0x700C, FILL_BASE = PAGE + 0x7010, STAT = PAGE + 0x7014, DBG = PAGE + 0x7018,
                      DSK_REQ = PAGE + 0x7020, DSK_LBA = PAGE + 0x7024, DSK_DONE = PAGE + 0x7028, DSK_BUF = PAGE + 0x8000;
static const int CONSOLE_PC = 11;           // (console_top's number for it)
static const uint32_t MOUSE = PAGE + 0x705C;   // (a byte of a PS/2 mouse packet: pc_top)
static const uint32_t CD_REG = PAGE + 0xA000, CD_AUDIO = PAGE + 0xB000, CD_BUF = PAGE + 0xC000;

static File disk;
static void padMapLoad(const String &imgPath);   // (below, with the controller's keys)
static volatile bool on = false;            // the PC is running with a disk open
static volatile bool inReq = false;         // the disk task is inside a request (stop() waits it out)
static volatile bool focus = true;          // the controller drives the keyboard (no menu up)
static TaskHandle_t task = nullptr;
static uint32_t served = 0, written = 0, outside = 0;
static uint32_t diskSectors = 0;            // the image's size: no request may reach past it
// where a request's time goes (pcstat): requests, and microseconds in each step summed
static uint32_t nReq = 0; static uint64_t usGap = 0, usSeek = 0, usRead = 0, usLink = 0;
static uint32_t lastDone = 0;
// the waits between requests, by length: <0.1, <0.5, <1, <2, <5, <10, <20, <50 ms, more
static uint32_t gapHist[9];
static const uint32_t GAP_EDGES[8] = { 100, 500, 1000, 2000, 5000, 10000, 20000, 50000 };

// the keyboard: a byte at a time into the core (the PS/2 device queues them)
static void key(uint8_t b) { fpga.padWrite(KBD, b); }
static void keys(const uint8_t *b, int n) { for (int i = 0; i < n; i++) key(b[i]); }

}  // namespace pc

// --- the CD drive's hooks (cdrom.h) ------------------------------------------------------------------------
struct CdFile {
  File f;
  bool open(const char *p) { f = SD.open(p, FILE_READ); return (bool)f; }
  bool seek(uint64_t pos) { return f && f.seek((uint32_t)pos); }
  int read(uint8_t *d, int n) { return f ? (int)f.read(d, n) : -1; }
  uint64_t size() { return f ? f.size() : 0; }
  void close() { if (f) f.close(); }
};
static uint16_t cd_reg_rd(int r) { return (uint16_t)fpga.busRead(pc::CD_REG + 4 * r); }
static void cd_reg_wr(int r, uint16_t v) { fpga.busWrite(pc::CD_REG + 4 * r, v); }
// (the CD's buffers are in PSRAM -- internal RAM is ~25 kB beside Bluetooth, and a 16 kB buffer there made
// its controller assert -- so what goes to the core passes through the disk's 4 kB internal buffer)
namespace pc {
static uint32_t *w = nullptr;
// what the disk task is doing and since when (watch(), on the other CPU, reports a step stuck for 2 s:
// the task watchdog resets the chip at 5 s and says only which task it was)
static volatile const char *step = "idle";
static volatile uint32_t stepT = 0, stepArg = 0;
static inline void at(const char *s, uint32_t arg = 0) { step = s; stepArg = arg; stepT = millis(); }
}
static void cd_send(uint32_t addr, const void *d, uint32_t n, bool step) {
  const uint8_t *b = (const uint8_t *)d;
  for (uint32_t off = 0; off < n; off += 4096) {
    uint32_t len = (n - off > 4096) ? 4096 : n - off, words = (len + 3) / 4;
    memcpy(pc::w, b + off, len);
    uint32_t a = addr + (step ? off : 0);
    if (fpga.quadWired()) fpga.busWriteQuad(a, pc::w, words); else fpga.busWriteFast(a, pc::w, words);
  }
}
static void cd_buf_wr(const void *d, uint32_t n) { cd_send(pc::CD_BUF, d, n, true); }
static void cd_buf_rd(void *d, uint32_t n) {
  uint8_t *b = (uint8_t *)d;
  for (uint32_t i = 0; i < (n + 3) / 4; i++) {
    uint32_t w = fpga.busRead(pc::CD_BUF + 4 * i);
    memcpy(b + 4 * i, &w, (n - 4 * i >= 4) ? 4 : n - 4 * i);
  }
}
static void cd_audio_wr(const uint32_t *s, int n) { cd_send(pc::CD_AUDIO, s, n * 4, false); }
static void cd_log(const char *fmt, ...) {
  char b[160]; va_list a; va_start(a, fmt); vsnprintf(b, sizeof b, fmt, a); va_end(a); Log.printf("%s", b);
}
// (the quad link reads its words out of internal RAM)
#define CD_MALLOC_BUF(n) heap_caps_malloc((n), MALLOC_CAP_SPIRAM)
#define CD_MALLOC_RAW(n) heap_caps_malloc((n), MALLOC_CAP_SPIRAM)     // (only copied out of: PSRAM will do)
#define CD_STEP(s, a) pc::at(s, a)
#include "cdrom.h"

namespace pc {

// --- the disk --------------------------------------------------------------------------------------
// Measured on the board (pctime), before: every request ONE sector (the IDE controller asks for them
// one at a time), and per sector 10.3 ms of waiting for it to be seen -- the task slept a tick between
// looks, and a tick here is 10 ms -- plus 3.4 ms reading 512 bytes off the card (a small read's fixed
// cost) and 0.6 ms seeking: 35 kB/s. Now: while the PC is reading, the task looks again at once (it
// sleeps only after 20 ms of nothing), and the image is read in 32 kB blocks into a cache in PSRAM
// (1 MB, the least recently used block goes) -- DOS reads files a sector after the next.
static const uint32_t CB_SECT = 64, CB_N = 32;      // 64 sectors (32 kB) a block, 32 blocks
struct CBlock { int32_t blk; uint32_t used; uint8_t *d; };
static CBlock cache[CB_N];
static uint32_t cacheClock = 0, cHits = 0, cMiss = 0;
static void cacheClear() { for (auto &b : cache) b.blk = -1; }
static uint8_t *cacheSector(uint32_t lba) {
  int32_t blk = lba / CB_SECT;
  CBlock *v = nullptr;
  for (auto &b : cache) {
    if (b.blk == blk && b.d) { b.used = ++cacheClock; cHits++; return b.d + (lba % CB_SECT) * 512; }
    if (!v || b.used < v->used) v = &b;
  }
  if (!v->d) v->d = (uint8_t *)heap_caps_malloc(CB_SECT * 512, MALLOC_CAP_SPIRAM);
  if (!v->d) return nullptr;
  size_t got = 0;
  if (disk && disk.seek((uint64_t)blk * CB_SECT * 512)) got = disk.read(v->d, CB_SECT * 512);
  if (got < CB_SECT * 512) {
    // (short only at the image's end; anywhere else the card read failed -- zeros go to the PC: say so)
    if ((uint64_t)blk * CB_SECT * 512 + got < (uint64_t)diskSectors * 512)
      Log.printf("pc disk: block %d read %u of %u bytes (file %s, position %u)" "\n", (int)blk, (unsigned)got, (unsigned)(CB_SECT * 512),
                 disk ? "open" : "NOT open", disk ? (unsigned)disk.position() : 0u);
    memset(v->d + got, 0, CB_SECT * 512 - got);
  }
  v->blk = blk; v->used = ++cacheClock; cMiss++;
  return v->d + (lba % CB_SECT) * 512;
}
// the disk's buffer: eight sectors, internal RAM (the quad link reads it); taken in start(), before the CD
// drive's -- the CD's buffers once left none and the task wrote through a null pointer (the reboot loop)
// is the board still the PC? console_top's 0x20: {cores built, ..., console} -- console 11, and a core built.
// When the board has left the PC (another console, the menu image, a reset) its registers read garbage:
// the task once took that for "write sector 0" and wrote the buffer's zeros over Doom's boot sector
// (2026-10-19, "Boot failed: not a bootable disk"), and sector 4294967295 requests came in the same way
static bool stillPc() {
  uint32_t v = fpga.busRead(PAGE + 0x20);
  return (v & 0xF) == (uint32_t)CONSOLE_PC && (v >> 16) != 0 && v != 0xFFFFFFFFu;
}
static void diskLoop(void *) {
  for (;;) {
    inReq = false;
    if (!on) { vTaskDelay(20); continue; }
    inReq = true;
    // a tick's sleep every 100 ms whatever is going on: CPU 0's idle task must run or the watchdog
    // resets the chip -- and the paths below that look again at once (the disk's, the CD's, CD audio's
    // every 13 ms) would otherwise never let it
    static uint32_t yieldT = 0;
    if (millis() - yieldT > 100) { yieldT = millis(); vTaskDelay(1); }
    // (the menu or a pad wants the link: theirs first -- but twice at most in a row: the menu drawing
    // takes the link over and over, and stepping aside every time stalled the game's disk for a minute)
    static int asideN = 0;
    if (fpga.othersWaiting() && asideN < 2) { asideN++; vTaskDelay(1); continue; }
    asideN = 0;
    uint32_t req = fpga.busRead(DSK_REQ);
    // the CD drive's request (or a reset to finish) and CD audio's room for a sector
    int cdr = (req >> 24) & 7;
    if (cdr || cdrom::busy()) { at("cd request", cdr); cdrom::io(cdr); }
    if (((req >> 27) & 1) && cdrom::wantAudio()) { at("cd audio", cdrom::play_start); cdrom::audio(); }
    at("poll");
    // Nothing for the disk: a tick's sleep, always. This task shares CPU 0 with Bluetooth; it used to
    // look again at once for 20 ms after any work, and with CD audio wanting a sector every 13 ms it never
    // stopped -- the controller asserted (rwbt.c 393) as Rayman's music began and the pad would not
    // connect. A tick (1 ms) costs little: the core reads ahead, eight sectors a request.
    if (!(req >> 31)) { vTaskDelay(1); continue; }
    if (!stillPc()) {
      on = false;
      Log.printf("pc disk: the board is not the PC any more (request %08x): the disk task stops, nothing written" "\n", (unsigned)req);
      continue;
    }
    uint32_t t0 = micros();
    if (lastDone) {
      uint32_t g = t0 - lastDone; usGap += g;
      int k = 0; while (k < 8 && g >= GAP_EDGES[k]) k++;
      gapHist[k]++;
    }
    uint32_t lba = fpga.busRead(DSK_LBA), n = (req >> 16) & 15;
    // (a request past the image's end is refused: a write there would make the file on the card grow)
    if (lba >= diskSectors || lba + ((req >> 30) & 1 ? ((n == 0 || n > 8) ? 1 : n) : 0) > diskSectors) {
      if (outside++ < 8) Log.printf("pc disk: sector %u is past the image's %u; refused\n", lba, diskSectors);
      fpga.busWrite(DSK_DONE, 1);
      lastDone = micros();
      continue;
    }
    bool wr = (req >> 30) & 1;
    if (n == 0 || n > 8) n = 1;
    if (!wr) {
      uint32_t t1 = micros();
      // eight sectors from the one asked for, whatever was asked: the core keeps them and answers the
      // next reads itself (read ahead, pc_disk.v); DSK_DONE says how many went in
      n = 8;
      at("disk read", lba);
      for (uint32_t i = 0; i < n; i++) {
        uint8_t *s = cacheSector(lba + i);
        if (s) memcpy((uint8_t *)w + i * 512, s, 512); else memset((uint8_t *)w + i * 512, 0, 512);
      }
      uint32_t t3 = micros();
      if (fpga.quadWired()) fpga.busWriteQuad(DSK_BUF, w, n * 128); else fpga.busWriteFast(DSK_BUF, w, n * 128);
      usRead += t3 - t1; usLink += (micros() - t3) + (t1 - t0);
      nReq++;
      served += n;
    } else {
      at("disk write", lba);
      for (uint32_t i = 0; i < n * 128; i++) w[i] = fpga.busRead(DSK_BUF + 4 * i);
      if (!stillPc()) { on = false; Log.printf("pc disk: the board left the PC during a write to sector %u: not written" "\n", (unsigned)lba); continue; }
      if (disk && disk.seek((uint64_t)lba * 512)) { disk.write((const uint8_t *)w, n * 512); disk.flush(); }
      // (the cache kept the same: a block holding these sectors gets them too)
      for (uint32_t i = 0; i < n; i++)
        for (auto &b : cache)
          if (b.d && b.blk == (int32_t)((lba + i) / CB_SECT)) memcpy(b.d + ((lba + i) % CB_SECT) * 512, (uint8_t *)w + i * 512, 512);
      written += n;
    }
    fpga.busWrite(DSK_DONE, wr ? 1 : n);              // (a read: the sectors now in the buffer)
    lastDone = micros();
    // (now and then a tick's sleep even while busy: CPU 0's idle task must run, or the watchdog
    // resets the chip -- the install task found that out)

  }
}

// --- starting it -------------------------------------------------------------------------------------
static bool fill(const char *path, uint32_t base, bool (*stream)(File &, uint32_t, uint32_t, int), uint32_t fillAddr) {
  File f = SD.open(path);
  if (!f) return false;
  fpga.busWrite(FILL_BASE, base);
  bool ok = stream(f, fillAddr, f.size(), 0);
  f.close();
  return ok;
}
// the image's configuration, the BIOSes, the disk open, run. stream: menu.h's loader (the fill path)
static String start(const String &imgPath, bool (*stream)(File &, uint32_t, uint32_t, int), uint32_t fillAddr, uint32_t bankReg) {
  on = false;
  if (disk) disk.close();
  // the PlayStation's disc reader off the card: it comes back at boot for the last PS1 disc (discRemember)
  // and went on reading -- and failing ("disc: reopened the image") -- beside this task, on the other
  // CPU; both of the day's watchdog resets came straight after it
  readerPause();
  fpga.busWrite(CTRL, 2); delay(2); fpga.busWrite(CTRL, 0);     // (the CPU held; the rest reset: nothing of the last start left)
  String cfgPath = imgPath.substring(0, imgPath.lastIndexOf('.')) + ".cfg";
  File c = SD.open(cfgPath);
  if (!c) return "no " + cfgPath + " (tools/pc/pccfg.py makes it)";
  int n = 0;
  for (;;) {
    uint32_t pr[2];
    if (c.read((uint8_t *)pr, 4) != 4 || pr[0] == 0) break;
    if (c.read((uint8_t *)&pr[1], 4) != 4) break;
    fpga.busWrite(MGMT_A, pr[0]); fpga.busWrite(MGMT_D, pr[1]); n++;
  }
  c.close();
  fpga.busWrite(bankReg, 0);
  if (!fill("/pc/boot0.rom", 0xF0000, stream, fillAddr)) return "no /pc/boot0.rom (the BIOS)";
  if (!fill("/pc/boot1.rom", 0xC0000, stream, fillAddr)) return "no /pc/boot1.rom (the VGA BIOS)";
  if (!w) w = (uint32_t *)heap_caps_malloc(8 * 512, MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
  if (!w) return "no memory for the disk's buffer";
  disk = SD.open(imgPath, "r+");
  if (!disk) return "cannot open " + imgPath;
  diskSectors = disk.size() / 512; outside = 0;
  padMapLoad(imgPath);                      // (the controller's keys for this game: <name>.pad, else Doom's)
  // the CD: the cue sheet named as the image, if there is one; else no drive
  String cuePath = imgPath.substring(0, imgPath.lastIndexOf('.')) + ".cue";
  File q = SD.open(cuePath);
  if (q && q.size() < 32768) {
    String text = q.readString();
    q.close();
    cdrom::insert(cuePath.c_str(), (char *)text.c_str());
  } else {
    if (q) q.close();
    cdrom::eject();
  }
  served = written = 0; nReq = 0; usGap = usSeek = usRead = usLink = 0; lastDone = 0; cHits = cMiss = 0; memset(gapHist, 0, sizeof gapHist);
  cacheClear();
  // (on CPU 1, beside the menu's loop -- not CPU 0, Bluetooth's: a disk write holds the CPU for tens of
  // milliseconds -- 4 kB read back over the link, the card flushed -- and the Bluetooth controller asserted
  // (rwbt.c 393) and took the chip down while Transport Tycoon wrote its files, 2026-10-20)
  if (!task) xTaskCreatePinnedToCore(diskLoop, "pcdisk", 4096, nullptr, 1, &task, 1);
  on = true; focus = true;
  fpga.busWrite(CTRL, 1);
  Log.printf("pc: %s, %d configuration writes, BIOS in, running%s", imgPath.c_str(), n, "\n");
  return "";
}
// (called by the main loop, on the other CPU)
static void watch() {
  static uint32_t said = 0;
  uint32_t t = stepT;
  if (on && t && millis() - t > 2000 && t != said) {
    said = t;
    Log.printf("pc: the disk task has been in '%s' (%u) for %u ms\n", (const char *)step, (unsigned)stepArg, (unsigned)(millis() - t));
  }
}
// (the task first: it may be inside a request on the other CPU, reading the very file -- closing it under
// the task's feet is a crash; it finishes the request it is in, then sees on = false)
static void stop() {
  on = false;
  uint32_t t0 = millis();
  while (inReq && millis() - t0 < 1000) delay(2);
  if (disk) disk.close();
}

// --- the controller as keys (set 2) ---------------------------------------------------------------------
// Each of the 14 buttons sends up to three keys, pressed and released with it. The game's own map is the
// text file beside its image (/roms/pc/<name>.pad): a line a button, "button = key, key ...", '#' a
// comment -- buttons up down left right a b x y l1 r1 l2 r2 start select; keys as in KEYS below. With
// no file, Doom's: arrows, fire (Ctrl), use (Space), run (Shift), strafe (, .), map (Tab), Enter, Esc, Y, N.
struct PadKey { uint8_t code; bool e0; };
static const int NBTN = 14, KPB = 3;
static const char *const BTN[NBTN] = { "up", "down", "left", "right", "a", "b", "x", "l1", "r1", "y", "start", "select", "r2", "l2" };
struct KeyName { const char *name; uint8_t code; bool e0; };
static const KeyName KEYS[] = {
  { "a", 0x1C }, { "b", 0x32 }, { "c", 0x21 }, { "d", 0x23 }, { "e", 0x24 }, { "f", 0x2B }, { "g", 0x34 },
  { "h", 0x33 }, { "i", 0x43 }, { "j", 0x3B }, { "k", 0x42 }, { "l", 0x4B }, { "m", 0x3A }, { "n", 0x31 },
  { "o", 0x44 }, { "p", 0x4D }, { "q", 0x15 }, { "r", 0x2D }, { "s", 0x1B }, { "t", 0x2C }, { "u", 0x3C },
  { "v", 0x2A }, { "w", 0x1D }, { "x", 0x22 }, { "y", 0x35 }, { "z", 0x1A },
  { "0", 0x45 }, { "1", 0x16 }, { "2", 0x1E }, { "3", 0x26 }, { "4", 0x25 }, { "5", 0x2E }, { "6", 0x36 },
  { "7", 0x3D }, { "8", 0x3E }, { "9", 0x46 },
  { "enter", 0x5A }, { "esc", 0x76 }, { "space", 0x29 }, { "tab", 0x0D }, { "backspace", 0x66 },
  { "shift", 0x12 }, { "rshift", 0x59 }, { "ctrl", 0x14 }, { "alt", 0x11 }, { "comma", 0x41 }, { "period", 0x49 },
  { "minus", 0x4E }, { "equals", 0x55 }, { "slash", 0x4A }, { "semicolon", 0x4C }, { "quote", 0x52 },
  { "lbracket", 0x54 }, { "rbracket", 0x5B }, { "backslash", 0x5D }, { "backquote", 0x0E },
  { "f1", 0x05 }, { "f2", 0x06 }, { "f3", 0x04 }, { "f4", 0x0C }, { "f5", 0x03 }, { "f6", 0x0B },
  { "f7", 0x83 }, { "f8", 0x0A }, { "f9", 0x01 }, { "f10", 0x09 }, { "f11", 0x78 }, { "f12", 0x07 },
  { "kp0", 0x70 }, { "kp1", 0x69 }, { "kp2", 0x72 }, { "kp3", 0x7A }, { "kp4", 0x6B }, { "kp5", 0x73 },
  { "kp6", 0x74 }, { "kp7", 0x6C }, { "kp8", 0x75 }, { "kp9", 0x7D }, { "kpplus", 0x79 }, { "kpminus", 0x7B },
  { "kpstar", 0x7C }, { "kpenter", 0x5A, true },
  { "arrowup", 0x75, true }, { "arrowdown", 0x72, true }, { "arrowleft", 0x6B, true }, { "arrowright", 0x74, true },
  { "home", 0x6C, true }, { "end", 0x69, true }, { "pageup", 0x7D, true }, { "pagedown", 0x7A, true },
  { "insert", 0x70, true }, { "delete", 0x71, true },
  // (not keys: the mouse's buttons -- padKeys sends them in its packets)
  { "mouse_left", 0xF1 }, { "mouse_right", 0xF2 }, { "mouse_middle", 0xF3 },
};
static const uint8_t MB_FIRST = 0xF1;
static bool lstickMouse = false;            // the .pad file's "lstick = mouse": the left stick moves it too
static float mouseSpeed = 4.0f;             // "mouse_speed = N": counts a 10 ms tick at full tilt (12 was too fast)
static PadKey padMap[NBTN][KPB];
static const PadKey DOOM_MAP[NBTN] = { { 0x75, true }, { 0x72, true }, { 0x6B, true }, { 0x74, true }, { 0x14, false },
                                       { 0x29, false }, { 0x12, false }, { 0x41, false }, { 0x49, false }, { 0x0D, false },
                                       { 0x5A, false }, { 0x76, false }, { 0x35, false }, { 0x31, false } };
static void padMapDefault() {
  memset(padMap, 0, sizeof padMap);
  for (int b = 0; b < NBTN; b++) padMap[b][0] = DOOM_MAP[b];
}
static const KeyName *keyNamed(const String &n) {
  for (auto &k : KEYS) if (n.equalsIgnoreCase(k.name)) return &k;
  return nullptr;
}
// the game's map (<image without extension>.pad), else Doom's
static void padMapLoad(const String &imgPath) {
  padMapDefault();
  lstickMouse = false;
  mouseSpeed = 4.0f;
  String path = imgPath.substring(0, imgPath.lastIndexOf('.')) + ".pad";
  File f = SD.open(path);
  if (!f) return;
  memset(padMap, 0, sizeof padMap);
  int lines = 0;
  while (f.available()) {
    String l = f.readStringUntil('\n');
    int h = l.indexOf('#'); if (h >= 0) l = l.substring(0, h);
    int eq = l.indexOf('='); if (eq < 0) continue;
    String bn = l.substring(0, eq); bn.trim();
    if (bn.equalsIgnoreCase("mouse_speed")) {
      float v = l.substring(eq + 1).toFloat();
      if (v > 0.2f && v < 50.0f) mouseSpeed = v;
      lines++;
      continue;
    }
    if (bn.equalsIgnoreCase("lstick")) {
      String v = l.substring(eq + 1); v.trim();
      lstickMouse = v.equalsIgnoreCase("mouse");
      lines++;
      continue;
    }
    int b = -1;
    for (int i = 0; i < NBTN; i++) if (bn.equalsIgnoreCase(BTN[i])) b = i;
    if (b < 0) { Log.printf("pc pad: no button '%s' in %s\n", bn.c_str(), path.c_str()); continue; }
    String rest = l.substring(eq + 1);
    int n = 0;
    while (rest.length() && n < KPB) {
      int c = rest.indexOf(',');
      String kn = c >= 0 ? rest.substring(0, c) : rest; kn.trim();
      rest = c >= 0 ? rest.substring(c + 1) : String("");
      if (!kn.length()) continue;
      const KeyName *k = keyNamed(kn);
      if (!k) { Log.printf("pc pad: no key '%s' in %s\n", kn.c_str(), path.c_str()); continue; }
      padMap[b][n++] = { k->code, k->e0 };
    }
    lines++;
  }
  f.close();
  Log.printf("pc pad: %s, %d buttons\n", path.c_str(), lines);
}
static uint16_t padWas = 0;
template <class In> static uint16_t padBits(const In &i) {
  const int DIGI = 48;
  uint16_t b = 0;
  int ly = lstickMouse ? 0 : i.ly, lx = lstickMouse ? 0 : i.lx;
  if (i.du || ly < -DIGI) b |= 1 << 0; if (i.dd || ly > DIGI) b |= 1 << 1;
  if (i.dl || lx < -DIGI) b |= 1 << 2; if (i.dr || lx > DIGI) b |= 1 << 3;
  if (i.a) b |= 1 << 4; if (i.b) b |= 1 << 5; if (i.x) b |= 1 << 6;
  if (i.l1) b |= 1 << 7; if (i.r1) b |= 1 << 8; if (i.y) b |= 1 << 9;
  if (i.start) b |= 1 << 10; if (i.sel) b |= 1 << 11; if (i.r2) b |= 1 << 12; if (i.l2) b |= 1 << 13;
  return b;
}
// the mouse: the right stick (and the left, with "lstick = mouse") as movement, the buttons mapped to
// mouse_left/right/middle as its buttons; a PS/2 packet (buttons, dx, dy -- up positive) at most every
// 10 ms while it moves or a button changes
static uint8_t mouseBtns = 0, mouseWas = 0;
static uint32_t mouseT = 0;
static float mfx = 0, mfy = 0;              // (fractions of a count carried over)
template <class In> static void mouseMove(const In &i) {
  if (millis() - mouseT < 10) return;
  mouseT = millis();
  auto axis = [](int v) -> float {          // dead zone, then faster the further it is pushed
    const int DZ = 14;
    if (v > -DZ && v < DZ) return 0.0f;
    float f = (v > 0 ? v - DZ : v + DZ) / 113.0f;
    return f * fabsf(f) * mouseSpeed;       // (counts a 10 ms tick at full tilt)
  };
  mfx += axis(i.rx) + (lstickMouse ? axis(i.lx) : 0.0f);
  mfy -= axis(i.ry) + (lstickMouse ? axis(i.ly) : 0.0f);
  int dx = (int)mfx, dy = (int)mfy;
  mfx -= dx; mfy -= dy;
  if (dx > 127) dx = 127; if (dx < -127) dx = -127; if (dy > 127) dy = 127; if (dy < -127) dy = -127;
  if (!dx && !dy && mouseBtns == mouseWas) return;
  uint8_t b0 = 0x08 | mouseBtns | (dx < 0 ? 0x10 : 0) | (dy < 0 ? 0x20 : 0);
  fpga.padWrite(MOUSE, b0); fpga.padWrite(MOUSE, (uint8_t)dx); fpga.padWrite(MOUSE, (uint8_t)dy);
  mouseWas = mouseBtns;
}
// (called by the pads' loop with the first player's buttons, when the board is the PC)
template <class In> static void padKeys(bool there, const In &i) {
  uint16_t now = (there && on && focus) ? padBits(i) : 0;
  uint16_t ch = now ^ padWas;
  for (int k = 0; k < NBTN; k++) {
    if (!((ch >> k) & 1)) continue;
    for (int j = 0; j < KPB; j++) {
      const PadKey &pk = padMap[k][j];
      if (!pk.code) continue;
      if (pk.code >= MB_FIRST) {             // a mouse button
        uint8_t m = 1 << (pk.code - MB_FIRST);
        if ((now >> k) & 1) mouseBtns |= m; else mouseBtns &= ~m;
        continue;
      }
      uint8_t s[3]; int n = 0;
      if (pk.e0) s[n++] = 0xE0;
      if (!((now >> k) & 1)) s[n++] = 0xF0;                 // released
      s[n++] = pk.code;
      keys(s, n);
    }
  }
  padWas = now;
  if (there && on && focus) mouseMove(i);
}

}  // namespace pc
