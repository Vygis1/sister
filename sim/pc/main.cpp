// sim/pc/main.cpp - pc_top under Verilator, the board around it played by C++:
//   DDR3      a port that takes a request at once and answers a read LAT clocks later, in order
//   the ESP32 the configuration (<image>.cfg), the BIOS and VGA BIOS through the fill, run, then
//             the disk: pc_disk's requests served from the image, as the firmware will
//   HDMI      640x480 timing at clk/2; every Nth frame saved as frames/NNNN.ppm
//
//   the CD     a cue sheet (the 6th argument): esp32/console/cdrom.h itself, on the host port
//
//   obj_dir/Vpc_top <image.img> <boot0.rom> <boot1.rom> [frames-to-run] [save-every] [disc.cue]
#include "Vpc_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <deque>
#include <string>
#include <vector>

#ifndef SIM_CLK_HZ                     // (the Makefile's CLK, VGA and CPU)
#define SIM_CLK_HZ 50000000
#endif
static Vpc_top *t;
static uint64_t cyc = 0;
static int LAT = 12, GAP = 1, SVC = 0, QD = 8, REFI = 390, RFC = 8;      // (SIM_DDR_LAT / SIM_DDR_GAP in the environment: the read latency, and clocks between answers)
static std::vector<uint8_t> ddr;
struct Rd { uint64_t due; uint32_t line; uint32_t data[4]; };
static std::deque<Rd> rdq;
static FILE *disk;
static int frames_run = 400, save_every = 10;

// --- the host's actions, a clock each (spaced as the link would) ------------------------------------
static void eval_edge();
static void host_wr(uint16_t off, uint32_t v) {
	t->h_we = 1; t->h_off = off; t->h_wdata = v; eval_edge(); t->h_we = 0;
	for (int i = 0; i < 4; i++) eval_edge();
}
static uint32_t host_rd(uint16_t off) {
	t->h_off = off; eval_edge(); eval_edge();
	return t->h_rdata;
}
static void fill_words(uint32_t base, const std::vector<uint8_t> &d) {
	host_wr(0x7010, base);
	for (size_t i = 0; i + 3 < d.size(); i += 4) {
		uint32_t w; memcpy(&w, &d[i], 4);
		t->fill_we = 1; t->fill_windex = i / 4; t->fill_wdata = w; eval_edge(); t->fill_we = 0;
		for (int k = 0; k < 7; k++) eval_edge();
	}
}
static std::vector<uint8_t> slurp(const char *p) {
	std::vector<uint8_t> v; FILE *f = fopen(p, "rb");
	if (!f) { fprintf(stderr, "cannot open %s\n", p); exit(1); }
	fseek(f, 0, SEEK_END); v.resize(ftell(f)); fseek(f, 0, SEEK_SET);
	if (fread(v.data(), 1, v.size(), f) != v.size()) exit(1);
	fclose(f); return v;
}

// --- HDMI ---------------------------------------------------------------------------------------
static int hx = 0, hy = 0, frame_no = 0, px_x = -1, px_y = -1;
static bool want_save = false;
static std::vector<uint8_t> img(640 * 480 * 3);
static void save_frame() {
	char fn[64]; snprintf(fn, sizeof fn, "frames/%04d.ppm", frame_no);
	FILE *f = fopen(fn, "wb"); if (!f) return;
	fprintf(f, "P6\n640 480\n255\n"); fwrite(img.data(), 1, img.size(), f); fclose(f);
	printf("%10llu: frame %d saved (VGA %u x %u, CS:IP %04x:%04x)\n", (unsigned long long)cyc, frame_no,
	       (unsigned)(host_rd(0x7014) & 0x7FF), (unsigned)((host_rd(0x7014) >> 16) & 0x3FF),
	       (unsigned)(host_rd(0x7018) >> 16), (unsigned)(host_rd(0x7018) & 0xFFFF));
#ifdef SIM_ZPERF
	// the z486 build's ZPERF counters (pc_top 0x7090-0x70CC), read as the host reads them
	printf("  ZPERF");
	for (int i = 0; i < 16; i++) printf(" %u", host_rd(0x7090 + 4 * i));
	printf("%c", 10);
#endif
	// what the BIOS wrote to its debug ports since the last frame (pc_top BIOSDBG: its panics)
	static uint32_t dbg_seen = 0;
	uint32_t n = host_rd(0x7058);
	if (n != dbg_seen) {
		std::string txt;
		for (uint32_t i = (n - dbg_seen > 1024 ? n - 1024 : dbg_seen); i < n; i++) {
			char c = (char)host_rd(0x9000 + 4 * (i % 1024));
			txt += (c == 10 || (c >= 32 && c < 127)) ? c : '.';
		}
		printf("  BIOS debug port: %s%c", txt.c_str(), 10);
		dbg_seen = n;
	}
	fflush(stdout);
}

