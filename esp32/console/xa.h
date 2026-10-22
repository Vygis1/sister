// xa.h - XA-ADPCM, the PlayStation's CD audio stream, decoded here for the drive.
//
// The drive (rtl/ps1_cdrom.v) queues the LBA of every XA audio sector the game lets through
// and plays 44.1 kHz stereo samples out of a 4096-sample FIFO; something has to turn the one
// into the other: this. A line-for-line port of tools/ps1/cdaudio.py's XaDecoder --
// DuckStation's ADPCM decoder and its zigzag interpolator, 37.8/18.9 kHz to 44.1 -- and
// tools/ps1/xatest.py checks it against that, word for word, on real sectors.
//
// Plain C++, no Arduino: the same file builds on the PC for the check.
#pragma once
#include <stdint.h>
// The decoding itself in IRAM, and a chunk at a time through small buffers: run from flash, with
// its output going to PSRAM, every PSRAM write could evict the loop's own code from the cache the
// two share on this chip -- 28 ms a sector at 240 MHz, fifty cycles a multiply.
#if defined(ESP_PLATFORM)
#include "esp_attr.h"
#define XA_FAST IRAM_ATTR __attribute__((optimize("O3")))
#else
#define XA_FAST
#endif

namespace xa {

static const int POS[4] = { 0, 60, 115, 98 };
static const int NEG[4] = { 0, 0, -52, -55 };

static const int16_t ZIGZAG[7][29] = {
  { 0, 0x0, 0x0, 0x0, 0x0, -0x0002, 0x000A, -0x0022, 0x0041, -0x0054, 0x0034, 0x0009, -0x010A, 0x0400, -0x0A78,
    0x234C, 0x6794, -0x1780, 0x0BCD, -0x0623, 0x0350, -0x016D, 0x006B, 0x000A, -0x0010, 0x0011, -0x0008, 0x0003, -0x0001 },
  { 0, 0x0, 0x0, -0x0002, 0x0, 0x0003, -0x0013, 0x003C, -0x004B, 0x00A2, -0x00E3, 0x0132, -0x0043, -0x0267, 0x0C9D,
    0x74BB, -0x11B4, 0x09B8, -0x05BF, 0x0372, -0x01A8, 0x00A6, -0x001B, 0x0005, 0x0006, -0x0008, 0x0003, -0x0001, 0x0 },
  { 0, 0x0, -0x0001, 0x0003, -0x0002, -0x0005, 0x001F, -0x004A, 0x00B3, -0x0192, 0x02B1, -0x039E, 0x04F8, -0x05A6, 0x7939,
    -0x05A6, 0x04F8, -0x039E, 0x02B1, -0x0192, 0x00B3, -0x004A, 0x001F, -0x0005, -0x0002, 0x0003, -0x0001, 0x0, 0x0 },
  { 0, -0x0001, 0x0003, -0x0008, 0x0006, 0x0005, -0x001B, 0x00A6, -0x01A8, 0x0372, -0x05BF, 0x09B8, -0x11B4, 0x74BB, 0x0C9D,
    -0x0267, -0x0043, 0x0132, -0x00E3, 0x00A2, -0x004B, 0x003C, -0x0013, 0x0003, 0x0, -0x0002, 0x0, 0x0, 0x0 },
  { -0x0001, 0x0003, -0x0008, 0x0011, -0x0010, 0x000A, 0x006B, -0x016D, 0x0350, -0x0623, 0x0BCD, -0x1780, 0x6794, 0x234C,
    -0x0A78, 0x0400, -0x010A, 0x0009, 0x0034, -0x0054, 0x0041, -0x0022, 0x000A, -0x0001, 0x0, 0x0001, 0x0, 0x0, 0x0 },
  { 0x0002, -0x0008, 0x0010, -0x0023, 0x002B, 0x001A, -0x00EB, 0x027B, -0x0548, 0x0AFA, -0x16FA, 0x53E0, 0x3C07, -0x1249,
    0x080E, -0x0347, 0x015B, -0x0044, -0x0017, 0x0046, -0x0023, 0x0011, -0x0005, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0 },
  { -0x0005, 0x0011, -0x0023, 0x0046, -0x0017, -0x0044, 0x015B, -0x0347, 0x080E, -0x1249, 0x3C07, 0x53E0, -0x16FA, 0x0AFA,
    -0x0548, 0x027B, -0x00EB, 0x001A, 0x002B, -0x0023, 0x0010, -0x0008, 0x0002, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0 },
};

static const int16_t T18900[7][25] = {
  { 0x0, -0x5, 0x11, -0x23, 0x46, -0x17, -0x44, 0x15b, -0x347, 0x80e, -0x1249, 0x3c07, 0x53e0,
    -0x16fa, 0xafa, -0x548, 0x27b, -0xeb, 0x1a, 0x2b, -0x23, 0x10, -0x8, 0x2, 0x0 },
  { 0x0, -0x2, 0xa, -0x22, 0x41, -0x54, 0x34, 0x9, -0x10a, 0x400, -0xa78, 0x234c, 0x6794,
    -0x1780, 0xbcd, -0x623, 0x350, -0x16d, 0x6b, 0xa, -0x10, 0x11, -0x8, 0x3, -0x1 },
  { -0x2, 0x0, 0x3, -0x13, 0x3c, -0x4b, 0xa2, -0xe3, 0x132, -0x43, -0x267, 0xc9d, 0x74bb,
    -0x11b4, 0x9b8, -0x5bf, 0x372, -0x1a8, 0xa6, -0x1b, 0x5, 0x6, -0x8, 0x3, -0x1 },
  { -0x1, 0x3, -0x2, -0x5, 0x1f, -0x4a, 0xb3, -0x192, 0x2b1, -0x39e, 0x4f8, -0x5a6, 0x7939,
    -0x5a6, 0x4f8, -0x39e, 0x2b1, -0x192, 0xb3, -0x4a, 0x1f, -0x5, -0x2, 0x3, -0x1 },
  { -0x1, 0x3, -0x8, 0x6, 0x5, -0x1b, 0xa6, -0x1a8, 0x372, -0x5bf, 0x9b8, -0x11b4, 0x74bb,
    0xc9d, -0x267, -0x43, 0x132, -0xe3, 0xa2, -0x4b, 0x3c, -0x13, 0x3, 0x0, -0x2 },
  { -0x1, 0x3, -0x8, 0x11, -0x10, 0xa, 0x6b, -0x16d, 0x350, -0x623, 0xbcd, -0x1780, 0x6794,
    0x234c, -0xa78, 0x400, -0x10a, 0x9, 0x34, -0x54, 0x41, -0x22, 0xa, -0x2, 0x0 },
  { 0x0, 0x2, -0x8, 0x10, -0x23, 0x2b, 0x1a, -0xeb, 0x27b, -0x548, 0xafa, -0x16fa, 0x53e0,
    0x3c07, -0x1249, 0x80e, -0x347, 0x15b, -0x44, -0x17, 0x46, -0x23, 0x11, -0x5, 0x0 },
};

// the most 44.1 kHz frames one sector can make: 18.9 kHz mono 4-bit, 4032 frames x 7/3
static const int MAX_OUT = 9408 + 8;

// the most one 128-byte sound group can make: 18.9 kHz mono 4-bit, 224 frames x 7/3
static const int MAX_CHUNK = 524 + 4;

static inline __attribute__((always_inline)) int32_t clip16(int64_t v) { return v < -32768 ? -32768 : v > 32767 ? 32767 : (int32_t)v; }

struct Decoder {
  int32_t prev[2][2];
  int32_t ring[2][64];             // the last 32 samples, twice over: entry p and p + 32 are the same,
                                   // so a window is contiguous ((p - k) & 31 == p + 32 - k)
  int p, six;
  bool cur; uint8_t curF, curC;   // the file/channel being played, without a filter

