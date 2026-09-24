// sdprobe.cpp - the SD card's own protocol, far enough to identify it.
//
// Everything here is the SPI-mode command set from the SD Physical Layer spec.
// It is worth doing by hand rather than leaning on the SD library, because the
// library's job starts at "mount a filesystem" and the question being asked here
// is strictly before that: is there a card on the end of these four wires.

#include "sdprobe.h"
#include <driver/gpio.h>

// A card is specified to accept commands at 400 kHz or less until it is
// initialised. Going straight to full speed is the classic way to get a card
// that works on one board and not another.
static const uint32_t INIT_HZ = 400000;
static const uint32_t READ_HZ = 4000000;

static SPIClass *g_bus = nullptr;
static int       g_cs  = -1;

static inline uint8_t xfer(uint8_t v) { return g_bus->transfer(v); }
static inline void    sel(bool on)    { digitalWrite(g_cs, on ? LOW : HIGH); }

// Clock out $FF until the card stops holding the line low. A card answers a
// command somewhere in the next eight bytes; more than that means it is not
// going to.
static uint8_t waitReply() {
  for (int i = 0; i < 16; i++) {
    uint8_t r = xfer(0xFF);
    if (!(r & 0x80)) return r;          // the top bit is clear in every R1
  }
  return 0xFF;
}

// CRC is only checked for CMD0 and CMD8, and only until the card is told
// otherwise -- so the two constants below are the only ones that ever matter.
static uint8_t cmd(uint8_t index, uint32_t arg, uint8_t crc) {
  xfer(0xFF);
  xfer(0x40 | index);
  xfer(arg >> 24); xfer(arg >> 16); xfer(arg >> 8); xfer(arg);
  xfer(crc);
  if (index == 12) xfer(0xFF);          // CMD12 has a stuff byte
  return waitReply();
}

static uint8_t acmd(uint8_t index, uint32_t arg) {
  cmd(55, 0, 0x01);
  return cmd(index, arg, 0x01);
}

