// --- the screen: 40 x 30 cells ----------------------------------------------------
// osd.v draws them: a cell is [6:0] the character, [8] the selection bar behind it,
// [10:9] the colour, [11] the header's / footer's lighter background. The font's
// codes 0x01-0x07 are a frame's corners and lines and a block, 0x0F a diamond.
static const int COLS = 40, ROWS = 30;
static uint32_t *cells = (uint32_t *)calloc(COLS * ROWS, 4);   // (heap: static RAM is short beside Bluetooth)
enum { WHITE = 0, YELLOW = 1, GREY = 2, GREEN = 3 };
enum : char { G_TL = 0x01, G_TR = 0x02, G_BL = 0x03, G_BR = 0x04, G_HL = 0x05, G_VL = 0x06, G_BLOCK = 0x07, G_DIAMOND = 0x0F,
              G_CURSOR = 0x10, G_UP = 0x1E, G_DOWN = 0x1F };
static bool barRow[ROWS];

static bool drawable(char c) { return (uint8_t)c >= 0x20 || (c >= G_TL && c <= G_BLOCK) || c == G_DIAMOND || c == G_CURSOR || c == G_UP || c == G_DOWN; }
static void put(int col, int row, const String &s, int colour = WHITE, bool hl = false, int width = -1) {
  if (row < 0 || row >= ROWS) return;
  int n = width < 0 ? s.length() : width;
  for (int i = 0; i < n && col + i < COLS; i++) {
    if (col + i < 0) continue;
    char ch = i < (int)s.length() ? s[i] : ' ';
    if (!drawable(ch)) ch = ' ';
    if ((uint8_t)ch > 0x7E) ch = '?';
    cells[row * COLS + col + i] = (uint8_t)ch | (hl ? 0x100 : 0) | (colour << 9) | (barRow[row] ? 0x800 : 0);
  }
}
static void putc_(int col, int row, char c, int colour = WHITE, bool hl = false) { put(col, row, String(c), colour, hl); }
static void centre(int row, const String &s, int colour = WHITE) { put((COLS - (int)s.length()) / 2, row, s, colour); }
static void right(int endCol, int row, const String &s, int colour = WHITE, bool hl = false) { put(endCol - (int)s.length() + 1, row, s, colour, hl); }
// a name cut to fit, with an ellipsis
static String fit(const String &s, int w) { return (int)s.length() <= w ? s : s.substring(0, w - 3) + "..."; }
// a game's name as shown: without the dump's tags -- "(USA, Europe)", "[!]", "(Rev-A)"
static String shown(const String &n) {
  int cut = -1;
  for (int i = 1; i < (int)n.length(); i++)
    if ((n[i] == '(' || n[i] == '[') && n[i - 1] == ' ') { cut = i - 1; break; }
  return cut > 0 ? n.substring(0, cut) : n;
}

// an empty screen: the header bar (rows 0-2) and the footer bar (27-29) lighter
static void clear() {
  for (int r = 0; r < ROWS; r++) barRow[r] = r <= 2 || r >= 27;
  for (int r = 0; r < ROWS; r++) for (int c = 0; c < COLS; c++) cells[r * COLS + c] = ' ' | (barRow[r] ? 0x800 : 0);
}
// a frame from (c0, r0) to (c1, r1), a title set into its top edge
static void frame(int c0, int r0, int c1, int r1, const String &title = "") {
  putc_(c0, r0, G_TL, GREY); putc_(c1, r0, G_TR, GREY); putc_(c0, r1, G_BL, GREY); putc_(c1, r1, G_BR, GREY);
  for (int c = c0 + 1; c < c1; c++) { putc_(c, r0, G_HL, GREY); putc_(c, r1, G_HL, GREY); }
  for (int r = r0 + 1; r < r1; r++) { putc_(c0, r, G_VL, GREY); putc_(c1, r, G_VL, GREY); }
  if (title.length()) put(c0 + 2, r0, " " + title + " ", WHITE);
}
// the header: the name, and what the board is now
static void header(const String &what) {
  putc_(2, 1, G_DIAMOND, YELLOW);
  put(4, 1, "FPGA CONSOLE", YELLOW);
  right(COLS - 3, 1, what, GREY);
}
static void footer(const String &hints) { centre(28, hints, GREY); }
static void show() { fpga.busWrite(OSD_CELLS, cells, COLS * ROWS); }
static void osd(uint32_t ctrl) { fpga.busWrite(OSD_CTRL, ctrl); }

// A message in a box (loading, switching, an error).
static void message(const String &a, const String &b = "", int colour = WHITE) {
  clear();
  header("");
  frame(2, 10, 37, 18);
  centre(13, fit(a, 32), colour);
  if (b.length()) centre(15, fit(b, 32), GREY);
  show(); osd(1);
}


static int level = 0;                       // 0 the consoles, 1 a console's games
static int cur = 0;                         // the console whose games are shown
static int sel = 0, top = 0, consSel = 0;
static bool (*menuButton)() = nullptr;      // a Bluetooth pad's PS / Home button (pads.h sets it)
static bool open_ = false, gameIn = false;
static String note;                         // one line under the list: what just happened
static const int LIST_TOP = 5, LIST_ROWS = 20;   // inside the frame (rows 4-25)

static int count() { return level == 0 ? (int)consoles.size() : (int)lists[cur].size(); }
// how many fit (a row free under the frame's title and above its bottom)
static int pageRows() { return level == 0 ? (LIST_ROWS - 2) / 2 + 1 : LIST_ROWS - 2; }

static void draw() {
  clear();
  Status st = fpga.status();
  int cm = machineOfCore(st.core);
  header(cm >= 0 ? String(MACHINES[cm].name) : String(""));
  int n = count();
  if (level == 0) frame(1, 4, 38, 25, "CONSOLES");
  else frame(1, 4, 38, 25, String(MACHINES[cur].name) + "  " + n + (n == 1 ? " game" : " games"));
  if (level == 0 && consoles.empty()) {
    centre(13, haveCard ? "no games on the card" : "no SD card", YELLOW);
    centre(15, "roms/nes  sms  md  n64   discs", GREY);
  }
  // (the consoles a line apart -- there are few -- the games one under another)
  int step = level == 0 ? 2 : 1, rows = pageRows();
  if (sel < top) top = sel;
  if (sel >= top + rows) top = sel - rows + 1;
  for (int r = 0; r < rows && top + r < n; r++) {
    int i = top + r, row = LIST_TOP + 1 + r * step;
    bool here = i == sel;
    put(2, row, "", WHITE, here, 36);                                  // the bar, frame to frame
    if (here) putc_(3, row, G_CURSOR, YELLOW, true);
    if (level == 0) {
      int m = consoles[i];
      put(5, row, MACHINES[m].name, m == cm ? GREEN : WHITE, here);
      right(36, row, String(lists[m].size()) + (lists[m].size() == 1 ? " game" : " games"), GREY, here);
    } else {
      put(5, row, fit(shown(lists[cur][i].name), 31), WHITE, here);
    }
  }
  if (top > 0) putc_(38, LIST_TOP + 1, G_UP, YELLOW);
  if (top + rows < n) putc_(38, LIST_TOP + LIST_ROWS - 2, G_DOWN, YELLOW);
  if (level == 1 && n > rows) right(36, 25, " " + String(sel + 1) + "/" + n + " ", GREY);
  put(2, 26, fit(note, 36), YELLOW);
  footer(level == 0 ? (gameIn ? "A open    B back to the game" : "A open")
                    : "A play     B back     L/R page");
  show();
}

