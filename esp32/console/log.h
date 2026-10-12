// log.h - what the firmware says about itself over the serial port: OFF unless asked.
//
// Every "disc: ...", "menu: ...", "pads: ..." line went out on the UART as it happened, and
// Serial.print blocks once its small buffer is full -- time taken from loop(), which is the
// pads. The replies to serial COMMANDS (pc/pad.py's register reads, "state", "install") are
// not logging and still go through Serial; everything else goes through Log, which is quiet
// until "log on" is typed (not kept across a reset).
#pragma once
#include <Arduino.h>

struct ConsoleLog {
  bool on = false;
  template <class... A> void printf(const char *f, A... a) { if (on) Serial.printf(f, a...); }
  template <class T> void print(const T &v) { if (on) Serial.print(v); }
  template <class T> void println(const T &v) { if (on) Serial.println(v); }
  void println() { if (on) Serial.println(); }
};
extern ConsoleLog Log;