SdProbe sdProbe(SPIClass &bus, int csPin) {
  SdProbe p;
  g_bus = &bus;
  g_cs  = csPin;

  pinMode(g_cs, OUTPUT);
  sel(false);

  bus.beginTransaction(SPISettings(INIT_HZ, MSBFIRST, SPI_MODE0));

  // At least 74 clocks with chip select HIGH, which is how a card is told to
  // enter SPI mode at all. Ten bytes is 80.
  for (int i = 0; i < 10; i++) xfer(0xFF);

  sel(true);
  uint8_t r = 0xFF;
  for (int tries = 0; tries < 10 && r != 0x01; tries++)
    r = cmd(0, 0, 0x95);                // GO_IDLE_STATE
  if (r != 0x01) {
    p.failedAt = "CMD0 -- no answer from the card at all";
    sel(false);
    bus.endTransaction();
    return p;
  }
  p.responded = true;

  // CMD8 says "I am a version 2 host, here is a pattern, echo it". A version 1
  // card rejects it; anything modern echoes it back.
  r = cmd(8, 0x000001AA, 0x87);
  if (!(r & 0x04)) {                    // not "illegal command"
    uint8_t e[4];
    for (int i = 0; i < 4; i++) e[i] = xfer(0xFF);
    p.v2 = (e[2] == 0x01 && e[3] == 0xAA);
  }

  // ACMD41 with the high-capacity bit set. The card stays busy for a while
  // during its internal power-up; a second is generous.
  uint32_t t0 = millis();
  do {
    r = acmd(41, p.v2 ? 0x40000000UL : 0);
  } while (r != 0 && millis() - t0 < 1500);
  if (r != 0) {
    p.failedAt = "ACMD41 -- the card answered but never finished starting up";
    sel(false);
    bus.endTransaction();
    return p;
  }
  p.initialised = true;

  // CMD58 reads the OCR. Bit 30 is CCS: set means SDHC or SDXC, which address
  // by block rather than by byte. Every card over 2 GB sets it.
  if (cmd(58, 0, 0x01) == 0) {
    uint8_t o[4];
    for (int i = 0; i < 4; i++) o[i] = xfer(0xFF);
    p.blockAddr = (o[0] & 0x40) != 0;
  }

  bus.endTransaction();
  bus.beginTransaction(SPISettings(READ_HZ, MSBFIRST, SPI_MODE0));

  // CMD9 reads the CSD, which carries the capacity. Version 2 CSDs store it as
  // a simple block count; version 1 uses the older shift-based encoding.
  if (cmd(9, 0, 0x01) == 0) {
    while (xfer(0xFF) != 0xFE) {}
    uint8_t csd[16];
    for (int i = 0; i < 16; i++) csd[i] = xfer(0xFF);
    xfer(0xFF); xfer(0xFF);             // discard the CRC
    if ((csd[0] >> 6) == 1) {
      uint32_t csize = ((uint32_t)(csd[7] & 0x3F) << 16) | (csd[8] << 8) | csd[9];
      p.bytes = (uint64_t)(csize + 1) * 512ULL * 1024ULL;
    } else {
      uint32_t csize = ((uint32_t)(csd[6] & 0x03) << 10) | (csd[7] << 2) | (csd[8] >> 6);
      uint8_t  mult  = ((csd[9] & 0x03) << 1) | (csd[10] >> 7);
      uint8_t  rdlen = csd[5] & 0x0F;
      p.bytes = (uint64_t)(csize + 1) * (1UL << (mult + 2)) * (1UL << rdlen);
    }
  }

  // Block zero. On a card straight from a factory this is a master boot record;
  // the partition type byte in it says what the filesystem claims to be, and
  // that is the whole point of reading it.
  if (cmd(17, 0, 0x01) == 0) {
    uint32_t t = millis();
    uint8_t tok = 0xFF;
    while (millis() - t < 200 && (tok = xfer(0xFF)) != 0xFE) {}
    if (tok == 0xFE) {
      uint8_t b[512];
      for (int i = 0; i < 512; i++) b[i] = xfer(0xFF);
      xfer(0xFF); xfer(0xFF);

      bool sig = (b[510] == 0x55 && b[511] == 0xAA);
      // A volume boot record names its filesystem in plain text; an MBR does
      // not, but its first partition entry carries a type byte.
      if (sig && !memcmp(b + 3, "EXFAT   ", 8)) {
        strcpy(p.fs, "exFAT");
      } else if (sig && !memcmp(b + 82, "FAT32   ", 8)) {
        strcpy(p.fs, "FAT32");
      } else if (sig && !memcmp(b + 54, "FAT1", 4)) {
        strcpy(p.fs, "FAT16");
      } else if (sig) {
        p.partType = b[446 + 4];
        switch (p.partType) {
          case 0x0B: case 0x0C: strcpy(p.fs, "FAT32"); break;
          case 0x04: case 0x06: case 0x0E: strcpy(p.fs, "FAT16"); break;
          case 0x07:            strcpy(p.fs, "exFAT"); break;   // or NTFS
          case 0x00:            strcpy(p.fs, "unformatted"); break;
          default:              strcpy(p.fs, "not FAT"); break;
        }
      }
    } else {
      p.failedAt = "CMD17 -- the card started but would not hand over block 0";
    }
  }

  sel(false);
  bus.endTransaction();
  return p;
}

String sdProbeSummary(const SdProbe &p, bool mounted) {
  if (!p.responded)
    return String("no card responding on the SD pins -- ") +
           "check the wiring (MISO and MOSI are easy to swap), that VCC suits "
           "the module, and that the card is seated";

  String kind = p.blockAddr ? (p.bytes > 32ULL * 1024 * 1024 * 1024 ? "SDXC" : "SDHC")
                            : "SD";
  String s = kind + " card, " +
             String((double)p.bytes / (1024.0 * 1024.0 * 1024.0), 1) + " GB, " +
             String(p.fs);

  if (mounted) return s + " -- mounted";

  if (!strcmp(p.fs, "exFAT"))
    return s + " -- WIRING IS FINE, the filesystem is the problem. exFAT is not "
               "supported here; reformat the card as FAT32.";
  if (!p.initialised)
    return s + " -- the card answers but did not finish initialising";
  return s + " -- wiring is fine; the filesystem could not be mounted";
}

