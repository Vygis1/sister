// cdrom.h - the FPGA PC's CD-ROM drive: the ATAPI side of the IDE controller on its secondary channel
// (rtl/pc/soc/ide_hps.v), carried out here as MiSTer's ARM carries it out for its ao486.
//
// Ported from Main_MiSTer (github.com/MiSTer-devel/Main_MiSTer): ide.cpp's request handling for a CD
// drive and ide_cdrom.cpp (cue/bin images, the packet commands, CD audio) -- GPL-3.0, Copyright (C)
// MiSTer-devel and Alexey Melnikov; this file is under the same licence. Left out: CHD images, ISO
// images, the hard disk paths (our hard disk is pc_disk.v's), placeholder/hot-swap drives.
//
// What the includer provides (pc.h on the ESP32, sim/pc/main.cpp in the simulation):
//   uint16_t cd_reg_rd(int r)                    the controller's management register r (0-6)
//   void     cd_reg_wr(int r, uint16_t v)
//   void     cd_buf_wr(const void *d, uint32_t n) n bytes into its sector buffer from the start
//   void     cd_buf_rd(void *d, uint32_t n)       n bytes out of it
//   void     cd_audio_wr(const uint32_t *s, int n)   n CD audio samples {right, left} into the FIFO
//   CdFile                                       a file: bool open(const char *), bool seek(uint64_t),
//                                                int read(uint8_t *, int), uint64_t size(), close()
//   void     cd_log(const char *fmt, ...)
// and calls cdrom::io(request) with the controller's request (DSK_REQ [26:24]) -- also while it is 0,
// as MiSTer does, to finish a reset -- and cdrom::audio() when the CD audio FIFO has room for a sector.
#pragma once
#include <stdint.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <ctype.h>

#ifndef CD_STEP
#define CD_STEP(s, a)
#endif
#ifndef CD_MALLOC_BUF
#define CD_MALLOC_BUF(n) malloc(n)
#define CD_MALLOC_RAW(n) malloc(n)
#endif

