// linktest - four wires, one question: is the board listening?
//
// Deliberately not the real firmware. This talks to nothing but the FPGA, needs
// no SD card and no Wi-Fi, and tests exactly one thing -- so when it fails, the
// list of things that could be wrong is four wires long.
//
// The board answers every frame with a fixed signature byte BEFORE it has been
// told what is wanted. That is the whole trick: a reply of 0xA5 proves the clock
// arrives, chip select frames the transfer, and MISO gets back -- without the
// board having to understand anything or MOSI having to be right.
//
// It runs the same transaction twice, once through the SPI peripheral and once
// by hand. That is not belt and braces: the FPGA has been watched with a logic
// analyser driving a correct reply while the peripheral read zeros, so the two
// results together say whether the fault is in the wires or in how this chip's
// SPI block is set up. They cannot both be true.
//
//   ESP32-S3        FPGA          header U2 pin
//   GPIO12    ->    esp_sclk      7
//   GPIO11    ->    esp_mosi      8
//   GPIO13    <-    esp_miso      9
//   GPIO10    ->    esp_cs_n      10
//   3V3, GND  <->                 3, 61      NOT 63/64 -- those are VIN

#include <SPI.h>

static const int PIN_SCK = 12, PIN_MOSI = 11, PIN_MISO = 13, PIN_CS = 10;

static const uint8_t CMD_PING = 0x01;
static const uint8_t SIGNATURE = 0xA5;

SPIClass fpga(FSPI);

static void report(const char *how, const uint8_t *rx) {
  Serial.printf("  %-10s -> %02X %02X %02X %02X %02X   ",
                how, rx[0], rx[1], rx[2], rx[3], rx[4]);
  if (rx[0] == SIGNATURE)
    Serial.printf("OK  version %u, core %u, busy %u\n", rx[1], rx[2], rx[3] & 1);
  else if (rx[0] == 0xFF)
    Serial.println("all ones - nothing is driving MISO at this end");
  else if (rx[0] == 0x00)
    Serial.println("all zeros - MISO is being read as low");
  else
    Serial.println("something, but not the signature");
}

// --- by hand ------------------------------------------------------------------
// Mode 0 spelled out: the master puts a bit on MOSI while the clock is low, both
// ends sample on the rising edge, and the slave changes MISO on the falling one.
// Slow on purpose -- about 100 kHz -- because nothing here is in a hurry and a
// slow clock removes every timing question at once.
static uint8_t bang_byte(uint8_t out) {
  uint8_t in = 0;
  for (int i = 7; i >= 0; i--) {
    digitalWrite(PIN_MOSI, (out >> i) & 1);
    delayMicroseconds(5);
    digitalWrite(PIN_SCK, HIGH);
    in = (in << 1) | (digitalRead(PIN_MISO) & 1);
    delayMicroseconds(5);
    digitalWrite(PIN_SCK, LOW);
  }
  return in;
}

static void bang_ping(uint8_t *rx) {
  pinMode(PIN_SCK, OUTPUT);
  pinMode(PIN_MOSI, OUTPUT);
  pinMode(PIN_CS, OUTPUT);
  pinMode(PIN_MISO, INPUT);

  digitalWrite(PIN_SCK, LOW);
  digitalWrite(PIN_CS, LOW);
  delayMicroseconds(10);
  rx[0] = bang_byte(CMD_PING);
  for (int i = 1; i < 5; i++) rx[i] = bang_byte(0x00);
  delayMicroseconds(10);
  digitalWrite(PIN_CS, HIGH);
}

// --- through the peripheral -----------------------------------------------------
static void spi_ping(uint32_t hz, uint8_t *rx) {
  fpga.begin(PIN_SCK, PIN_MISO, PIN_MOSI, PIN_CS);
  pinMode(PIN_CS, OUTPUT);
  digitalWrite(PIN_CS, HIGH);

  fpga.beginTransaction(SPISettings(hz, MSBFIRST, SPI_MODE0));
  digitalWrite(PIN_CS, LOW);
  delayMicroseconds(2);
  rx[0] = fpga.transfer(CMD_PING);
  for (int i = 1; i < 5; i++) rx[i] = fpga.transfer(0x00);
  delayMicroseconds(2);
  digitalWrite(PIN_CS, HIGH);
  fpga.endTransaction();
  fpga.end();
}

void setup() {
  Serial.begin(115200);
  delay(400);
  Serial.println();
  Serial.println("linktest: ESP32-S3 -> FPGA shell");
  Serial.printf("SCK=%d MOSI=%d MISO=%d CS=%d\n", PIN_SCK, PIN_MOSI, PIN_MISO, PIN_CS);
}

void loop() {
  uint8_t rx[5];

  Serial.println("ping:");

  // By hand first. If this works and the peripheral does not, the wires are
  // right and the peripheral is set up wrong.
  bang_ping(rx);
  report("bit-banged", rx);

  // Is that wire actually connected?
  //
  // The FPGA drives esp_miso continuously -- it never lets go of it, even
  // between frames. So a pull-up inside this chip cannot win against it: if the
  // wire is connected, the level is whatever the FPGA says and the internal pull
  // changes nothing. If the wire is open, the pull decides and the reading
  // FOLLOWS it. That is the whole test, and it needs nobody to touch anything.
  pinMode(PIN_MISO, INPUT_PULLUP);
  delayMicroseconds(500);
  int up = digitalRead(PIN_MISO);
  pinMode(PIN_MISO, INPUT_PULLDOWN);
  delayMicroseconds(500);
  int down = digitalRead(PIN_MISO);
  pinMode(PIN_MISO, INPUT);

  Serial.printf("  MISO pullup=%d pulldown=%d -> %s\n", up, down,
                (up == 1 && down == 0)
                  ? "OPEN CIRCUIT - nothing is driving this pin"
                  : "connected, and driven by the FPGA");

  spi_ping(1000000, rx);   report("SPI 1MHz", rx);
  spi_ping(10000000, rx);  report("SPI 10MHz", rx);

  Serial.println();
  delay(2000);
}