// --- working out which wire ------------------------------------------------------
//
// The probe above answers "is there a card". When the answer is no, this answers
// "why not", which is the question actually worth asking with a fresh set of
// jumper wires in front of you.

static bool probeWith(SPIClass &bus, int sck, int miso, int mosi, int cs,
                      uint32_t hz, SdProbe &out) {
  bus.end();
  bus.begin(sck, miso, mosi, cs);
  out = sdProbe(bus, cs);
  return out.responded;
}

SdDiagnosis sdDiagnose(SPIClass &bus, int sck, int miso, int mosi, int cs) {
  SdDiagnosis d;

  // Is anything holding MISO up? A powered module pulls it high when it is not
  // driving. A flat line means the module has no power, or MISO is not landing
  // where it is supposed to -- either way, no amount of retrying will help.
  pinMode(miso, INPUT);
  delayMicroseconds(200);
  d.misoHigh = digitalRead(miso);

  if (probeWith(bus, sck, miso, mosi, cs, 400000, d.probe)) return d;

  // Swapped. The single most common way to wire this wrong, because the labels
  // belong to the module and not to the host: the module's "MISO" or "DO" is an
  // output, so it goes to the ESP's input, and a pin-name-to-pin-name wiring
  // gets it backwards.
  if (probeWith(bus, sck, mosi, miso, cs, 400000, d.probe)) {
    d.swapped = true;
    d.verdict = "MISO and MOSI are swapped -- exchange those two wires";
    bus.end();
    bus.begin(sck, miso, mosi, cs);
    return d;
  }

  // Long unshielded jumpers to a card module are a surprisingly effective
  // low-pass filter. If it answers at a crawl, the wiring is right and the wires
  // are the problem.
  if (probeWith(bus, sck, miso, mosi, cs, 100000, d.probe)) {
    d.slowOnly = true;
    d.verdict  = "only answers at 100 kHz -- the wires are too long or too "
                 "noisy; shorten them, and keep the ground return next to them";
    return d;
  }

  bus.end();
  bus.begin(sck, miso, mosi, cs);
  d.verdict = d.misoHigh
      ? "the module has power (MISO idles high) but the card never answers -- "
        "most likely CS or SCK is not landing, or a solder joint is cold"
      : "MISO sits low, which means the module is not powered or MISO is not "
        "connected -- check VCC first: a module with a regulator and a level "
        "shifter on it needs 5 V, not 3.3 V";
  return d;
}

// --- the wires themselves ----------------------------------------------------------

// Five milliseconds, not microseconds.
//
// The first version of this used 500 us in one place and 400 us in another, and
// the two disagreed about the same pin in the same boot. That was not noise: the
// internal pull-up is about 45 kohm, and against the capacitance of a jumper
// lead and an unpowered chip's input the two settle times sat on either side of
// the RC. An unpowered module reads as "nothing attached" or "held low"
// depending purely on how long you waited, which is worse than no test at all.
//
// 5 ms is thousands of time constants. Whatever it says now is the wire.
static const int SETTLE_MS = 5;

static const char *pinState(int pin) {
  pinMode(pin, INPUT_PULLUP);
  delay(SETTLE_MS);
  bool up = digitalRead(pin);
  pinMode(pin, INPUT_PULLDOWN);
  delay(SETTLE_MS);
  bool down = digitalRead(pin);
  pinMode(pin, INPUT);

  if (up && !down) return "follows the pull - nothing is driving this pin";
  if (!up && !down) return "HELD LOW  - shorted to ground, or driven low";
  if (up && down)   return "held high - something is pulling this up";
  return "odd       - follows the pull backwards, which should be impossible";
}