// --- one clk cycle (and pclk at half of it) -----------------------------------------------------
static void eval_edge() {
	// DDR3: take what is asked, answer reads in order. SIM_DDR_SVC = 0 (the default): every request taken
	// at once and done at once, a read answered LAT clocks later. SIM_DDR_SVC = n: as ddr3_mem and the MIG --
	// a queue of SIM_DDR_QD requests (taken while there is room), one served every n clocks (a write's bytes
	// land, a read's line is read, then) and none while a refresh runs (SIM_DDR_RFC clocks every SIM_DDR_REFI);
	// a read's line LAT clocks after it is served; at most one answer every GAP clocks
	struct Cmd { bool we; uint32_t line; uint32_t wd[4]; uint16_t wm; };
	static std::deque<Cmd> cq;
	static uint64_t next_svc = 0;
	bool queued = SVC > 0;
	t->d_ready = t->d_req && (!queued || (int)cq.size() < QD);
	if (t->d_req && t->d_ready) {
		Cmd c; c.we = t->d_we; c.line = t->d_addr & 0xFFFFFF; c.wm = t->d_wmask;
		for (int w = 0; w < 4; w++) c.wd[w] = t->d_wdata[w];
		cq.push_back(c);
	}
	bool refresh = queued && REFI > 0 && (cyc % (uint64_t)REFI) < (uint64_t)RFC;
	while (!cq.empty() && (!queued || (cyc >= next_svc && !refresh))) {
		Cmd c = cq.front(); cq.pop_front();
		if (c.we) {
			for (int b = 0; b < 16; b++)
				if ((c.wm >> b) & 1) ddr[(size_t)c.line * 16 + b] = (uint8_t)(c.wd[b / 4] >> (8 * (b % 4)));
		} else {
			Rd r; r.due = cyc + LAT; r.line = c.line;
			for (int w = 0; w < 4; w++) memcpy(&r.data[w], &ddr[(size_t)c.line * 16 + 4 * w], 4);
			rdq.push_back(r);
		}
		if (queued) { next_svc = cyc + SVC; break; }
	}
	t->d_valid = 0;
	static uint64_t last_ans = 0;
	if (!rdq.empty() && rdq.front().due <= cyc && cyc - last_ans >= (uint64_t)GAP) {
		last_ans = cyc;
		for (int w = 0; w < 4; w++) t->d_rdata[w] = rdq.front().data[w];
		rdq.pop_front();
		t->d_valid = 1;
	}
	// pclk: rises on every other clk
	bool prise = (cyc & 1) == 0;
	if (prise) {
		// the colour for the request a pclk ago
		if (px_x >= 0 && px_x < 640 && px_y >= 0 && px_y < 480) {
			uint32_t c = t->vid_rgb; uint8_t *p = &img[(px_y * 640 + px_x) * 3];
			p[0] = c >> 16; p[1] = c >> 8; p[2] = c;
		}
		px_x = hx; px_y = hy;
		t->vid_x = hx; t->vid_y = hy; t->vid_req = (hx < 640 && hy < 480);
		if (++hx == 800) { hx = 0; if (++hy == 525) { hy = 0; frame_no++; if (frame_no % save_every == 0) want_save = true; } }
		t->pclk = 1;
	}
	t->clk = 1; t->eval();
	t->clk = 0; if (prise) t->pclk = 0; t->eval();
	cyc++;
}