namespace cdrom {

// --- the controller (ide.h) ---------------------------------------------------------------------------
enum { ST_BSY = 0x80, ST_RDY = 0x40, ST_DSC = 0x10, ST_DRQ = 0x08, ST_IRQ = 0x04, ST_END = 0x02, ST_ERR = 0x01 };
enum { ERR_ABRT = 0x04, ERR_MC = 0x20 };
enum { S_IDLE, S_RESET, S_INIT_RW, S_WAIT_PKT_CMD, S_WAIT_PKT_RD, S_WAIT_PKT_END, S_WAIT_PKT_MODE };
enum { CD_ERR_NO_DISK = 2, CD_ERR_ILLEGAL_REQUEST = 5, CD_ERR_UNIT_ATTENTION = 6 };
enum { ASC_SEQUENCE = 0x2C, ASC_ILLEGAL_OPCODE = 0x20, ASC_ILLEGAL_FIELD = 0x24, ASC_MEDIUM_CHANGED = 0x28 };
static const uint32_t RAW = 2352, COOKED = 2048, PADDING = 150, IO_MAX = 32;   // IO_MAX: 512-byte units

struct Regs {
  uint8_t io_done, features, sector_count, sector, head, drv, lba, cmd, io_size, error, status;
  uint16_t cylinder, pkt_size_limit, pkt_io_size;
  uint32_t pkt_lba, pkt_cnt;
};
struct Track {
  int file;                 // index into files[] (-1: the lead-out)
  uint32_t start, length, skip;
  uint16_t sectorSize;
  uint8_t attr, mode2, number;
};
static const int MAXT = 100, MAXF = 4;
static CdFile files[MAXF];
static char fileNames[MAXF][160];
static int nFiles = 0;
static Track track[MAXT];
static int trackCnt = 0;
static Regs regs;
static int state = S_IDLE;
static bool present = false, nul = false;
static uint8_t load_state = 3;            // 3 no disc, 1-2 becoming ready, 0 ready
static bool playing = false, paused = false;
static uint32_t play_start = 0xFFFFFFFF, play_end = 0;
static uint16_t vol_l = 256, vol_r = 256; // /256
static uint8_t sense_key = 0, asc = 0, ascq = 0;
static uint16_t ident[256];
static uint8_t *buf = nullptr;            // IO_MAX * 512 bytes (the buffer's size: 16 kB)
static uint8_t *rawbuf = nullptr;         // sectors as they are on the image, for a read
static uint32_t nReads = 0, nPkts = 0;

struct TMSF { uint8_t min, sec, fr; };
static inline TMSF frames_to_msf(uint32_t frames) {
  TMSF m; m.fr = frames % 75; frames /= 75; m.sec = frames % 60; frames /= 60; m.min = (uint8_t)frames; return m;
}

// --- the controller's registers (ide.cpp: ide_get_regs / ide_set_regs) ----------------------------------
static void get_regs() {
  uint16_t r0 = cd_reg_rd(0), r1 = cd_reg_rd(1), r2 = cd_reg_rd(2), r5 = cd_reg_rd(5);
  regs.io_done = r0 & 1; regs.features = r0 >> 8;
  regs.sector_count = r1 & 0xFF; regs.sector = r1 >> 8;
  regs.cylinder = r2;
  regs.head = r5 & 0xF; regs.drv = (r5 >> 4) & 1; regs.lba = (r5 >> 6) & 1; regs.cmd = r5 >> 8;
  regs.error = 0; regs.status = 0;
}
static bool isCd() { return present && regs.drv == 0; }
static void set_regs() {
  bool cd = isCd();
  if (!cd && !(regs.status & (ST_BSY | ST_ERR))) regs.status |= ST_DSC;
  uint8_t d[12] = {
    (uint8_t)(cd ? 0x80 : regs.io_size), regs.error, regs.sector_count, regs.sector,
    (uint8_t)regs.cylinder, (uint8_t)(regs.cylinder >> 8), 0, 0,
    (uint8_t)(cd ? regs.pkt_io_size : 0), (uint8_t)(cd ? regs.pkt_io_size >> 8 : 0),
    (uint8_t)((regs.lba ? 0xE0 : 0xA0) | (regs.drv ? 0x10 : 0) | regs.head), regs.status };
  // (the order matters: register 5 -- the status -- last; it ends the request)
  for (int r = 0; r < 6; r++) cd_reg_wr(r, d[2 * r] | (d[2 * r + 1] << 8));
}
static void send_data(const void *d, uint32_t words) { cd_buf_wr(d, words * 2); }

// --- the image: a cue sheet and its bin files (ide_cdrom.cpp: load_cue_file / add_track) -----------------
static int fileIndex(const char *name) {
  for (int i = 0; i < nFiles; i++) if (!strcmp(fileNames[i], name)) return i;
  if (nFiles >= MAXF) return -1;
  if (!files[nFiles].open(name)) return -1;
  strncpy(fileNames[nFiles], name, sizeof fileNames[0] - 1);
  return nFiles++;
}
static bool add_track(Track &curr, uint32_t &shift, int32_t prestart, uint32_t &totalPregap, uint32_t currPregap, const char *fname) {
  uint32_t skip = 0;
  if (trackCnt >= MAXT) return false;
  if (prestart >= 0) {
    if (prestart > (int32_t)curr.start) return false;
    skip = curr.start - prestart;
  }
  curr.file = fname[0] ? fileIndex(fname) : -1;
  if (fname[0] && curr.file < 0) { cd_log("cd: cannot open %s\n", fname); return false; }
  if (!trackCnt) {
    curr.skip = skip * curr.sectorSize;
    curr.start += currPregap;
    totalPregap = currPregap;
    track[trackCnt++] = curr;
    return true;
  }
  Track &prev = track[trackCnt - 1];
  if (curr.file == prev.file) {
    curr.start += shift;
    if (!prev.length) prev.length = curr.start + totalPregap - prev.start - skip;
    curr.skip += prev.skip + prev.length * prev.sectorSize + skip * curr.sectorSize;
    totalPregap += currPregap;
    curr.start += totalPregap;
  } else {
    uint64_t size = prev.file >= 0 ? files[prev.file].size() : 0;
    uint32_t tmp = (uint32_t)(size - prev.skip);
    prev.length = tmp / prev.sectorSize;
    if (tmp % prev.sectorSize) prev.length++;
    curr.start += prev.start + prev.length + currPregap;
    curr.skip = skip * curr.sectorSize;
    shift += prev.start + prev.length;
    totalPregap = currPregap;
  }
  if (curr.number <= 1 || prev.number + 1 != curr.number || curr.start < prev.start + prev.length) {
    cd_log("cd: track %d failed the checks\n", curr.number);
    return false;
  }
  track[trackCnt++] = curr;
  return true;
}
static bool timecode(const char *s, uint32_t &frames) {
  unsigned m, sec, f;
  if (sscanf(s, "%u:%u:%u", &m, &sec, &f) != 3) return false;
  frames = (m * 60 + sec) * 75 + f;
  return true;
}
static void closeAll() {
  for (int i = 0; i < nFiles; i++) files[i].close();
  nFiles = 0; trackCnt = 0;
}
// the cue sheet's text (whole, NUL-ended) and the folder its bin files are in (ending in '/')
static bool load_cue(char *text, const char *dir) {
  closeAll();
  Track t; memset(&t, 0, sizeof t);
  uint32_t shift = 0, currPregap = 0, totalPregap = 0;
  int32_t prestart = -1;
  bool canAdd = false;
  char fname[160] = "";
  for (char *line = strtok(text, "\r\n"); line; line = strtok(nullptr, "\r\n")) {
    while (*line == ' ' || *line == '\t') line++;
    char cmd[16] = ""; int n = 0;
    while (line[n] && line[n] != ' ' && line[n] != '\t' && n < 15) { cmd[n] = toupper((unsigned char)line[n]); n++; }
    cmd[n] = 0;
    char *rest = line + n; while (*rest == ' ' || *rest == '\t') rest++;
    bool ok = true;
    if (!strcmp(cmd, "TRACK")) {
      if (canAdd) ok = add_track(t, shift, prestart, totalPregap, currPregap, fname);
      t.start = 0; t.skip = 0; t.length = 0; currPregap = 0; prestart = -1;
      int num = 0; char type[24] = "";
      sscanf(rest, "%d %23s", &num, type);
      for (char *p = type; *p; p++) *p = toupper((unsigned char)*p);
      t.number = (uint8_t)num;
      if (!strcmp(type, "AUDIO"))            { t.sectorSize = RAW;    t.attr = 0;    t.mode2 = 0; }
      else if (!strcmp(type, "MODE1/2048"))  { t.sectorSize = COOKED; t.attr = 0x40; t.mode2 = 0; }
      else if (!strcmp(type, "MODE1/2352"))  { t.sectorSize = RAW;    t.attr = 0x40; t.mode2 = 0; }
      else if (!strcmp(type, "MODE2/2336"))  { t.sectorSize = 2336;   t.attr = 0x40; t.mode2 = 1; }
      else if (!strcmp(type, "MODE2/2352"))  { t.sectorSize = RAW;    t.attr = 0x40; t.mode2 = 1; }
      else ok = false;
      canAdd = true;
    } else if (!strcmp(cmd, "INDEX")) {
      int idx = 0; char tc[16] = ""; uint32_t frame = 0;
      sscanf(rest, "%d %15s", &idx, tc);
      ok = timecode(tc, frame);
      if (idx == 1) t.start = frame; else if (idx == 0) prestart = (int32_t)frame;
    } else if (!strcmp(cmd, "FILE")) {
      if (canAdd) ok = add_track(t, shift, prestart, totalPregap, currPregap, fname);
      canAdd = false;
      char name[128] = "";
      const char *q = strchr(rest, '"');
      if (q) { const char *e = strchr(q + 1, '"'); int l = e ? (int)(e - q - 1) : 0; if (l > 127) l = 127; memcpy(name, q + 1, l); name[l] = 0; }
      else sscanf(rest, "%127s", name);
      snprintf(fname, sizeof fname, "%s%s", dir, name);
    } else if (!strcmp(cmd, "PREGAP")) {
      ok = timecode(rest, currPregap);
    } else if (!strcmp(cmd, "CATALOG") || !strcmp(cmd, "CDTEXTFILE") || !strcmp(cmd, "FLAGS") || !strcmp(cmd, "ISRC") ||
               !strcmp(cmd, "PERFORMER") || !strcmp(cmd, "POSTGAP") || !strcmp(cmd, "REM") ||
               !strcmp(cmd, "SONGWRITER") || !strcmp(cmd, "TITLE") || !cmd[0]) {
    } else ok = false;
    if (!ok) { cd_log("cd: cue line not understood: %s\n", line); return false; }
  }
  if (!add_track(t, shift, prestart, totalPregap, currPregap, fname)) return false;
  // the lead-out
  t.number++;
  t.attr = 0;
  t.start = 0;                         // (MiSTer reads an empty slot here: 0; add_track puts it after the last track)
  t.length = 0;
  if (!add_track(t, shift, -1, totalPregap, 0, "")) return false;
  for (int i = 0; i < trackCnt; i++) if (track[i].attr == 0x40) return true;
  return false;
}
static Track *track_from_lba(uint32_t lba, bool &index0) {
  index0 = false;
  for (int i = 0; i < trackCnt; i++) {
    uint32_t s = i ? track[i - 1].start + track[i - 1].length : 0, e = track[i].start + track[i].length;
    if (lba >= s && lba <= e) { if (lba < track[i].start) index0 = true; return &track[i]; }
  }
  return nullptr;
}

// --- replies -----------------------------------------------------------------------------------------
static bool mcr_flag = false;
static void reply(uint8_t error, uint8_t a = 0, uint8_t aq = 0, bool unit_attention = true, uint8_t extra = 0) {
  state = S_IDLE;
  regs.sector_count = 3;
  if (mcr_flag && unit_attention) {
    regs.status = ST_RDY | ST_IRQ | ST_ERR;
    regs.error = (CD_ERR_UNIT_ATTENTION << 4) | ERR_MC;
    mcr_flag = false;
    sense_key = CD_ERR_UNIT_ATTENTION; asc = ASC_MEDIUM_CHANGED; ascq = 0;
  } else {
    regs.status = ST_RDY | ST_IRQ | (error ? ST_ERR : 0) | extra;
    regs.error = error << 4;
    sense_key = error; asc = a; ascq = aq;
  }
  set_regs();
}
static void pkt_send(const void *d, uint16_t size) {
  regs.pkt_io_size = (size + 1) / 2;
  send_data(d, regs.pkt_io_size);
  regs.cylinder = size;
  regs.sector_count = 2;
  regs.status = ST_RDY | ST_DRQ | ST_IRQ;
  set_regs();
  state = S_WAIT_PKT_RD;
}
static void nodisk() { if (load_state && load_state < 3) load_state--; reply(CD_ERR_NO_DISK); }

// --- the data the commands answer with (ide_cdrom.cpp) -----------------------------------------------------
static bool get_tracks(int &first, int &last, TMSF &leadOut) {
  if (trackCnt < 2 || !track[0].length) return false;
  first = track[0].number; last = track[trackCnt - 2].number;
  leadOut = frames_to_msf(track[trackCnt - 1].start + PADDING);
  return true;
}
static bool get_track_info(int n, TMSF &start, uint8_t &attr) {
  if (trackCnt < 2 || n < 1 || n >= trackCnt) return false;
  start = frames_to_msf(track[n - 1].start + PADDING);
  attr = track[n - 1].attr;
  return true;
}
static uint8_t *put_addr(uint8_t *w, TMSF m, bool time) {
  if (time) { *w++ = 0; *w++ = m.min; *w++ = m.sec; *w++ = m.fr; }
  else { uint32_t s = m.min * 4500u + m.sec * 75u + m.fr - 150u; *w++ = s >> 24; *w++ = s >> 16; *w++ = s >> 8; *w++ = s; }
  return w;
}
static int read_toc(const uint8_t *cmd) {
  // (cut to the driver's allocation length: OAKCDROM.SYS asks for room for one entry -- MiSTer's note)
  unsigned alloc = (cmd[7] << 8) | cmd[8];
  uint8_t format = cmd[2] & 0xF, from = cmd[6];
  bool time = cmd[1] & 2;
  int first, last; TMSF leadOut;
  memset(buf, 0, 8);
  if (!get_tracks(first, last, leadOut)) return 8;
  uint8_t *w = buf + 2;
  if (format == 1) {
    uint8_t attr; TMSF st;
    *w++ = 1; *w++ = 1;
    if (!get_track_info(first, st, attr)) { attr = 0x41; st = { 0, 0, 0 }; }
    *w++ = 0; *w++ = (attr >> 4) | 0x10; *w++ = (uint8_t)first; *w++ = 0;
    w = put_addr(w, st, time);
  } else if (format == 0) {
    *w++ = (uint8_t)first; *w++ = (uint8_t)last;
    for (int t = first; t <= last; t++) {
      uint8_t attr; TMSF st;
      if (!get_track_info(t, st, attr)) { attr = 0x41; st = { 0, 0, 0 }; }
      if (t < from) continue;
      if (w + 8 > buf + alloc) break;
      *w++ = 0; *w++ = (attr >> 4) | 0x10; *w++ = (uint8_t)t; *w++ = 0;
      w = put_addr(w, st, time);
    }
    if (w + 8 <= buf + alloc) { *w++ = 0; *w++ = 0x14; *w++ = 0xAA; *w++ = 0; w = put_addr(w, leadOut, time); }
  } else return 8;
  unsigned x = (unsigned)(w - buf) - 2;
  buf[0] = x >> 8; buf[1] = x;
  return (int)(w - buf);
}
static void mode_select() {
  uint8_t *page = buf + 8;
  if ((page[0] & 0x3F) == 0x0E) { vol_l = page[9] + 1; vol_r = page[11] + 1; }
}
static int mode_sense(int page) {
  uint8_t *w = buf, *plen; bool valid = false;
  memset(buf, 0, 8); w += 8;
  if (page == 0x01 || page == 0x3F) {
    valid = true; *w++ = 1; plen = w; *w++ = 0;
    *w++ = 0; *w++ = 3; *w++ = 0; *w++ = 0; *w++ = 0; *w++ = 0;
    *plen = (uint8_t)(w - plen - 1);
  }
  if (page == 0x0E || page == 0x3F) {
    valid = true; *w++ = 0x0E; plen = w; *w++ = 0;
    *w++ = 0x04; *w++ = 0; *w++ = 0; *w++ = 0; *w++ = 0; *w++ = 75;
    *w++ = 0x01; *w++ = (uint8_t)(vol_l - 1); *w++ = 0x02; *w++ = (uint8_t)(vol_l - 1);
    *w++ = 0; *w++ = 0; *w++ = 0; *w++ = 0;
    *plen = (uint8_t)(w - plen - 1);
  }
  if (page == 0x2A || page == 0x3F) {
    valid = true; *w++ = 0x2A; plen = w; *w++ = 0;
    *w++ = 0x07; *w++ = 0x00; *w++ = 0x71; *w++ = 0xFF; *w++ = 0x2F; *w++ = 0x03;
    uint32_t x = 176 * 8; *w++ = x >> 8; *w++ = x;
    x = 256; *w++ = x >> 8; *w++ = x;
    x = 6 * 256; *w++ = x >> 8; *w++ = x;
    x = 176 * 8; *w++ = x >> 8; *w++ = x;
    *plen = (uint8_t)(w - plen - 1);
  }
  if (!valid) { *w++ = (uint8_t)page; *w++ = 6; memset(w, 0, 6); w += 6; }
  uint32_t x = (uint32_t)(w - buf) - 2;
  buf[0] = x >> 8; buf[1] = x;
  return (int)(x + 2);
}
static bool get_subchan(uint8_t &attr, uint8_t &tn, uint8_t &index, TMSF &rel, TMSF &abs_) {
  attr = 0; tn = 1; index = 1; rel = { 0, 2, 0 }; abs_ = { 0, 2, 0 };
  if (play_start == 0xFFFFFFFF) return false;
  bool i0; Track *t = track_from_lba(play_start, i0);
  if (!t) return false;
  tn = t->number; attr = t->attr;
  abs_ = frames_to_msf(play_start + PADDING);
  int d = (int)play_start - (int)t->start;
  rel = frames_to_msf(d < 0 ? -d : d);
  index = i0 ? 0 : 1;
  return true;
}
static int read_subchannel(const uint8_t *cmd) {
  uint8_t list = cmd[3]; bool subq = cmd[2] & 0x40, time = cmd[1] & 2;
  memset(buf, 0, 8);
  if (list == 0 || list > 3 || list == 2 || list == 3) return 8;
  uint8_t attr, tn, index; TMSF rel, abs_;
  if (!get_subchan(attr, tn, index, rel, abs_)) return 8;
  uint8_t *w = buf;
  *w++ = 0; *w++ = !playing ? 0x13 : paused ? 0x12 : 0x11; *w++ = 0; *w++ = 0;
  if (subq) {
    *w++ = 0x01; *w++ = (attr >> 4) | 0x10; *w++ = tn; *w++ = index;
    w = put_addr(w, abs_, time); w = put_addr(w, rel, time);
  }
  unsigned x = (unsigned)(w - buf) - 4;
  buf[2] = x >> 8; buf[3] = x;
  return (int)(w - buf);
}
static int disc_info(uint16_t maxlen) {
  if (!maxlen) return 0;
  if (maxlen > 34) maxlen = 34;
  memset(buf, 0, 34);
  buf[1] = 32; buf[2] = 0xE; buf[3] = 1; buf[4] = 1; buf[5] = 1; buf[6] = (uint8_t)trackCnt; buf[7] = 0x20; buf[8] = 0;
  memset(buf + 16, 0xFF, 4); memset(buf + 20, 0xFF, 4);
  return maxlen;
}
static int track_info(uint8_t n, uint16_t maxlen) {
  if (!maxlen) return 0;
  if (maxlen > 24) maxlen = 24;
  memset(buf, 0, 24);
  buf[1] = 20; buf[2] = n; buf[3] = 1; buf[5] = 1; buf[6] = track[n].mode2 ? 2 : 1;
  uint32_t s = track[n].start; buf[8] = s >> 24; buf[9] = s >> 16; buf[10] = s >> 8; buf[11] = s;
  return maxlen;
}
static int inquiry(uint8_t maxlen) {
  static const char vendor[] = "FPGA    ", product[] = "CDROM           ";
  memset(buf, 0, 47);
  buf[0] = 5; buf[1] = 0x80; buf[2] = 0; buf[3] = 0x21; buf[4] = maxlen - 5;
  for (int i = 0; i < 8; i++) buf[i + 8] = vendor[i];
  for (int i = 0; i < 16; i++) buf[i + 16] = product[i];
  for (int i = 0; i < 4; i++) buf[i + 32] = ' ';
  for (int i = 0; i < 11; i++) buf[i + 36] = ' ';
  return maxlen;
}
static void set_sense(uint8_t sk, uint8_t a = 0, uint8_t aq = 0) {
  memset(buf, 0, 18); buf[0] = 0x70; buf[2] = sk & 0xF; buf[7] = 0; buf[12] = a; buf[13] = aq;
}
static int get_sense() {
  switch (load_state) {
  case 3: set_sense(2, 0x3A); break;
  case 2: set_sense(2, 4, 1); load_state--; break;
  case 1: set_sense(2, 28, 0); load_state--; break;
  default:
    set_sense(sense_key, asc, ascq);
    if (sense_key == CD_ERR_UNIT_ATTENTION) sense_key = asc = ascq = 0;
  }
  return 18;
}
static void get_conf(const uint8_t *cmd, uint16_t maxlen) {
  if (cmd[2] == 0 && cmd[3] == 0) {
    if (!maxlen) { reply(0); return; }
    if (maxlen > 16) maxlen = 16;
    memset(buf, 0, 16);
    buf[3] = 0x0F; buf[7] = 0x08; buf[10] = 0x03; buf[11] = 0x04; buf[13] = 0x08; buf[14] = 0x01;
    pkt_send(buf, maxlen);
  } else reply(CD_ERR_ILLEGAL_REQUEST, ASC_ILLEGAL_FIELD);
}
static void play_msf(const uint8_t *c) {
  if (c[3] == 0xFF && c[4] == 0xFF && c[5] == 0xFF) play_start = 0xFFFFFFFF;
  else { play_start = c[3] * 4500u + c[4] * 75u + c[5]; play_start = play_start >= 150 ? play_start - 150 : 0; }
  if (c[6] == 0xFF && c[7] == 0xFF && c[8] == 0xFF) play_end = 0xFFFFFFFF;
  else { play_end = c[6] * 4500u + c[7] * 75u + c[8]; play_end = play_end >= 150 ? play_end - 150 : 0; }
  if (play_start == play_end) { playing = paused = false; return; }
  if (play_start != 0xFFFFFFFF) { playing = true; paused = false; } else { playing = false; paused = true; }
}
static void play10(const uint8_t *c) {
  play_start = ((uint32_t)c[2] << 24) | (c[3] << 16) | (c[4] << 8) | c[5];
  uint16_t len = (c[7] << 8) | c[8];
  play_end = play_start + len;
  if (!len) { playing = paused = false; return; }
  if (play_start != 0xFFFFFFFF) { playing = true; paused = false; } else { playing = false; paused = true; }
}

// --- reading sectors ---------------------------------------------------------------------------------
// (MiSTer seeks and reads 2048 bytes a sector; here the run of raw sectors in one read -- a small read
// off the card costs a fixed few ms -- and the 2048 bytes of each copied out)
static void read_sectors(Track *t, uint32_t lba, uint32_t cnt) {
  if (!t || t->file < 0) { memset(buf, 0, cnt * COOKED); return; }
  uint32_t sz = t->sectorSize;
  uint64_t pos = t->skip + (uint64_t)(lba - t->start) * sz;
  CdFile &f = files[t->file];
  if (sz == COOKED) {
    if (!f.seek(pos) || f.read(buf, cnt * COOKED) != (int)(cnt * COOKED)) memset(buf, 0, cnt * COOKED);
    return;
  }
  uint32_t pre = t->mode2 ? 24 : 16;
  if (!f.seek(pos) || f.read(rawbuf, cnt * sz) != (int)(cnt * sz)) { memset(buf, 0, cnt * COOKED); return; }
  for (uint32_t i = 0; i < cnt; i++) memcpy(buf + i * COOKED, rawbuf + i * sz + pre, COOKED);
}
static void cd_read() {
  CD_STEP("cd read", regs.pkt_lba);
  uint32_t cnt = regs.pkt_cnt;
  if (cnt * 4 > IO_MAX) cnt = IO_MAX / 4;
  while (cnt * COOKED > regs.pkt_size_limit && cnt > 1) cnt--;
  bool i0; Track *t = track_from_lba(regs.pkt_lba, i0);
  read_sectors(t, regs.pkt_lba, cnt);
  regs.pkt_lba += cnt;
  regs.pkt_cnt -= cnt;
  nReads += cnt;
  pkt_send(buf, cnt * COOKED);
}

// --- a packet (ide_cdrom.cpp: cdrom_handle_pkt) ----------------------------------------------------------
static void handle_pkt() {
  uint8_t cmd[12];
  cd_buf_rd(cmd, 12);
  CD_STEP("cd packet", cmd[0]);
  nPkts++;
#ifdef CD_TRACE
  cd_log("cd: packet %02X %02X %02X %02X %02X %02X %02X %02X %02X %02X\n", cmd[0], cmd[1], cmd[2], cmd[3], cmd[4], cmd[5], cmd[6], cmd[7], cmd[8], cmd[9]);
#endif
  regs.pkt_cnt = 0;
  bool err = false;
  if (load_state || mcr_flag) {
    if (cmd[0] != 0x46 && cmd[0] != 0x4A && cmd[0] != 0x12 && cmd[0] != 0x03) { nodisk(); return; }
  }
  switch (cmd[0]) {
  case 0xA8: case 0x28:
    regs.pkt_cnt = cmd[0] == 0x28 ? ((cmd[7] << 8) | cmd[8]) : ((cmd[6] << 24) | (cmd[7] << 16) | (cmd[8] << 8) | cmd[9]);
    regs.pkt_lba = ((uint32_t)cmd[2] << 24) | (cmd[3] << 16) | (cmd[4] << 8) | cmd[5];
    if (!regs.pkt_cnt) { reply(0); break; }
    state = S_INIT_RW;
    if (!load_state) cd_read(); else nodisk();
    break;
  case 0x25: {
    if (load_state) { nodisk(); break; }
    uint32_t n = track[trackCnt - 1].start;
    buf[0] = n >> 24; buf[1] = n >> 16; buf[2] = n >> 8; buf[3] = n;
    buf[4] = 0; buf[5] = 0; buf[6] = 0x08; buf[7] = 0;
    pkt_send(buf, 8);
    break;
  }
  case 0x2B: playing = paused = false; reply(0, 0, 0, true, ST_DSC); break;
  case 0x1B: case 0x1E: case 0x35: reply(0); break;
  case 0x5A: pkt_send(buf, (uint16_t)mode_sense(cmd[2] & 0x3F)); break;
  case 0x42: if (!load_state) pkt_send(buf, (uint16_t)read_subchannel(cmd)); else nodisk(); break;
  case 0x43: if (!load_state) pkt_send(buf, (uint16_t)read_toc(cmd)); else nodisk(); break;
  case 0x4E: playing = paused = false; reply(0); break;
  case 0x12: pkt_send(buf, (uint16_t)inquiry(cmd[4])); break;
  case 0x46: get_conf(cmd, (cmd[7] << 8) | cmd[8]); break;
  case 0x51: if ((cmd[1] & 7) == 0) pkt_send(buf, (uint16_t)disc_info((cmd[7] << 8) | cmd[8])); else err = true; break;
  case 0x52:
    if (cmd[1] == 1 && cmd[5] <= trackCnt && cmd[5] != 0xFF) pkt_send(buf, (uint16_t)track_info(cmd[5], (cmd[7] << 8) | cmd[8]));
    else err = true;
    break;
  case 0x03: pkt_send(buf, (uint16_t)get_sense()); break;
  case 0x55:
    regs.cylinder = (cmd[7] << 8) | cmd[8];
    if (regs.cylinder > 512) regs.cylinder = 512;
    regs.pkt_io_size = (regs.cylinder + 1) / 2;
    regs.sector_count = 0;
    regs.status = ST_RDY | ST_DRQ | ST_IRQ;
    set_regs();
    state = S_WAIT_PKT_MODE;
    break;
  case 0x00: if (!load_state) reply(0); else nodisk(); break;   // (MiSTer: cdrom_reply(ide, 0, false) -- the false is asc_code)
  case 0x45: play10(cmd); reply(0); break;
  case 0x47: play_msf(cmd); reply(0); break;
  case 0x4B: {
    bool ok = false;
    if (playing) { paused = !(cmd[8] & 1); ok = true; }
    reply(ok ? 0 : CD_ERR_ILLEGAL_REQUEST, ASC_SEQUENCE);
    break;
  }
  default: err = true;
  }
  if (err) { cd_log("cd: packet %02X not done\n", cmd[0]); reply(CD_ERR_ILLEGAL_REQUEST, ASC_ILLEGAL_OPCODE); }
}

// --- an ATA command (ide_cdrom.cpp: cdrom_handle_cmd) -------------------------------------------------------
static bool handle_cmd() {
  switch (regs.cmd) {
  case 0xA1: {
    send_data(ident, 256);
    uint8_t drv = regs.drv;
    memset(&regs, 0, sizeof regs);
    regs.drv = drv;
    regs.pkt_io_size = 256;
    regs.status = ST_RDY | ST_DRQ | ST_IRQ | ST_END;
    set_regs();
    state = S_IDLE;
    return true;
  }
  case 0xEC:
    regs.sector = 1; regs.sector_count = 1; regs.cylinder = 0xEB14; regs.head = 0; regs.io_size = 0;
    return false;
  case 0xA0:
    if (regs.features & 1) return false;
    regs.pkt_size_limit = regs.cylinder ? regs.cylinder : IO_MAX * 512;
    regs.pkt_io_size = 6;
    regs.sector_count = 1;
    regs.status = ST_RDY | ST_DRQ;
    set_regs();
    state = S_WAIT_PKT_CMD;
    return true;
  case 0x08:
    playing = paused = false;
    regs.sector = 1; regs.sector_count = 1; regs.cylinder = 0xEB14; regs.head = 0; regs.error = 1; regs.io_size = 0;
    regs.status = 0;
    set_regs();
    return true;
  case 0xEF:
    if (regs.features == 0x03) { regs.status = ST_RDY | ST_IRQ; set_regs(); return true; }
    return false;
  default:
    return false;
  }
}

// --- the controller's requests (ide.cpp: ide_io) -------------------------------------------------------------
static void io(int req) {
  CD_STEP("cd io", req);
  if (req == 0) {
    if (state == S_RESET) { state = S_IDLE; regs.status = ST_RDY; set_regs(); }
  } else if (req == 4) {
    state = S_IDLE;
    get_regs();
#ifdef CD_TRACE
    cd_log("cd: command %02X drive %d features %02X\n", regs.cmd, regs.drv, regs.features);
#endif
    bool ok = isCd() ? handle_cmd() : false;
    if (!ok) { regs.status = ST_RDY | ST_ERR | ST_IRQ; regs.error = ERR_ABRT; set_regs(); }
  } else if (req == 5) {
    if (state == S_WAIT_PKT_CMD) handle_pkt();
    else if (state == S_WAIT_PKT_RD) { if (regs.pkt_cnt) cd_read(); else reply(0, 0, 0, false); }
    else if (state == S_WAIT_PKT_MODE) { cd_buf_rd(buf, 512); mode_select(); reply(0); }
    else { state = S_IDLE; regs.status = ST_RDY | ST_ERR | ST_IRQ; regs.error = ERR_ABRT; set_regs(); }
  } else if (req == 6) {
    playing = paused = false;
    get_regs();
    regs.head = 0;
    regs.error = isCd() ? 1 : 0;
    regs.sector = 1; regs.sector_count = 1;
    regs.cylinder = !(present && regs.drv == 0) ? 0xFFFF : 0xEB14;
    regs.status = ST_BSY;
    set_regs();
    state = S_RESET;
  }
}
static bool busy() { return state == S_RESET; }

// --- CD audio (ide_cdrom.cpp: ide_cdda_send_sector) -----------------------------------------------------
static uint32_t nAudio = 0;
static bool wantAudio() { return playing && !paused; }
static void audio() {
  if (!wantAudio()) return;
  bool i0; Track *t = track_from_lba(play_start, i0);
  uint8_t *a = rawbuf;
  bool got = false;
  if (t && !t->attr) {
    Track *rt = t;
    if (i0 && t->number > 1) rt = &track[t->number - 2];
    if (rt->file >= 0) {
      uint64_t pos = rt->skip + (uint64_t)(play_start - rt->start) * rt->sectorSize;
      got = files[rt->file].seek(pos) && files[rt->file].read(a, RAW) == (int)RAW;
    }
  }
  if (!got) memset(a, 0, RAW);
  int16_t *s = (int16_t *)a;
  if (vol_l != 256 || vol_r != 256)
    for (int i = 0; i < (int)(RAW / 2); i++) s[i] = (int16_t)((s[i] * (int32_t)((i & 1) ? vol_r : vol_l)) >> 8);
  cd_audio_wr((const uint32_t *)a, RAW / 4);
  nAudio++;
  if (++play_start >= play_end) playing = paused = false;
}

// --- the drive: a disc in it, or none -------------------------------------------------------------------------
static void setup(bool have) {
  present = true;                      // (the drive is there whether or not a disc is)
  if (!buf) buf = (uint8_t *)CD_MALLOC_BUF(IO_MAX * 512 + 64);
  if (!rawbuf) rawbuf = (uint8_t *)CD_MALLOC_RAW(8 * RAW + 64);
  if (!buf || !rawbuf) { cd_log("cd: no memory for the drive's buffers\n"); present = false; cd_reg_wr(6, 8); return; }
  static const uint16_t base[] = { 0x8580 };
  memset(ident, 0, sizeof ident);
  ident[0] = base[0];
  const char *ser = "FPCD0000            ";
  for (int i = 0; i < 10; i++) ident[10 + i] = (ser[2 * i] << 8) | ser[2 * i + 1];
  const char *model = "FPGA PC CD-ROM                          ";
  for (int i = 0; i < 20; i++) ident[27 + i] = (model[2 * i] << 8) | model[2 * i + 1];
  ident[49] = 1 << 9; ident[53] = 7; ident[65] = ident[66] = ident[67] = ident[68] = 120;
  ident[80] = 0x7E; ident[82] = (1 << 9) | (1 << 4); ident[83] = 1 << 14; ident[84] = 1 << 14;
  ident[85] = (1 << 14) | (1 << 9) | (1 << 4); ident[87] = 1 << 14;
  ident[93] = 1 | (1 << 14) | (1 << 13) | (1 << 9) | (1 << 8) | (1 << 3) | (1 << 1) | 1;
  load_state = have ? 1 : 3;
  playing = paused = false; play_start = 0xFFFFFFFF; vol_l = vol_r = 256; mcr_flag = false;
  sense_key = asc = ascq = 0;
  memset(&regs, 0, sizeof regs);
  // the controller: drive 0 present (ide.cpp: ide_img_set), no wait states, then a reset to finish
  cd_reg_wr(6, 9);
  cd_reg_wr(6, 0x200);
  state = S_RESET;
}
// the cue sheet at path (its bin files beside it): the disc in the drive; false: an empty drive
static bool insert(const char *path, char *text) {
  char dir[160]; strncpy(dir, path, sizeof dir - 1); dir[sizeof dir - 1] = 0;
  char *sl = strrchr(dir, '/'); if (sl) sl[1] = 0; else dir[0] = 0;
  bool ok = load_cue(text, dir);
  if (ok) cd_log("cd: %s, %d tracks, %u sectors\n", path, trackCnt - 1, track[trackCnt - 1].start);
  else { cd_log("cd: %s not loaded\n", path); closeAll(); }
  setup(ok);
  return ok;
}
static void eject() { closeAll(); present = false; playing = false; cd_reg_wr(6, 8); }

}  // namespace cdrom