void sdPinReport(int sck, int miso, int mosi, int cs) {
  struct { const char *name; int pin; } pins[] = {
    {"SCK ", sck}, {"MISO", miso}, {"MOSI", mosi}, {"CS  ", cs},
  };
  Serial.println("    wire      GPIO  state");
  for (auto &e : pins)
    Serial.println("    " + String(e.name) + "      " +
                   (e.pin < 10 ? " " : "") + String(e.pin) + "   " + pinState(e.pin));
  Serial.println("    (a powered module holds MISO and CS high; all four "
                 "floating means no power)");
}

// --- where did the wires actually go? ----------------------------------------------

String sdScanPins() {
  // Left out deliberately: 0, 3, 45, 46 are strapping pins and reading them with
  // a pull changes how the chip boots; 19 and 20 are the USB data lines; 26-37
  // belong to the on-board flash and PSRAM; 43 and 44 are this serial port, and
  // pulling on those would cut off the very message being printed.
  static const int SAFE[] = {1, 2, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
                             16, 17, 18, 21, 38, 39, 40, 41, 42, 47, 48};
  String out = "    what is attached to each pin, measured before anything "
               "else touched them:" + String(char(10));
  bool any = false;
  for (int pin : SAFE) {
    // Hand the pin back to plain GPIO first: on this chip a pin that a
    // peripheral has claimed ignores pinMode's pull settings entirely, and
    // reads back whatever that peripheral is driving.
    gpio_reset_pin((gpio_num_t)pin);
    pinMode(pin, INPUT_PULLUP);
    delay(SETTLE_MS);
    bool up = digitalRead(pin);
    pinMode(pin, INPUT_PULLDOWN);
    delay(SETTLE_MS);
    bool down = digitalRead(pin);
    pinMode(pin, INPUT);
    if (up && !down) continue;                 // floating: nothing there
    any = true;
    const char *what = (up && down) ? "held HIGH" : (!up && !down) ? "held LOW "
                                                                   : "odd";
    const char *known = pin == 10 ? "  (FPGA cs_n)"
                      : pin == 11 ? "  (FPGA mosi)"
                      : pin == 12 ? "  (FPGA sclk)"
                      : pin == 13 ? "  (FPGA miso)"
                      : pin == 14 ? "  (PROGRAM_B)"
                                  : "";
    out += "      GPIO" + String(pin) + (pin < 10 ? " " : "") +
           "  " + what + known + char(10);
  }
  if (!any) out += "      nothing attached to any of them" + String(char(10));
  return out;
}

// --- is the module there but unpowered? ---------------------------------------------

bool sdRailFloating(int driven, int a, int b, int c) {
  const int others[3] = {a, b, c};

  // Hold the others DOWN, so that anything they do is against the pull, not
  // with it. Only then does following the driven pin mean something.
  for (int p : others) pinMode(p, INPUT_PULLDOWN);

  pinMode(driven, OUTPUT);
  digitalWrite(driven, LOW);
  delay(SETTLE_MS * 4);
  int lowCount = 0;
  for (int p : others) lowCount += (digitalRead(p) == LOW);

  digitalWrite(driven, HIGH);
  delay(SETTLE_MS * 4);
  int highCount = 0;
  for (int p : others) highCount += (digitalRead(p) == HIGH);

  digitalWrite(driven, LOW);
  pinMode(driven, INPUT);
  for (int p : others) pinMode(p, INPUT);

  // Every one of them had to sit low when the driven pin was low AND be dragged
  // high when it went high. Anything less is coincidence.
  bool coupled = (lowCount == 3 && highCount == 3);
  Serial.println(String("    coupling test: driving GPIO") + driven +
                 " high pulled " + highCount + " of 3 other pins up" +
                 (coupled ? "  -> THEY ARE ALL TIED TOGETHER" : "  -> independent"));
  return coupled;
}
