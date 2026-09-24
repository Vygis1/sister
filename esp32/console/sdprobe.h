// sdprobe.h - ask the card what it is, before asking the filesystem anything.
//
// SD.begin() answers one question with one bit, and two completely different
// faults produce that same bit: a card that is not wired up correctly, and a
// card that is wired perfectly and formatted in something this chip cannot read.
// The first is a soldering iron, the second is a reformat, and "no SD card" does
// not tell you which one you are holding.
//
// So this talks to the card directly first, in SPI mode, using the commands the
// card answers before any filesystem exists. If CMD0 comes back the wiring is
// good, whatever the filesystem turns out to be.

#pragma once
#include <Arduino.h>
#include <SPI.h>

struct SdProbe {
  bool     responded   = false;   // CMD0 answered: clock, CS, MOSI and MISO work
  bool     initialised = false;   // ACMD41 finished: the card is ready
  bool     v2          = false;   // answered CMD8, so SD version 2 or later
  bool     blockAddr   = false;   // SDHC/SDXC: addresses are blocks, not bytes
  uint64_t bytes       = 0;       // from the CSD
  char     fs[12]      = "unknown";
  uint8_t  partType    = 0;       // MBR partition type byte, 0 if no MBR
  const char *failedAt = nullptr; // the first step that did not work
};

// Probes the card on an already-begun SPI bus. Leaves the bus usable: the card
// is reset by CMD0, which is exactly what SD.begin() does first anyway.
SdProbe sdProbe(SPIClass &bus, int csPin);

// When the straightforward probe finds nothing, work out why rather than saying
// "check the wiring" and leaving it there.
//
// Re-probes with MISO and MOSI exchanged, and again at a crawl. Both are one
// line on this chip because the S3 routes SPI through a GPIO matrix, so the
// pins are a software choice -- and between them they separate the three things
// that actually go wrong: the two data wires swapped (the labels are from the
// MODULE's point of view and half of them say DO/DI instead), wires too long or
// too capacitive for the clock, and nothing powered at all.
struct SdDiagnosis {
  SdProbe     probe;
  bool        swapped   = false;   // it works with MISO and MOSI exchanged
  bool        slowOnly  = false;   // it works, but only at a crawl
  bool        misoHigh  = false;   // something is holding MISO up, so it has power
  const char *verdict   = nullptr;
};

SdDiagnosis sdDiagnose(SPIClass &bus, int sck, int miso, int mosi, int cs);

// What each of the four wires looks like electrically, before any protocol.
//
// The chip's own pull-up and pull-down settle a question nothing else can: a pin
// that follows the pull in both directions is connected to NOTHING, and a pin
// that refuses to follow is being held by something. "Not wired" and "wired to
// the wrong thing" look identical from a single read, and they are a different
// five minutes with the pliers.
//
// A powered card module holds MISO and CS up. All four floating means the module
// is not powered at all, whatever its VCC pin measures.
void sdPinReport(int sck, int miso, int mosi, int cs);

// Every pin that is safe to touch, and what is on it.
//
// For when the wires are not where they were meant to go. A powered SD module
// holds MISO and CS up through the card's own pull-ups, so the module announces
// its own position: the pins that refuse an internal pull-down are where it is.
// Reads only -- nothing here ever drives a pin, so it cannot fight whatever is
// on the other end.
// Returns the report rather than printing it, because it has to run BEFORE
// anything else in setup() and is only worth showing when something is wrong.
//
// Running it first is not a detail. The earlier version ran it last and it
// disagreed with every other test on this page: by then SPI.begin() had claimed
// the pins through the GPIO matrix and the preceding tests had left their own
// pull settings on them, so it was faithfully reporting the state of the
// software, not the wiring.
String sdScanPins();

// Is there an UNPOWERED chip on the end of these wires?
//
// A chip with no supply is not an open circuit. Every input has protection
// diodes to its VCC rail, and when that rail is floating, pulling any one pin up
// drags the rail -- and therefore every other pin -- up with it. So driving one
// wire and watching the others separates the two cases that look alike:
//
//   others follow  -> the module IS wired to these pins and has NO POWER
//   others ignore  -> the pins really are unconnected
//
// This is what makes a missing VCC or ground diagnosable from software, instead
// of being the thing you conclude after trying everything else.
bool sdRailFloating(int driven, int a, int b, int c);

// One line for the serial log, and the same text the web page shows.
String sdProbeSummary(const SdProbe &p, bool mounted);