// --- the CD drive: the firmware's own code (esp32/console/cdrom.h) on the host port ---------------------
#include <cstdarg>
struct CdFile {
	FILE *f = nullptr;
	bool open(const char *p) { f = fopen(p, "rb"); return f != nullptr; }
	bool seek(uint64_t pos) { return f && fseeko(f, (off_t)pos, SEEK_SET) == 0; }
	int read(uint8_t *d, int n) { return f ? (int)fread(d, 1, n, f) : -1; }
	uint64_t size() { if (!f) return 0; off_t c = ftello(f); fseeko(f, 0, SEEK_END); off_t s = ftello(f); fseeko(f, c, SEEK_SET); return s; }
	void close() { if (f) fclose(f); f = nullptr; }
};
static uint16_t cd_reg_rd(int r) { return (uint16_t)host_rd(0xA000 + 4 * r); }
static void cd_reg_wr(int r, uint16_t v) { host_wr(0xA000 + 4 * r, v); }
static void cd_buf_wr(const void *d, uint32_t n) {
	const uint8_t *b = (const uint8_t *)d;
	for (uint32_t i = 0; i < (n + 3) / 4; i++) { uint32_t w = 0; memcpy(&w, b + 4 * i, (n - 4 * i >= 4) ? 4 : n - 4 * i); host_wr(0xC000 + 4 * i, w); }
}
static void cd_buf_rd(void *d, uint32_t n) {
	uint8_t *b = (uint8_t *)d;
	for (uint32_t i = 0; i < (n + 3) / 4; i++) { uint32_t w = host_rd(0xC000 + 4 * i); memcpy(b + 4 * i, &w, (n - 4 * i >= 4) ? 4 : n - 4 * i); }
}
static void cd_audio_wr(const uint32_t *s, int n) { for (int i = 0; i < n; i++) host_wr(0xB000, s[i]); }
static void cd_log(const char *fmt, ...) {
	va_list a; va_start(a, fmt); printf("%10llu: ", (unsigned long long)cyc); vprintf(fmt, a); va_end(a); fflush(stdout);
}
#define CD_TRACE 1
#include "../../esp32/console/cdrom.h"

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	if (argc < 4) { fprintf(stderr, "usage: Vpc_top image.img boot0.rom boot1.rom [frames] [save-every]\n"); return 1; }
	if (argc > 4) frames_run = atoi(argv[4]);
	if (argc > 5) save_every = atoi(argv[5]);
	ddr.assign((size_t)256 << 20, 0);
	if (getenv("SIM_DDR_LAT")) LAT = atoi(getenv("SIM_DDR_LAT"));
	if (getenv("SIM_DDR_GAP")) GAP = atoi(getenv("SIM_DDR_GAP"));
	if (getenv("SIM_DDR_SVC")) SVC = atoi(getenv("SIM_DDR_SVC"));
	if (getenv("SIM_DDR_QD")) QD = atoi(getenv("SIM_DDR_QD"));
	if (getenv("SIM_DDR_REFI")) REFI = atoi(getenv("SIM_DDR_REFI"));
	if (getenv("SIM_DDR_RFC")) RFC = atoi(getenv("SIM_DDR_RFC"));
	t = new Vpc_top;
	disk = fopen(argv[1], "r+b");
	if (!disk) { fprintf(stderr, "cannot open %s\n", argv[1]); return 1; }
	std::string cfgp = std::string(argv[1]); cfgp = cfgp.substr(0, cfgp.rfind('.')) + ".cfg";
	std::vector<uint8_t> cfg = slurp(cfgp.c_str()), b0 = slurp(argv[2]), b1 = slurp(argv[3]);

	t->rst = 1; for (int i = 0; i < 32; i++) eval_edge(); t->rst = 0;
	for (int i = 0; i < 100; i++) eval_edge();
	int n = 0;
	for (size_t i = 0; i + 7 < cfg.size(); i += 8) {
		uint32_t a, d; memcpy(&a, &cfg[i], 4); memcpy(&d, &cfg[i + 4], 4);
		if (!a) break;
		host_wr(0x7008, a); host_wr(0x700C, d); n++;
	}
	printf("config: %d writes\n", n);
	fill_words(0xF0000, b0);
	fill_words(0xC0000, b1);
	printf("%10llu: BIOS %zu + VGA BIOS %zu bytes in; run\n", (unsigned long long)cyc, b0.size(), b1.size());
	if (argc > 6) {
		std::vector<uint8_t> cue = slurp(argv[6]); cue.push_back(0);
		cdrom::insert(argv[6], (char *)cue.data());
	}
	host_wr(0x7000, 1);

	uint64_t last_poll = 0, sectors = 0;
	// PC_RESET_AT=<frame> (the environment): at that frame the host stops the CPU and starts it again -- a
	// warm reset as the CPU and pc_z486_cdc see it, in the middle of whatever it was doing; WRESETS and
	// WRST_AT (z486 build) are printed beside the CS:IP the host read just before
	int reset_at = getenv("PC_RESET_AT") ? atoi(getenv("PC_RESET_AT")) : -1;
	while (frame_no < frames_run) {
		eval_edge();
		if (want_save) { want_save = false; save_frame(); }
		if (frame_no == reset_at) {
			reset_at = -1;
			uint32_t was = host_rd(0x7018);
			host_wr(0x7000, 0); for (int i = 0; i < 200; i++) eval_edge(); host_wr(0x7000, 1);
			printf("%10llu: CPU reset by the host; CS:IP %04x:%04x before it -- WRESETS %08x WRST_AT %08x EIP %08x%c",
			       (unsigned long long)cyc, was >> 16, was & 0xFFFF, host_rd(0x7074), host_rd(0x7078), host_rd(0x707C), 10);
			fflush(stdout);
		}
		if (cyc - last_poll < 2000) continue;
		last_poll = cyc;
		uint32_t req = host_rd(0x7020);
		int cdr = (req >> 24) & 7;
		if (cdr || cdrom::busy()) cdrom::io(cdr);
		if (((req >> 27) & 1) && cdrom::wantAudio()) cdrom::audio();
		if (!(req >> 31)) continue;
		uint32_t lba = host_rd(0x7024), cnt = (req >> 16) & 15;
		bool wr = (req >> 30) & 1;
		static uint8_t sec[8 * 512];
		if (!wr) {
			cnt = 8;                                   // (read ahead: eight, whatever was asked -- pc.h)
			fseek(disk, (long)lba * 512, SEEK_SET);
			size_t got = fread(sec, 1, cnt * 512, disk);
			if (got < cnt * 512) memset(sec + got, 0, cnt * 512 - got);
			for (uint32_t i = 0; i < cnt * 128; i++) { uint32_t w; memcpy(&w, &sec[i * 4], 4); host_wr(0x8000 + i * 4, w); }
		} else {
			for (uint32_t i = 0; i < cnt * 128; i++) { uint32_t w = host_rd(0x8000 + i * 4); memcpy(&sec[i * 4], &w, 4); }
			fseek(disk, (long)lba * 512, SEEK_SET); fwrite(sec, 1, cnt * 512, disk); fflush(disk);
			printf("%10llu: disk write, %u sectors at %u\n", (unsigned long long)cyc, cnt, lba);
		}
		host_wr(0x7028, wr ? 1 : cnt);
		sectors += cnt;
		if ((sectors & 0x3FF) < cnt) { printf("%10llu: %llu sectors read so far\n", (unsigned long long)cyc, (unsigned long long)sectors); fflush(stdout); }
	}
	fclose(disk);
	delete t;
	return 0;
}