  void reset() {
    for (int i = 0; i < 2; i++) { prev[i][0] = prev[i][1] = 0; for (int k = 0; k < 64; k++) ring[i][k] = 0; }
    p = 0; six = 6; cur = false;
  }

  // DuckStation's "current file": with no filter, the first file/channel heard is the one
  // played until its EOF; channel 255 is junk. (Raw 2352-byte sector: subheader at 16.)
  bool accept(const uint8_t *s, bool filtered) {
    uint8_t f = s[16], c = s[17], sub = s[18];
    if (filtered) return true;
    if (!cur) {
      if (c == 255) return false;
      cur = true; curF = f; curC = c;
    } else if (curF != f || curC != c) return false;
    if (sub & 0x80) cur = false;                       // EOF: the next sector picks again
    return true;
  }

  bool stereo, half, eight;          // the sector's coding (begin)

  void begin(const uint8_t *s) {
    uint8_t coding = s[19];
    stereo = (coding & 3) == 1; half = ((coding >> 2) & 3) == 1; eight = ((coding >> 4) & 3) == 1;
  }

  // one sector into `out` as {right << 16 | left} words (the drive's FIFO format); the count
  int decode(const uint8_t *s, uint32_t *out) {
    begin(s);
    int n = 0;
    for (int ci = 0; ci < 18; ci++) n += chunk(s + 24 + ci * 128, out + n);
    return n;
  }

