// cdtest.cpp - esp32/console/cdrom.h on its own, on the PC: a cue sheet parsed, the track table and the
// TOC printed, sector 16 read (an ISO 9660 disc's volume descriptor: "CD001").
//   g++ -O2 -std=c++17 -o cdtest cdtest.cpp && ./cdtest <file.cue>
#include <cstdio>
#include <cstdarg>
#include <cstdint>
#include <vector>

struct CdFile {
	FILE *f = nullptr;
	bool open(const char *p) { f = fopen(p, "rb"); return f != nullptr; }
	bool seek(uint64_t pos) { return f && fseeko(f, (off_t)pos, SEEK_SET) == 0; }
	int read(uint8_t *d, int n) { return f ? (int)fread(d, 1, n, f) : -1; }
	uint64_t size() { if (!f) return 0; off_t c = ftello(f); fseeko(f, 0, SEEK_END); off_t s = ftello(f); fseeko(f, c, SEEK_SET); return s; }
	void close() { if (f) fclose(f); f = nullptr; }
};
static uint16_t regs[8];
static std::vector<uint8_t> cdbuf(16384);
static uint16_t cd_reg_rd(int r) { return regs[r]; }
static void cd_reg_wr(int r, uint16_t v) { regs[r] = v; }
static void cd_buf_wr(const void *d, uint32_t n) { memcpy(cdbuf.data(), d, n); }
static void cd_buf_rd(void *d, uint32_t n) { memcpy(d, cdbuf.data(), n); }
static void cd_audio_wr(const uint32_t *, int) {}
static void cd_log(const char *fmt, ...) { va_list a; va_start(a, fmt); vprintf(fmt, a); va_end(a); }
#include "../../esp32/console/cdrom.h"

int main(int argc, char **argv) {
	if (argc < 2) return 1;
	FILE *f = fopen(argv[1], "rb"); if (!f) return 1;
	static char text[65536]; size_t n = fread(text, 1, sizeof text - 1, f); text[n] = 0; fclose(f);
	if (!cdrom::insert(argv[1], text)) return 2;
	for (int i = 0; i < cdrom::trackCnt; i++) {
		auto &t = cdrom::track[i];
		printf("track %2d: start %6u length %6u skip %10u size %u attr %02X file %d\n", t.number, t.start, t.length, t.skip, t.sectorSize, t.attr, t.file);
	}
	uint8_t cmd[12] = { 0x43, 2, 0, 0, 0, 0, 0, 0x03, 0x24, 0, 0, 0 };   // READ TOC, MSF, room for all
	int len = cdrom::read_toc(cmd);
	printf("TOC %d bytes:", len);
	for (int i = 0; i < len; i++) printf("%s%02X", i % 8 == 4 ? "  " : " ", cdrom::buf[i]);
	printf("\n");
	bool i0; cdrom::Track *t = cdrom::track_from_lba(16, i0);
	cdrom::read_sectors(t, 16, 1);
	printf("sector 16: %02X '%.5s'\n", cdrom::buf[0], (const char *)cdrom::buf + 1);
	return (cdrom::buf[1] == 'C' && cdrom::buf[2] == 'D' && cdrom::buf[3] == '0') ? 0 : 3;
}
