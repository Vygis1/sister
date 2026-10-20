// shim: what gfx.h takes from the Arduino core, for tools/menu/gfx_preview.cpp on the PC
#pragma once
#include <cstdint>
#include <cstring>
#include <cmath>
#include <cstdlib>
#include <cstdio>
#include <algorithm>
#include <string>
using std::min; using std::max;
#include <chrono>
#include <thread>
static inline uint32_t millis() { using namespace std::chrono; return (uint32_t)duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count(); }
static inline void delay(uint32_t ms) { std::this_thread::sleep_for(std::chrono::milliseconds(ms)); }