  // one 128-byte sound group of the sector begin() was given: at most MAX_CHUNK words
  // (defined below, out of the class: a member defined in it is inline, and an inline function
  // in IRAM has its literals placed after their use -- the linker refuses it)
  int chunk(const uint8_t *ch, uint32_t *out);
};

XA_FAST int Decoder::chunk(const uint8_t *ch, uint32_t *out) {
  int nblk = eight ? 4 : 8, per = 28 * nblk;
  int32_t smp[224];
  int n = 0;
  {
    for (int blk = 0; blk < nblk; blk++) {
      uint8_t hdr = ch[4 + blk];
      int shift = hdr & 0x0F; if (shift > 12) shift = 9;
      int flt = (hdr >> 4) & 0x0F;
      int fp = flt < 4 ? POS[flt] : 0, fn = flt < 4 ? NEG[flt] : 0;
      int32_t *pv = stereo ? prev[blk & 1] : prev[0];
      int o = stereo ? (blk / 2) * 56 + (blk % 2) : blk * 28, inc = stereo ? 2 : 1;
      for (int w = 0; w < 28; w++) {
        const uint8_t *wp = ch + 16 + 4 * w;
        uint32_t word = wp[0] | (uint32_t)wp[1] << 8 | (uint32_t)wp[2] << 16 | (uint32_t)wp[3] << 24;
        uint32_t nib = eight ? (word >> (blk * 8)) & 0xFF : (word >> (blk * 4)) & 0x0F;
        int32_t v16 = (int16_t)((nib << (eight ? 8 : 12)) & 0xFFFF);
        v16 >>= shift;
        int32_t v = clip16((int64_t)v16 + ((pv[0] * fp) >> 6) + ((pv[1] * fn) >> 6));
        pv[1] = pv[0]; pv[0] = v;
        smp[o] = v; o += inc;
      }
    }
    // this chunk's frames through the resampler
    int nf = stereo ? per / 2 : per;
    if (!half) {
      for (int i = 0; i < nf; i++) {
        ring[0][p] = ring[0][p + 32] = stereo ? smp[2 * i] : smp[i];
        ring[1][p] = ring[1][p + 32] = stereo ? smp[2 * i + 1] : smp[i];
        p = (p + 1) & 31;
        if (--six == 0) {
          six = 6;
          // 32-bit: a 16 x 16 product fits, and each term is shifted before the sum, so the
          // sum fits too -- and the ESP32 does 64-bit multiplies in software (in 64 bits this
          // took the drive task's time and the disc feed fell to 93 sectors a second)
          const int32_t *wl = &ring[0][p + 32], *wr = &ring[1][p + 32];
          for (int j = 0; j < 7; j++) {
            int32_t l = 0, r = 0;
            const int16_t *z = ZIGZAG[j];
            if (stereo) for (int k = 0; k < 29; k++) { l += (wl[-k] * z[k]) >> 15; r += (wr[-k] * z[k]) >> 15; }
            else        for (int k = 0; k < 29; k++)   l += (wl[-k] * z[k]) >> 15;
            int32_t L = clip16(l), R = stereo ? clip16(r) : L;
            out[n++] = ((uint32_t)(R & 0xFFFF) << 16) | (uint32_t)(L & 0xFFFF);
          }
        }
      }
    } else {
      int i = 0;
      while (i < nf) {
        if (six >= 7) {
          six -= 7;
          p = (p + 1) & 31;
          ring[0][p] = ring[0][p + 32] = stereo ? smp[2 * i] : smp[i];
          ring[1][p] = ring[1][p + 32] = stereo ? smp[2 * i + 1] : smp[i];
          i++;
        }
        // 32-bit, as the full-rate path: the samples are clipped to 16 bits and each table's
        // coefficients add up to at most 56,030 in magnitude, so the sum stays inside +-1.84e9
        // and comes out exactly as in 64 bits -- which the ESP32 multiplies in software (an
        // 18.9 kHz sector took 28 ms, a 37.8 kHz one 12: Syphon Filter's music fell behind)
        int32_t l = 0, r = 0;
        const int32_t *wl = &ring[0][p + 7], *wr = &ring[1][p + 7];   // ((p + 7 + k) & 31, k < 25)
        const int16_t *t = T18900[six];
        if (stereo) for (int k = 0; k < 25; k++) { l += wl[k] * t[k]; r += wr[k] * t[k]; }
        else        for (int k = 0; k < 25; k++)   l += wl[k] * t[k];
        int32_t L = clip16(l >> 15), R = stereo ? clip16(r >> 15) : L;
        out[n++] = ((uint32_t)(R & 0xFFFF) << 16) | (uint32_t)(L & 0xFFFF);
        six += 3;
      }
    }
  }
  return n;
}

}  // namespace xa
