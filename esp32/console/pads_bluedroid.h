// pads_bluedroid.h - Bluetooth pads on ESP-IDF's own Bluetooth stack, Bluedroid (Apache-2.0), in
// place of Bluepad32 on BTstack (BTstack is free for non-commercial use only). docs/BLUETOOTH.md
// has the why, the licences and what is still to be checked on a board.
//
// Two transports:
//
//   Classic (DualShock 4, DualSense, Switch Pro, Xbox on old firmware): our own small HID host on
//   Bluedroid's L2CAP, the way Bluedroid's hidh_conn.c does it. The stock arduino-esp32 build has
//   the HID host compiled out but L2CAP, the security manager and the BTA message system in, so
//   the PSMs 0x11 (control) and 0x13 (interrupt) are registered here, BTM_SetSecurityLevel makes
//   L2CAP do the pairing / authentication / encryption before it hands a channel over, and every
//   L2CAP call is made on Bluedroid's own BTU task: we register as BTA subsystem 23 (the HID
//   host's slot, free) and post to it.
//
//   BLE (Xbox Wireless Controller, firmware 5 and later): ESP-IDF's esp_hidh (HID over GATT).
//
// No SDP: a Classic pad is told apart by its first report (and its name). The Sony pads start
// with a short 0x01 report; a GET_REPORT of feature 0x05 turns them to 0x11 (DS4) or 0x31
// (DualSense). The Switch Pro starts in 0x3F mode; subcommands read its stick calibration and
// turn on 0x30 reports. Report layouts as documented by Linux hid-playstation / hid-nintendo,
// SDL's HIDAPI drivers and dekuNukem's Nintendo_Switch_Reverse_Engineering notes.
//
// Tasks: Bluedroid's BTU task runs the Classic channels (the l2_* callbacks and btuEvent); the BTC
// task runs the GAP callbacks; esp_hidh's own event task runs the BLE reports; our "padbt" task
// (core 0) finds pads (inquiry, BLE scan) and opens BLE ones (esp_hidh_dev_open blocks). What the
// rest of the firmware reads (Pad) is copied under mux.

#pragma once
#include <Arduino.h>
#include <esp_idf_version.h>
#include <esp_bt.h>
#include <esp_bt_main.h>
#include <esp_bt_device.h>
#include <esp_gap_bt_api.h>
#include <esp_gap_ble_api.h>
#include <esp_gattc_api.h>
#include <esp_hidh.h>
#include <esp_hidh_gattc.h>
#include <esp_hidh_bluedroid.h>
#include <esp_heap_caps.h>
#include <esp_timer.h>
#include "log.h"

#if !(ESP_IDF_VERSION_MAJOR == 5 && ESP_IDF_VERSION_MINOR == 5)
#error "pads_bluedroid.h re-declares Bluedroid internals as they are in ESP-IDF v5.5.5 (arduino-esp32 3.3.11); check them against this ESP-IDF first (docs/BLUETOOTH.md)"
#endif
#if !(CONFIG_BT_BLUEDROID_ENABLED && CONFIG_BT_CLASSIC_ENABLED && CONFIG_BT_BLE_ENABLED && CONFIG_GATTC_ENABLE)
#error "the Bluedroid pads need Bluedroid with Classic, BLE and the GATT client (stock arduino-esp32 3.3.x has them)"
#endif

// arduino-esp32 3.x frees the Bluetooth controller's memory at start-up unless one of these says
// Bluetooth is wanted (esp32-hal-misc.c); a library would set them, we are not one
extern "C" bool btClassicInUse(void) { return true; }
extern "C" bool bleInUse(void) { return true; }

// --- Bluedroid internals ---------------------------------------------------------------------
// Not in the arduino libraries' headers. Copied (declarations only) from ESP-IDF v5.5.5,
// components/bt/host/bluedroid: stack/include/stack/{l2c_api.h, bt_types.h, hcidefs.h, btm_api.h},
// bta/include/bta/bta_sys.h, common/osi/include/osi/allocator.h. Apache-2.0, Broadcom/Espressif.
namespace bd {
extern "C" {
typedef struct { uint16_t event, len, offset, layer_specific; /* data follows */ } BT_HDR;
typedef struct {
  uint8_t qos_flags, service_type;
  uint32_t token_rate, token_bucket_size, peak_bandwidth, latency, delay_variation;
} FLOW_SPEC;
typedef struct { uint8_t mode, tx_win_sz, max_transmit; uint16_t rtrans_tout, mon_tout, mps; } tL2CAP_FCR_OPTS;
typedef struct {
  uint8_t id, stype; uint16_t max_sdu_size; uint32_t sdu_inter_time, access_latency, flush_timeout;
} tHCI_EXT_FLOW_SPEC;
typedef struct {
  uint16_t result;
  bool mtu_present;            uint16_t mtu;
  bool qos_present;            FLOW_SPEC qos;
  bool flush_to_present;       uint16_t flush_to;
  bool fcr_present;            tL2CAP_FCR_OPTS fcr;
  bool fcs_present;            uint8_t fcs;
  bool ext_flow_spec_present;  tHCI_EXT_FLOW_SPEC ext_flow_spec;
  uint16_t flags;
} tL2CAP_CFG_INFO;
typedef struct {
  void (*connect_ind)(uint8_t *bda, uint16_t lcid, uint16_t psm, uint8_t id);
  void (*connect_cfm)(uint16_t lcid, uint16_t result);
  void (*connect_pnd)(uint16_t lcid);
  void (*config_ind)(uint16_t lcid, tL2CAP_CFG_INFO *cfg);
  void (*config_cfm)(uint16_t lcid, tL2CAP_CFG_INFO *cfg);
  void (*disconnect_ind)(uint16_t lcid, bool ack_needed);
  void (*disconnect_cfm)(uint16_t lcid, uint16_t result);
  void (*qos_violation_ind)(uint8_t *bda);
  void (*data_ind)(uint16_t lcid, BT_HDR *msg);
  void (*congestion_status)(uint16_t lcid, bool congested);
  void (*tx_complete)(uint16_t lcid, uint16_t sdu_count);
} tL2CAP_APPL_INFO;
typedef struct { bool (*evt_hdlr)(BT_HDR *msg); void (*disable)(void); } tBTA_SYS_REG;

uint16_t L2CA_Register(uint16_t psm, tL2CAP_APPL_INFO *p_cb_info);
uint16_t L2CA_ConnectReq(uint16_t psm, uint8_t *bda);
bool L2CA_ConnectRsp(uint8_t *bda, uint8_t id, uint16_t lcid, uint16_t result, uint16_t status);
bool L2CA_ConfigReq(uint16_t cid, tL2CAP_CFG_INFO *cfg);
bool L2CA_ConfigRsp(uint16_t cid, tL2CAP_CFG_INFO *cfg);
bool L2CA_DisconnectReq(uint16_t cid);
bool L2CA_DisconnectRsp(uint16_t cid);
uint8_t L2CA_DataWrite(uint16_t cid, BT_HDR *p_data);            // (takes the buffer, always)
bool L2CA_SetIdleTimeoutByBdAddr(uint8_t *bda, uint16_t timeout, uint8_t transport);
uint8_t L2CA_SetDesireRole(uint8_t new_role);
bool BTM_SetSecurityLevel(bool is_originator, const char *p_name, uint8_t service_id, uint16_t sec_level,
                          uint16_t psm, uint32_t mx_proto_id, uint32_t mx_chan_id);
void bta_sys_register(uint8_t id, const tBTA_SYS_REG *p_reg);
void BTA_DmBond(uint8_t *bd_addr);                            // (bta_api.h; posts to the BTU task)
void bta_sys_sendmsg(void *p_msg);
void *osi_malloc_func(size_t size);
void osi_free_func(void *ptr);
// the link's power mode (btm_api.h): a pad's link let drift into sniff delivers its reports in bursts
struct tBTM_PM_PWR_MD { uint16_t max, min, attempt, timeout; uint8_t mode; };
uint8_t BTM_SetLinkPolicy(uint8_t *remote_bda, uint16_t *settings);
void BTM_SetDefaultLinkPolicy(uint16_t settings);
uint8_t BTM_SetPowerMode(uint8_t pm_id, uint8_t *remote_bda, tBTM_PM_PWR_MD *p_mode);
uint8_t BTM_ReadPowerMode(uint8_t *remote_bda, uint8_t *p_mode);
}
static const uint16_t L2CAP_MIN_OFFSET = 13, L2CAP_CONN_OK = 0, L2CAP_CONN_NO_RESOURCES = 4, L2CAP_CFG_OK = 0;
static const uint8_t HCI_ROLE_MASTER = 0x00, BT_TRANSPORT_BR_EDR = 1, L2CAP_DW_FAILED = 0;
static const uint16_t BTM_SEC_IN_AUTHENTICATE = 0x0002, BTM_SEC_IN_ENCRYPT = 0x0004,
                      BTM_SEC_OUT_AUTHENTICATE = 0x0010, BTM_SEC_OUT_ENCRYPT = 0x0020;
static const uint8_t BTM_SEC_SERVICE_HIDH_SEC_CTRL = 32, BTM_SEC_SERVICE_HIDH_INTR = 34, BTM_SEC_PROTO_L2CAP = 0;
static const uint16_t HCI_ENABLE_MASTER_SLAVE_SWITCH = 0x0001;   // (the policy without hold, sniff, park)
static const uint8_t BTM_PM_SET_ONLY_ID = 0x80, BTM_PM_MD_ACTIVE = 0, BTM_PM_MD_SNIFF = 2, BTM_SUCCESS = 0;
static const uint8_t BTA_ID_HH = 23;              // the HID host's BTA slot: compiled out, so ours
}  // namespace bd

namespace padbt {

// --- what the rest of the firmware sees ----------------------------------------------------------
// buttons in the PC pad's order (pads.h's "P" line): 0 cross, 1 circle, 2 square, 3 triangle,
// 4 select, 5 start, 6-9 up/down/left/right, 10 L1, 11 R1, 12 L2, 13 R2, 14 PS/home
enum : uint16_t { B_CROSS = 1, B_CIRCLE = 2, B_SQUARE = 4, B_TRIANGLE = 8, B_SELECT = 16, B_START = 32,
                  B_UP = 64, B_DOWN = 128, B_LEFT = 256, B_RIGHT = 512, B_L1 = 1024, B_R1 = 2048,
                  B_L2 = 4096, B_R2 = 8192, B_HOME = 16384 };
enum Kind : uint8_t { K_UNKNOWN, K_SONY, K_DS4, K_DS5, K_SWITCH, K_XBOX_BT, K_XBOX_BLE };
static const char *const KIND_NAME[] = { "Bluetooth pad", "PlayStation pad", "DualShock 4", "DualSense",
                                         "Switch Pro", "Xbox (old firmware)", "Xbox Wireless" };
struct Pad {
  bool on;
  uint16_t btn;
  int8_t lx, ly, rx, ry;                  // -128..127, up negative
  int8_t battery;                         // 0..100, -1 not known
  uint8_t kind;
  char name[32];
};

// --- the two slots -------------------------------------------------------------------------------
enum : uint8_t { U_FREE, U_CLASSIC, U_BLE };
enum : uint8_t { C_IDLE, C_CONN_CTRL, C_CONN_INTR, C_CONFIG, C_UP };
enum : uint8_t { CF_MY_CTRL = 1, CF_HIS_CTRL = 2, CF_MY_INTR = 4, CF_HIS_INTR = 8, CF_ALL = 15 };
enum : uint8_t { ST_DONE, ST_IDENT, ST_SONY, ST_SWITCH };
static const int NSLOT = 2;
struct Slot {
  // shared (mux)
  uint8_t used;
  uint8_t bda[6];
  Pad pad;
  char rname[32];                         // the name the pad gave (inquiry / remote name request)
  volatile bool nameNew;
  // Classic: the BTU task's only
  uint8_t cst; bool orig, cong;
  uint16_t ctrl, intr, peerMtu; uint8_t cfg;
  uint8_t step, tries, swCnt, swSub, swIdx, ds5seq; bool swAcked; uint32_t stepT, upT;
  bool calOk; int16_t cal[2][6];          // Switch sticks: x centre, below, above, y centre, below, above
  uint8_t rumbleS, rumbleW;
  bool guide2;                            // an older Xbox's Xbox button (its report 0x02)
  // BLE
  esp_hidh_dev_t *dev;
  // for the "pads" serial command
  uint8_t lastId; uint16_t lastLen; uint32_t reports;
  uint32_t lastUs, gapMax, gapSum, gapN; uint8_t pm, polGen; uint32_t pmT;   // report spacing; the link's power mode
};
static Slot S[NSLOT];
static portMUX_TYPE mux = portMUX_INITIALIZER_UNLOCKED;
static volatile bool up = false;
static volatile bool keepActive = true;     // keep the pads' links out of sniff ("btactive off": leave them be)
static volatile uint8_t policyGen = 0;      // (bumped by the switch: each link takes the new policy at its next report)

// --- a few lines of what happened, for the "pads" command (and Log) ------------------------------
static char evLog[12][64];
static volatile uint8_t evN = 0;
static portMUX_TYPE evMux = portMUX_INITIALIZER_UNLOCKED;
template <class... A> static void ev(const char *f, A... a) {
  char line[64];
  int n = snprintf(line, sizeof line, "%6lu ", (unsigned long)(millis() / 100));   // (tenths of s)
  snprintf(line + n, sizeof line - n, f, a...);
  portENTER_CRITICAL(&evMux); memcpy(evLog[evN % 12], line, sizeof line); evN = evN + 1; portEXIT_CRITICAL(&evMux);
  Log.printf("pads: %s\n", line + n);
}
struct Mac { char s[18]; };                          // (by value: several tasks print addresses)
static Mac macOf(const uint8_t *b) {
  Mac m; snprintf(m.s, sizeof m.s, "%02x:%02x:%02x:%02x:%02x:%02x", b[0], b[1], b[2], b[3], b[4], b[5]);
  return m;
}
#define mac(b) (macOf(b).s)

static int slotOfBda(const uint8_t *bda) {
  for (int i = 0; i < NSLOT; i++) if (S[i].used && !memcmp(S[i].bda, bda, 6)) return i;
  return -1;
}
static int slotOfCid(uint16_t cid) {
  for (int i = 0; i < NSLOT; i++) if (S[i].used == U_CLASSIC && cid && (S[i].ctrl == cid || S[i].intr == cid)) return i;
  return -1;
}
static int slotOfDev(esp_hidh_dev_t *d) {
  for (int i = 0; i < NSLOT; i++) if (S[i].used == U_BLE && S[i].dev == d) return i;
  return -1;
}
// a slot for this pad: its own if it has one, else a free one (-1: none)
static int takeSlot(const uint8_t *bda, uint8_t how) {
  portENTER_CRITICAL(&mux);
  int i = slotOfBda(bda);
  if (i < 0) for (int k = 0; k < NSLOT; k++) if (!S[k].used) { i = k; break; }
  if (i >= 0 && !S[i].used) {
    Slot &s = S[i];
    memset(&s, 0, sizeof s);
    s.used = how; memcpy(s.bda, bda, 6); s.pad.battery = -1;
    strlcpy(s.pad.name, KIND_NAME[0], sizeof s.pad.name);
  }
  portEXIT_CRITICAL(&mux);
  return i;
}
static void freeSlot(int i) {
  portENTER_CRITICAL(&mux); memset(&S[i], 0, sizeof S[i]); portEXIT_CRITICAL(&mux);
}
static int freeSlots() { int n = 0; for (auto &s : S) if (!s.used) n++; return n; }
static bool anyOn() { for (auto &s : S) if (s.pad.on) return true; return false; }
// (strlcpy, not snprintf, inside the critical sections: nothing there that might take a lock)
static void showName(Slot &s) {                      // the kind's name once known, else the pad's own
  portENTER_CRITICAL(&mux);
  uint8_t k = s.pad.kind;
  strlcpy(s.pad.name, (k != K_UNKNOWN && k != K_SONY) || !s.rname[0] ? KIND_NAME[k] : s.rname, sizeof s.pad.name);
  portEXIT_CRITICAL(&mux);
}
static void setKind(Slot &s, uint8_t k) {
  if (s.pad.kind == k) return;
  portENTER_CRITICAL(&mux); s.pad.kind = k; portEXIT_CRITICAL(&mux);
  showName(s);
}
static void publish(Slot &s, uint16_t btn, int lx, int ly, int rx, int ry, int battery) {
  auto c = [](int v) { return (int8_t)(v < -128 ? -128 : v > 127 ? 127 : v); };
  portENTER_CRITICAL(&mux);
  s.pad.btn = btn; s.pad.lx = c(lx); s.pad.ly = c(ly); s.pad.rx = c(rx); s.pad.ry = c(ry);
  if (battery >= 0) s.pad.battery = battery > 100 ? 100 : battery;
  portEXIT_CRITICAL(&mux);
}

// --- report parsing ------------------------------------------------------------------------------
static uint16_t hat(uint8_t h) {                    // 0 up, 1 up-right, ... 7 up-left; others: none
  static const uint16_t T[8] = { B_UP, B_UP | B_RIGHT, B_RIGHT, B_DOWN | B_RIGHT, B_DOWN, B_DOWN | B_LEFT, B_LEFT, B_UP | B_LEFT };
  return h < 8 ? T[h] : 0;
}
// the Sony pads' three button bytes (the same in the DS4's and the DualSense's reports)
static uint16_t sonyButtons(uint8_t b0, uint8_t b1, uint8_t b2) {
  uint16_t o = hat(b0 & 0x0F);
  if (b0 & 0x10) o |= B_SQUARE;   if (b0 & 0x20) o |= B_CROSS;  if (b0 & 0x40) o |= B_CIRCLE; if (b0 & 0x80) o |= B_TRIANGLE;
  if (b1 & 0x01) o |= B_L1;       if (b1 & 0x02) o |= B_R1;     if (b1 & 0x04) o |= B_L2;     if (b1 & 0x08) o |= B_R2;
  if (b1 & 0x10) o |= B_SELECT;   if (b1 & 0x20) o |= B_START;  if (b2 & 0x01) o |= B_HOME;   // (share/create, options, PS)
  return o;
}
static int sonyBattery(uint8_t st) { int l = st & 0x0F; return l >= 10 ? 100 : l * 10 + 5; }
static int ax8(uint8_t v) { return (int)v - 128; }

// the Switch Pro's 12-bit sticks, through its factory calibration (or a typical one)
static int swAxis(const Slot &s, int stick, int y, int raw) {
  int c = 2048, below = 1500, above = 1500;
  if (s.calOk) { c = s.cal[stick][y * 3]; below = s.cal[stick][y * 3 + 1]; above = s.cal[stick][y * 3 + 2]; }
  int v = raw - c;
  v = v >= 0 ? v * 127 / (above ? above : 1) : v * 128 / (below ? below : 1);
  return y ? -v : v;                                    // (the Switch's y is up-positive)
}
static void parseSwitchFull(Slot &s, const uint8_t *r, int n) {     // 0x30 / 0x21
  if (n < 12) return;
  uint8_t R = r[3], M = r[4], L = r[5];
  uint16_t o = 0;
  if (R & 0x04) o |= B_CROSS;  if (R & 0x08) o |= B_CIRCLE; if (R & 0x01) o |= B_SQUARE; if (R & 0x02) o |= B_TRIANGLE;   // B A Y X, by position
  if (R & 0x40) o |= B_R1;     if (R & 0x80) o |= B_R2;
  if (M & 0x01) o |= B_SELECT; if (M & 0x02) o |= B_START;  if (M & 0x10) o |= B_HOME;
  if (L & 0x01) o |= B_DOWN;   if (L & 0x02) o |= B_UP;     if (L & 0x04) o |= B_RIGHT;  if (L & 0x08) o |= B_LEFT;
  if (L & 0x40) o |= B_L1;     if (L & 0x80) o |= B_L2;
  int lx = r[6] | (r[7] & 0x0F) << 8, ly = r[7] >> 4 | r[8] << 4;
  int rx = r[9] | (r[10] & 0x0F) << 8, ry = r[10] >> 4 | r[11] << 4;
  int bat = (r[2] >> 4) & 0x0E;                                    // 8 full, 6, 4, 2, 0 empty
  publish(s, o, swAxis(s, 0, 0, lx), swAxis(s, 0, 1, ly), swAxis(s, 1, 0, rx), swAxis(s, 1, 1, ry), bat * 100 / 8);
}
static void parseSwitchSimple(Slot &s, const uint8_t *r, int n) {   // 0x3F, before the 0x30 mode is on
  if (n < 12) return;
  uint8_t b1 = r[1], b2 = r[2];
  uint16_t o = hat(r[3]);
  if (b1 & 0x01) o |= B_CROSS; if (b1 & 0x02) o |= B_CIRCLE; if (b1 & 0x04) o |= B_SQUARE; if (b1 & 0x08) o |= B_TRIANGLE;
  if (b1 & 0x10) o |= B_L1;    if (b1 & 0x20) o |= B_R1;     if (b1 & 0x40) o |= B_L2;     if (b1 & 0x80) o |= B_R2;
  if (b2 & 0x01) o |= B_SELECT; if (b2 & 0x02) o |= B_START; if (b2 & 0x10) o |= B_HOME;
  auto a = [&](int i) { return (int)r[i + 1] - 128; };            // (16-bit, the high byte; HID's down-positive)
  publish(s, o, a(4), a(6), a(8), a(10), -1);
}
// Xbox: the report without its id (BLE gives it so; the Classic one is passed from r + 1)
static void parseXbox(Slot &s, const uint8_t *d, int n) {
  if (n < 15) return;
  auto a = [&](int i) { return (int)d[i + 1] - 128; };            // (16-bit, high byte; down-positive)
  int lt = (d[8] | d[9] << 8) & 0x3FF, rt = (d[10] | d[11] << 8) & 0x3FF;
  uint16_t o = d[12] ? hat(d[12] - 1) : 0;                         // (1 up ... 8 up-left, 0 none)
  // (as SDL's HIDAPI Xbox One driver reads them: 15 bytes, the first One S firmware; 16 and more,
  // firmware 4.8 (Classic) and 5.x (BLE), the Series pads and the Elite 2)
  if (n >= 16) {
    uint8_t b = d[13], m = d[14];
    if (b & 0x01) o |= B_CROSS;  if (b & 0x02) o |= B_CIRCLE; if (b & 0x08) o |= B_SQUARE; if (b & 0x10) o |= B_TRIANGLE;
    if (b & 0x40) o |= B_L1;     if (b & 0x80) o |= B_R1;
    if (m & 0x04) o |= B_SELECT; if (m & 0x08) o |= B_START;  if (m & 0x10) o |= B_HOME;
    if (d[15] & 0x01) o |= B_SELECT;                               // (fw 4.8's Back, the Series pads' Share)
  } else {
    uint8_t b = d[13];
    if (b & 0x01) o |= B_CROSS;  if (b & 0x02) o |= B_CIRCLE; if (b & 0x04) o |= B_SQUARE; if (b & 0x08) o |= B_TRIANGLE;
    if (b & 0x10) o |= B_L1;     if (b & 0x20) o |= B_R1;     if (b & 0x40) o |= B_SELECT; if (b & 0x80) o |= B_START;
  }
  if (s.guide2) o |= B_HOME;                                       // (older firmware: the Xbox button is report 2)
  if (lt > 200) o |= B_L2;
  if (rt > 200) o |= B_R2;
  publish(s, o, a(0), a(2), a(4), a(6), -1);
}

// --- Classic: output ------------------------------------------------------------------------------
static uint32_t crc32(const uint8_t *p, size_t n) {
  uint32_t c = 0xFFFFFFFFu;
  while (n--) { c ^= *p++; for (int k = 0; k < 8; k++) c = (c >> 1) ^ (0xEDB88320u & (0u - (c & 1))); }
  return ~c;
}
// (BTU task) bytes onto a channel, the HIDP header first
static void sendRaw(Slot &s, bool intr, const uint8_t *p, int n) {
  uint16_t cid = intr ? s.intr : s.ctrl;
  if (!cid || s.cong || (s.peerMtu && n > s.peerMtu)) return;
  auto *m = (bd::BT_HDR *)bd::osi_malloc_func(sizeof(bd::BT_HDR) + bd::L2CAP_MIN_OFFSET + n);
  if (!m) return;
  m->event = 0; m->layer_specific = 0; m->offset = bd::L2CAP_MIN_OFFSET; m->len = n;
  memcpy((uint8_t *)(m + 1) + bd::L2CAP_MIN_OFFSET, p, n);
  bd::L2CA_DataWrite(cid, m);
}
static int slotIndex(const Slot &s) { return (int)(&s - S); }
// DS4: output report 0x11 -- lightbar (blue for slot 1, red for slot 2) and rumble
static void ds4Out(Slot &s) {
  uint8_t b[79] = {};
  b[0] = 0xA2; b[1] = 0x11; b[2] = 0xC8;                  // DATA|output; HID + CRC, a report every 8 ms
  b[4] = 0x07;                                             // motors, lightbar, blink
  b[7] = s.rumbleW; b[8] = s.rumbleS;
  bool p2 = slotIndex(s) == 1;
  b[9] = p2 ? 0x40 : 0; b[10] = 0; b[11] = p2 ? 0 : 0x40;
  uint32_t c = crc32(b, 75);
  b[75] = c; b[76] = c >> 8; b[77] = c >> 16; b[78] = c >> 24;
  sendRaw(s, true, b, sizeof b);
}
// DualSense: output report 0x31 -- player dots, lightbar, the start-up blue off, rumble
static void ds5Out(Slot &s, bool first) {
  uint8_t b[79] = {};
  b[0] = 0xA2; b[1] = 0x31; b[2] = (uint8_t)(s.ds5seq++ << 4); b[3] = 0x10;
  b[4] = 0x03;                                             // compatible vibration, haptics select
  b[5] = 0x04 | 0x10;                                      // lightbar, player indicator
  b[6] = s.rumbleW; b[7] = s.rumbleS;
  b[42] = (first ? 0x02 : 0) | 0x04;                       // lightbar setup, vibration 2
  if (first) b[45] = 0x02;                                 // lightbar setup: light out
  bool p2 = slotIndex(s) == 1;
  b[47] = p2 ? 0x0A : 0x04;                                // player 1: the middle dot; 2: two
  b[48] = p2 ? 0x40 : 0; b[49] = 0; b[50] = p2 ? 0 : 0x40;
  uint32_t c = crc32(b, 75);
  b[75] = c; b[76] = c >> 8; b[77] = c >> 16; b[78] = c >> 24;
  sendRaw(s, true, b, sizeof b);
}
// GET_REPORT of a feature report turns the extended reports on: 0x05 (the Bluetooth calibration,
// as Linux asks for it), and on the retries 0x02 too (the USB one, as SDL asks for it)
static void sonyFeature(Slot &s) {
  uint8_t g[2] = { 0x43, (uint8_t)(s.tries & 1 ? 0x02 : 0x05) };
  sendRaw(s, false, g, 2);
  s.stepT = millis();
}
// Switch: subcommands, in order; each waits for its 0x21 reply
static void swSend(Slot &s) {
  uint8_t b[17] = { 0xA2, 0x01, (uint8_t)(s.swCnt++ & 0x0F), 0x00, 0x01, 0x40, 0x40, 0x00, 0x01, 0x40, 0x40 };
  int n = 12;
  switch (s.swIdx) {
  case 0: b[11] = 0x10; b[12] = 0x3D; b[13] = 0x60; b[14] = 0; b[15] = 0; b[16] = 0x12; n = 17; break;  // SPI 0x603D, 18 bytes
  case 1: b[11] = 0x03; b[12] = 0x30; n = 13; break;                                                    // 0x30 reports
  case 2: b[11] = 0x48; b[12] = 0x01; n = 13; break;                                                    // vibration on
  case 3: b[11] = 0x30; b[12] = slotIndex(s) == 1 ? 0x03 : 0x01; n = 13; break;                         // player lights
  default: s.step = ST_DONE; return;
  }
  s.swSub = b[11]; s.swAcked = false;
  sendRaw(s, true, b, n);
  s.stepT = millis();
}
// the next one goes from tick(), 70 ms on: Linux's hid-nintendo keeps subcommands over Bluetooth
// at least 60 ms apart
static void swNext(Slot &s) { s.swIdx++; s.tries = 0; s.swAcked = true; s.stepT = millis(); }
static void swCalibration(Slot &s, const uint8_t *d) {     // 18 bytes from 0x603D
  auto u12a = [](const uint8_t *p) { return (int16_t)(p[0] | (p[1] & 0x0F) << 8); };
  auto u12b = [](const uint8_t *p) { return (int16_t)(p[1] >> 4 | p[2] << 4); };
  const uint8_t *l = d, *r = d + 9;
  int16_t c[2][6] = {
    { u12a(l + 3), u12a(l + 6), u12a(l + 0), u12b(l + 3), u12b(l + 6), u12b(l + 0) },     // left: above, centre, below
    { u12a(r + 0), u12a(r + 3), u12a(r + 6), u12b(r + 0), u12b(r + 3), u12b(r + 6) } };   // right: centre, below, above
  bool ok = true;
  for (auto &st : c) for (int a = 0; a < 2; a++)
    if (st[a * 3] < 1000 || st[a * 3] > 3100 || st[a * 3 + 1] < 400 || st[a * 3 + 2] < 400) ok = false;
  if (ok) { memcpy(s.cal, c, sizeof c); s.calOk = true; }
  ev("switch calibration %s (centre %d,%d)", ok ? "read" : "unusable, typical used", c[0][0], c[0][3]);
}

// (BTU task) what the pad is, and what it is to be told
static void identified(Slot &s, uint8_t k) {
  if (s.pad.kind == k) return;
  setKind(s, k);
  ev("%s is a %s", mac(s.bda), KIND_NAME[k]);
  s.tries = 0;
  if (k == K_SONY) { s.step = ST_SONY; sonyFeature(s); }
  else if (k == K_DS4) { s.step = ST_DONE; ds4Out(s); }
  else if (k == K_DS5) { s.step = ST_DONE; ds5Out(s, true); }
  else if (k == K_SWITCH) { s.step = ST_SWITCH; s.swIdx = 0; swSend(s); }
  else s.step = ST_DONE;
}
static uint8_t kindOfName(const char *n) {
  if (strstr(n, "Pro Controller") || strstr(n, "Joy-Con") || strstr(n, "Nintendo")) return K_SWITCH;
  if (strstr(n, "Xbox")) return K_XBOX_BT;
  if (strstr(n, "Wireless Controller") || strstr(n, "DualSense") || strstr(n, "DUALSHOCK")) return K_SONY;
  return K_UNKNOWN;
}

// (BTU task) a report from a Classic pad: r[0] its id
static void classicReport(Slot &s, const uint8_t *r, int n) {
  s.lastId = r[0]; s.lastLen = n; s.reports++;
  uint32_t t = micros();
  if (s.lastUs) { uint32_t g = t - s.lastUs; if (g > s.gapMax) s.gapMax = g; s.gapSum += g; s.gapN++; }
  s.lastUs = t;
  if (s.polGen != policyGen) {
    s.polGen = policyGen;
    uint16_t pol = keepActive ? bd::HCI_ENABLE_MASTER_SLAVE_SWITCH : (uint16_t)(bd::HCI_ENABLE_MASTER_SLAVE_SWITCH | 0x0004);
    bd::BTM_SetLinkPolicy(s.bda, &pol);
  }
  if (millis() - s.pmT > 500) {                  // (twice a second: still active?)
    s.pmT = millis();
    uint8_t m = 0xFF;
    if (bd::BTM_ReadPowerMode(s.bda, &m) == bd::BTM_SUCCESS) s.pm = m;
    if (keepActive && m == bd::BTM_PM_MD_SNIFF) {
      bd::tBTM_PM_PWR_MD md = {}; md.mode = bd::BTM_PM_MD_ACTIVE;
      bd::BTM_SetPowerMode(bd::BTM_PM_SET_ONLY_ID, s.bda, &md);
      ev("%s was in sniff: back to active", mac(s.bda));
    }
  }
  switch (r[0]) {
  case 0x01:                                                         // Sony's short report (10 bytes), or an old Xbox's (16-20)
    if (s.pad.kind == K_XBOX_BT || (s.pad.kind == K_UNKNOWN && n >= 16 && n <= 20)) {
      if (s.pad.kind != K_XBOX_BT) identified(s, K_XBOX_BT);
      parseXbox(s, r + 1, n - 1);
      break;
    }
    if (n < 10) break;
    if (s.pad.kind == K_UNKNOWN) identified(s, K_SONY);
    publish(s, sonyButtons(r[5], r[6], r[7]), ax8(r[1]), ax8(r[2]), ax8(r[3]), ax8(r[4]), -1);
    break;
  case 0x02:                                                         // old Xbox: its Xbox button
    if (s.pad.kind == K_XBOX_BT && n >= 2) {
      s.guide2 = r[1] & 1;
      portENTER_CRITICAL(&mux); s.pad.btn = (s.pad.btn & ~B_HOME) | (s.guide2 ? B_HOME : 0); portEXIT_CRITICAL(&mux);
    }
    break;
  case 0x11:
    if (n < 33) break;
    if (s.pad.kind != K_DS4) identified(s, K_DS4);
    publish(s, sonyButtons(r[7], r[8], r[9]), ax8(r[3]), ax8(r[4]), ax8(r[5]), ax8(r[6]), sonyBattery(r[32]));
    break;
  case 0x31:
    if (n < 55) break;
    if (s.pad.kind != K_DS5) identified(s, K_DS5);
    publish(s, sonyButtons(r[9], r[10], r[11]), ax8(r[2]), ax8(r[3]), ax8(r[4]), ax8(r[5]), sonyBattery(r[54]));
    break;
  case 0x3F:
    if (s.pad.kind != K_SWITCH) identified(s, K_SWITCH);
    parseSwitchSimple(s, r, n);
    break;
  case 0x21:
    if (s.pad.kind != K_SWITCH) identified(s, K_SWITCH);
    parseSwitchFull(s, r, n);
    if (s.step == ST_SWITCH && !s.swAcked && n >= 15 && r[14] == s.swSub) {
      if (s.swSub == 0x10 && n >= 38) swCalibration(s, r + 20);
      swNext(s);
    }
    break;
  case 0x30:
    if (s.pad.kind != K_SWITCH) identified(s, K_SWITCH);
    parseSwitchFull(s, r, n);
    break;
  }
}

// --- Classic: the L2CAP side (BTU task) ------------------------------------------------------------
static bd::tL2CAP_CFG_INFO myCfg;
static void channelsUp(Slot &s) {
  s.cst = C_UP; s.upT = millis(); s.step = ST_IDENT;
  portENTER_CRITICAL(&mux); s.pad.on = true; portEXIT_CRITICAL(&mux);
  ev("%s up (%s)", mac(s.bda), s.orig ? "we called" : "it called");
  if (keepActive) {                                       // (no sniff: a report every few ms, not in bursts)
    uint16_t pol = bd::HCI_ENABLE_MASTER_SLAVE_SWITCH;
    bd::BTM_SetLinkPolicy(s.bda, &pol);
  }
  s.lastUs = s.gapMax = s.gapSum = s.gapN = 0;
  esp_bt_gap_read_remote_name(s.bda);                     // (the answer: gapEvent)
  uint8_t k = s.rname[0] ? kindOfName(s.rname) : (uint8_t)K_UNKNOWN;
  if (k == K_SWITCH || k == K_XBOX_BT) identified(s, k);  // (the Sony pads say so with their first report)
}
static void progress(Slot &s) {
  if (s.orig && (s.cfg & (CF_MY_CTRL | CF_HIS_CTRL)) == (CF_MY_CTRL | CF_HIS_CTRL) && !s.intr && s.cst == C_CONFIG) {
    s.intr = bd::L2CA_ConnectReq(0x13, s.bda);
    s.cst = s.intr ? C_CONN_INTR : C_IDLE;
    if (!s.intr) ev("%s: no interrupt channel", mac(s.bda));
  }
  if ((s.cfg & CF_ALL) == CF_ALL && s.cst != C_UP) channelsUp(s);
}
static void closeSlot(int i, const char *why) {
  Slot &s = S[i];
  ev("%s gone: %s", mac(s.bda), why);
  freeSlot(i);
}
static void l2ConnectInd(uint8_t *bda, uint16_t cid, uint16_t psm, uint8_t id) {
  int i = slotOfBda(bda);
  if (psm == 0x11) {
    if (i >= 0 && S[i].used == U_CLASSIC && S[i].cst == C_UP) {   // (a pad back before we saw it go)
      closeSlot(i, "came back");
      i = -1;
    }
    if (i < 0) i = takeSlot(bda, U_CLASSIC);
    if (i < 0 || S[i].used != U_CLASSIC) {
      bd::L2CA_ConnectRsp(bda, id, cid, bd::L2CAP_CONN_NO_RESOURCES, 0);
      ev("%s refused: no free slot", mac(bda));
      return;
    }
    Slot &s = S[i];
    s.orig = false; s.ctrl = cid; s.intr = 0; s.cfg = 0; s.cst = C_CONFIG;
  } else {
    if (i < 0 || S[i].used != U_CLASSIC || !S[i].ctrl) { bd::L2CA_ConnectRsp(bda, id, cid, bd::L2CAP_CONN_NO_RESOURCES, 0); return; }
    S[i].intr = cid;
  }
  bd::L2CA_ConnectRsp(bda, id, cid, bd::L2CAP_CONN_OK, bd::L2CAP_CONN_OK);
  bd::L2CA_ConfigReq(cid, &myCfg);
}
static void l2ConnectCfm(uint16_t cid, uint16_t result) {
  int i = slotOfCid(cid);
  if (i < 0) return;
  Slot &s = S[i];
  if (result != bd::L2CAP_CONN_OK) {
    if (cid == s.ctrl) s.ctrl = 0; else s.intr = 0;
    if (s.ctrl) bd::L2CA_DisconnectReq(s.ctrl);
    else { char w[24]; snprintf(w, sizeof w, "connect failed 0x%x", result); closeSlot(i, w); }
    return;
  }
  s.cst = C_CONFIG;
  bd::L2CA_ConfigReq(cid, &myCfg);
}
static void l2ConfigInd(uint16_t cid, bd::tL2CAP_CFG_INFO *cfg) {
  int i = slotOfCid(cid);
  if (i < 0) return;
  Slot &s = S[i];
  if (cid == s.intr) s.peerMtu = (!cfg->mtu_present || cfg->mtu > 640) ? 640 : cfg->mtu;
  cfg->flush_to_present = false; cfg->mtu_present = false; cfg->result = bd::L2CAP_CFG_OK;
  bd::L2CA_ConfigRsp(cid, cfg);
  s.cfg |= cid == s.ctrl ? CF_HIS_CTRL : CF_HIS_INTR;
  progress(s);
}
static void l2ConfigCfm(uint16_t cid, bd::tL2CAP_CFG_INFO *cfg) {
  int i = slotOfCid(cid);
  if (i < 0) return;
  Slot &s = S[i];
  if (cfg->result != bd::L2CAP_CFG_OK) { bd::L2CA_DisconnectReq(cid); return; }
  s.cfg |= cid == s.ctrl ? CF_MY_CTRL : CF_MY_INTR;
  progress(s);
}
static void l2Gone(uint16_t cid) {
  int i = slotOfCid(cid);
  if (i < 0) return;
  Slot &s = S[i];
  if (cid == s.intr) { s.intr = 0; if (s.ctrl) bd::L2CA_DisconnectReq(s.ctrl); }
  else s.ctrl = 0;
  if (!s.ctrl && !s.intr) closeSlot(i, "disconnected");
}
static void l2DisconnectInd(uint16_t cid, bool ack) { if (ack) bd::L2CA_DisconnectRsp(cid); l2Gone(cid); }
static void l2DisconnectCfm(uint16_t cid, uint16_t) { l2Gone(cid); }
static void l2Congestion(uint16_t cid, bool c) { int i = slotOfCid(cid); if (i >= 0) S[i].cong = c; }
static void l2Data(uint16_t cid, bd::BT_HDR *m) {
  int i = slotOfCid(cid);
  const uint8_t *p = (const uint8_t *)(m + 1) + m->offset;
  int n = m->len;
  if (i >= 0 && n >= 2) {
    Slot &s = S[i];
    uint8_t t = p[0] >> 4;
    if (t == 0xA && (p[0] & 3) == 1) classicReport(s, p + 1, n - 1);        // DATA, input
    else if (t == 0x1 && (p[0] & 0x0F) == 5) bd::L2CA_DisconnectReq(s.intr ? s.intr : s.ctrl);   // virtual cable unplug
  }
  bd::osi_free_func(m);
}
static bd::tL2CAP_APPL_INFO l2Reg = { l2ConnectInd, l2ConnectCfm, nullptr, l2ConfigInd, l2ConfigCfm,
                                      l2DisconnectInd, l2DisconnectCfm, nullptr, l2Data, l2Congestion, nullptr };

// --- messages into the BTU task --------------------------------------------------------------------
enum : uint8_t { M_INIT = 1, M_CONNECT, M_TICK, M_DISCONNECT, M_RUMBLE };
struct Msg { bd::BT_HDR h; uint8_t slot; uint8_t bda[6]; char name[32]; };
static void post(uint8_t what, int slot = 0, const uint8_t *bda = nullptr, const char *name = nullptr) {
  auto *m = (Msg *)bd::osi_malloc_func(sizeof(Msg));
  if (!m) return;
  memset(m, 0, sizeof *m);
  m->h.event = (uint16_t)(bd::BTA_ID_HH << 8 | what);
  m->slot = slot;
  if (bda) memcpy(m->bda, bda, 6);
  if (name) snprintf(m->name, sizeof m->name, "%s", name);
  bd::bta_sys_sendmsg(m);
}
static void tick() {
  uint32_t now = millis();
  for (auto &s : S) {
    if (s.used != U_CLASSIC || s.cst != C_UP) continue;
    if (s.nameNew) {
      s.nameNew = false;
      uint8_t k = kindOfName(s.rname);
      if (s.pad.kind == K_UNKNOWN && k != K_UNKNOWN) identified(s, k);
      else showName(s);                                     // (the pad's own name, until its kind is known)
    }
    switch (s.step) {
    case ST_SONY:                                          // asked for feature 0x05: no 0x11/0x31 yet
      if (now - s.stepT > 400) {
        if (++s.tries > 5) { s.step = ST_DONE; ev("%s stays on short reports", mac(s.bda)); }
        else sonyFeature(s);
      }
      break;
    case ST_SWITCH:
      if (s.swAcked) { if (now - s.stepT >= 70) swSend(s); }
      else if (now - s.stepT > 300) { if (++s.tries > 3) swNext(s); else swSend(s); }
      break;
    }
  }
}
static bool btuEvent(bd::BT_HDR *h) {
  Msg *m = (Msg *)h;
  switch (h->event & 0xFF) {
  case M_INIT: {
    memset(&myCfg, 0, sizeof myCfg);
    myCfg.mtu_present = true; myCfg.mtu = 640;
    myCfg.flush_to_present = true; myCfg.flush_to = 0xFFFF;
    uint16_t sec = bd::BTM_SEC_IN_AUTHENTICATE | bd::BTM_SEC_IN_ENCRYPT | bd::BTM_SEC_OUT_AUTHENTICATE | bd::BTM_SEC_OUT_ENCRYPT;
    bool ok = bd::L2CA_Register(0x11, &l2Reg) && bd::L2CA_Register(0x13, &l2Reg);
    for (int orig = 0; orig < 2; orig++) {
      ok &= bd::BTM_SetSecurityLevel(orig, "", bd::BTM_SEC_SERVICE_HIDH_SEC_CTRL, sec, 0x11, bd::BTM_SEC_PROTO_L2CAP, 0);
      ok &= bd::BTM_SetSecurityLevel(orig, "", bd::BTM_SEC_SERVICE_HIDH_INTR, sec, 0x13, bd::BTM_SEC_PROTO_L2CAP, 0);
    }
    bd::L2CA_SetDesireRole(bd::HCI_ROLE_MASTER);
    if (keepActive) bd::BTM_SetDefaultLinkPolicy(bd::HCI_ENABLE_MASTER_SLAVE_SWITCH);
    up = ok;
    ev("HID host %s", ok ? "registered" : "NOT registered (L2CAP/security)");
    break; }
  case M_CONNECT: {                                       // a pad found while pairing: call it
    if (slotOfBda(m->bda) >= 0) break;
    int i = takeSlot(m->bda, U_CLASSIC);
    if (i < 0 || S[i].used != U_CLASSIC) break;
    Slot &s = S[i];
    s.orig = true; snprintf(s.rname, sizeof s.rname, "%s", m->name);
    s.ctrl = bd::L2CA_ConnectReq(0x11, s.bda);
    if (!s.ctrl) { closeSlot(i, "no L2CAP connection"); break; }
    s.cst = C_CONN_CTRL;
    ev("calling %s %s", mac(s.bda), s.rname);
    break; }
  case M_TICK: tick(); break;
  case M_DISCONNECT: {
    Slot &s = S[m->slot % NSLOT];
    if (s.used != U_CLASSIC) break;
    bd::L2CA_SetIdleTimeoutByBdAddr(s.bda, 0, bd::BT_TRANSPORT_BR_EDR);
    if (s.intr) bd::L2CA_DisconnectReq(s.intr); else if (s.ctrl) bd::L2CA_DisconnectReq(s.ctrl);
    break; }
  case M_RUMBLE: {
    Slot &s = S[m->slot % NSLOT];
    if (s.used != U_CLASSIC || s.cst != C_UP) break;
    if (s.pad.kind == K_DS4) ds4Out(s); else if (s.pad.kind == K_DS5) ds5Out(s, false);
    break; }
  }
  return true;                                            // (BTA frees it)
}
static void btuDisable() {}
static const bd::tBTA_SYS_REG btuReg = { btuEvent, btuDisable };

// --- finding pads: GAP (BTC task) -------------------------------------------------------------------
static volatile bool pairing = true, inquiring = false, scanning = false, scanParamsSet = false;
static volatile uint32_t pairUntil = 120000;
struct Found { volatile bool valid; uint8_t bda[6]; char name[32]; uint8_t addrType; };
static Found classicFound, bleFound;
static portMUX_TYPE foundMux = portMUX_INITIALIZER_UNLOCKED;
static volatile int bleBonded = 0;
static esp_bd_addr_t bleBonds[4];
// a Classic pad found while pairing: bonded first (dedicated bonding, as BlueZ's "pair" does: an
// L2CAP connection alone pairs it as "no bonding", and a pad may then not keep the key), then
// called on 0x11/0x13 within the 3 s that Bluedroid keeps a bonding's link up
static volatile uint32_t callT = 0;               // since when (0: no pad being called)
static volatile bool callBonding = false;
static uint8_t callBda[6];
static char callName[32];

static bool pairingNow() { return pairing && ((int32_t)(pairUntil - millis()) > 0 || !anyOn()); }

static void gapEvent(esp_bt_gap_cb_event_t e, esp_bt_gap_cb_param_t *p) {
  switch (e) {
  case ESP_BT_GAP_DISC_RES_EVT: {
    uint32_t cod = 0; char name[32] = "";
    for (int i = 0; i < p->disc_res.num_prop; i++) {
      esp_bt_gap_dev_prop_t &q = p->disc_res.prop[i];
      if (q.type == ESP_BT_GAP_DEV_PROP_COD) cod = *(uint32_t *)q.val;
      else if (q.type == ESP_BT_GAP_DEV_PROP_BDNAME && !name[0]) snprintf(name, sizeof name, "%.*s", q.len, (char *)q.val);
      else if (q.type == ESP_BT_GAP_DEV_PROP_EIR && !name[0]) {
        uint8_t l = 0;
        uint8_t *nm = esp_bt_gap_resolve_eir_data((uint8_t *)q.val, ESP_BT_EIR_TYPE_CMPL_LOCAL_NAME, &l);
        if (!nm) nm = esp_bt_gap_resolve_eir_data((uint8_t *)q.val, ESP_BT_EIR_TYPE_SHORT_LOCAL_NAME, &l);
        if (nm) snprintf(name, sizeof name, "%.*s", l, (char *)nm);
      }
    }
    // peripheral (major 5), joystick or gamepad (minor bits 2-5: 1, 2); or a name we know
    bool pad = ((cod >> 8) & 0x1F) == 5 && (((cod >> 2) & 0x0F) == 1 || ((cod >> 2) & 0x0F) == 2);
    if (!pad && kindOfName(name) == K_UNKNOWN) break;
    if (slotOfBda(p->disc_res.bda) >= 0 || !pairingNow()) break;
    portENTER_CRITICAL(&foundMux);
    if (!classicFound.valid) {
      memcpy(classicFound.bda, p->disc_res.bda, 6); memcpy(classicFound.name, name, sizeof name);
      classicFound.valid = true;
    }
    portEXIT_CRITICAL(&foundMux);
    break; }
  case ESP_BT_GAP_DISC_STATE_CHANGED_EVT:
    inquiring = p->disc_st_chg.state == ESP_BT_GAP_DISCOVERY_STARTED;
    break;
  case ESP_BT_GAP_CFM_REQ_EVT: esp_bt_gap_ssp_confirm_reply(p->cfm_req.bda, true); break;       // just works
  case ESP_BT_GAP_KEY_REQ_EVT: esp_bt_gap_ssp_passkey_reply(p->key_req.bda, true, 0); break;
  case ESP_BT_GAP_PIN_REQ_EVT: {                                                               // legacy: 0000
    esp_bt_pin_code_t pin = { '0', '0', '0', '0' };
    esp_bt_gap_pin_reply(p->pin_req.bda, true, 4, pin);
    break; }
  case ESP_BT_GAP_AUTH_CMPL_EVT:
    ev("%s pairing %s (%d)", mac(p->auth_cmpl.bda), p->auth_cmpl.stat == ESP_BT_STATUS_SUCCESS ? "ok" : "FAILED", p->auth_cmpl.stat);
    if (callBonding && !memcmp(p->auth_cmpl.bda, callBda, 6)) {
      callBonding = false; callT = millis();
      post(M_CONNECT, 0, callBda, callName);        // (failed or not: L2CAP's own security tries again)
    }
    break;
  case ESP_BT_GAP_READ_REMOTE_NAME_EVT: {
    if (p->read_rmt_name.stat != ESP_BT_STATUS_SUCCESS) break;
    portENTER_CRITICAL(&mux);
    int i = slotOfBda(p->read_rmt_name.bda);
    if (i >= 0) { strlcpy(S[i].rname, (char *)p->read_rmt_name.rmt_name, sizeof S[i].rname); S[i].nameNew = true; }
    portEXIT_CRITICAL(&mux);
    break; }
  default: break;
  }
}

static bool advHas16(uint8_t *adv, int len, esp_ble_adv_data_type t, uint16_t uuid) {
  uint8_t l = 0;
  uint8_t *d = esp_ble_resolve_adv_data_by_type(adv, len, t, &l);
  for (int i = 0; d && i + 1 < l; i += 2) if ((d[i] | d[i + 1] << 8) == uuid) return true;
  return false;
}
static void bleGapEvent(esp_gap_ble_cb_event_t e, esp_ble_gap_cb_param_t *p) {
  switch (e) {
  case ESP_GAP_BLE_SCAN_PARAM_SET_COMPLETE_EVT: scanParamsSet = true; break;
  case ESP_GAP_BLE_SCAN_START_COMPLETE_EVT: scanning = p->scan_start_cmpl.status == ESP_BT_STATUS_SUCCESS; break;
  case ESP_GAP_BLE_SCAN_STOP_COMPLETE_EVT: scanning = false; break;
  case ESP_GAP_BLE_SCAN_RESULT_EVT: {
    auto &r = p->scan_rst;
    if (r.search_evt == ESP_GAP_SEARCH_INQ_CMPL_EVT) { scanning = false; break; }
    if (r.search_evt != ESP_GAP_SEARCH_INQ_RES_EVT) break;
    if (r.ble_evt_type != ESP_BLE_EVT_CONN_ADV && r.ble_evt_type != ESP_BLE_EVT_CONN_DIR_ADV) break;
    if (slotOfBda(r.bda) >= 0) break;
    bool bonded = false;
    for (int i = 0; i < bleBonded && i < 4; i++) if (!memcmp(bleBonds[i], r.bda, 6)) bonded = true;
    int len = r.adv_data_len + r.scan_rsp_len;
    uint8_t l = 0; char name[32] = "";
    uint8_t *nm = esp_ble_resolve_adv_data_by_type(r.ble_adv, len, ESP_BLE_AD_TYPE_NAME_CMPL, &l);
    if (!nm) nm = esp_ble_resolve_adv_data_by_type(r.ble_adv, len, ESP_BLE_AD_TYPE_NAME_SHORT, &l);
    if (nm) snprintf(name, sizeof name, "%.*s", l, (char *)nm);
    uint8_t *ap = esp_ble_resolve_adv_data_by_type(r.ble_adv, len, ESP_BLE_AD_TYPE_APPEARANCE, &l);
    uint16_t appearance = ap && l >= 2 ? (ap[0] | ap[1] << 8) : 0;
    bool hid = advHas16(r.ble_adv, len, ESP_BLE_AD_TYPE_16SRV_CMPL, 0x1812) || advHas16(r.ble_adv, len, ESP_BLE_AD_TYPE_16SRV_PART, 0x1812);
    // a gamepad / joystick by its appearance, an Xbox by its name, or a HID "...Controller"
    bool padLike = (appearance >= 0x03C3 && appearance <= 0x03C4) || !strncmp(name, "Xbox", 4) || (hid && strstr(name, "Controller"));
    if (!(bonded || (padLike && pairingNow()))) break;
    portENTER_CRITICAL(&foundMux);
    if (!bleFound.valid) {
      memcpy(bleFound.bda, r.bda, 6); memcpy(bleFound.name, name, sizeof name); bleFound.addrType = r.ble_addr_type;
      bleFound.valid = true;
    }
    portEXIT_CRITICAL(&foundMux);
    break; }
  case ESP_GAP_BLE_SEC_REQ_EVT: esp_ble_gap_security_rsp(p->ble_security.ble_req.bd_addr, true); break;
  case ESP_GAP_BLE_NC_REQ_EVT: esp_ble_confirm_reply(p->ble_security.key_notif.bd_addr, true); break;
  case ESP_GAP_BLE_PASSKEY_REQ_EVT: esp_ble_passkey_reply(p->ble_security.ble_req.bd_addr, true, 0); break;
  case ESP_GAP_BLE_AUTH_CMPL_EVT:
    ev("%s BLE pairing %s", mac(p->ble_security.auth_cmpl.bd_addr), p->ble_security.auth_cmpl.success ? "ok" : "FAILED");
    break;
  default: break;
  }
}

// --- BLE pads: esp_hidh's events (its own task) ---------------------------------------------------
static void hidhEvent(void *, esp_event_base_t, int32_t id, void *data) {
  auto *p = (esp_hidh_event_data_t *)data;
  switch ((esp_hidh_event_t)id) {
  case ESP_HIDH_INPUT_EVENT: {
    int i = slotOfDev(p->input.dev);
    if (i < 0) break;
    Slot &s = S[i];
    s.lastId = p->input.report_id; s.lastLen = p->input.length; s.reports++;
    if (p->input.report_id == 1 || p->input.usage == ESP_HID_USAGE_GAMEPAD) parseXbox(s, p->input.data, p->input.length);
    break; }
  case ESP_HIDH_BATTERY_EVENT: {
    int i = slotOfDev(p->battery.dev);
    if (i >= 0) { portENTER_CRITICAL(&mux); S[i].pad.battery = p->battery.level > 100 ? 100 : p->battery.level; portEXIT_CRITICAL(&mux); }
    break; }
  case ESP_HIDH_CLOSE_EVENT: {
    int i = slotOfDev(p->close.dev);
    if (i >= 0) closeSlot(i, "BLE closed");
    esp_hidh_dev_free(p->close.dev);
    break; }
  default: break;
  }
}

// --- the finder task ------------------------------------------------------------------------------
enum { REQ_NONE, REQ_FORGET, REQ_PAIR_ON, REQ_PAIR_OFF };
static volatile int req = REQ_NONE;
static bool scanOn(bool active, uint16_t interval, uint16_t window, uint32_t seconds) {
  esp_ble_scan_params_t sp = {};
  sp.scan_type = active ? BLE_SCAN_TYPE_ACTIVE : BLE_SCAN_TYPE_PASSIVE;
  sp.own_addr_type = BLE_ADDR_TYPE_PUBLIC;
  sp.scan_filter_policy = BLE_SCAN_FILTER_ALLOW_ALL;
  sp.scan_interval = interval; sp.scan_window = window;
  sp.scan_duplicate = BLE_SCAN_DUPLICATE_DISABLE;
  scanParamsSet = false;
  if (esp_ble_gap_set_scan_params(&sp) != ESP_OK) return false;
  for (int t = 0; t < 50 && !scanParamsSet; t++) vTaskDelay(pdMS_TO_TICKS(10));
  scanning = true;                                          // (until the start event says otherwise)
  if (esp_ble_gap_start_scanning(seconds) == ESP_OK) return true;
  scanning = false;
  return false;
}
static void scanOff() {
  if (!scanning) return;
  esp_ble_gap_stop_scanning();
  for (int t = 0; t < 50 && scanning; t++) vTaskDelay(pdMS_TO_TICKS(10));
  scanning = false;
}
static void inquiryOff() {
  if (!inquiring) return;
  esp_bt_gap_cancel_discovery();
  for (int t = 0; t < 100 && inquiring; t++) vTaskDelay(pdMS_TO_TICKS(10));
}
static void refreshBonds() {
  int n = esp_ble_get_bond_device_num();
  if (n <= 0) { bleBonded = 0; return; }
  esp_ble_bond_dev_t list[4];
  if (n > 4) n = 4;
  if (esp_ble_get_bond_device_list(&n, list) != ESP_OK) return;
  for (int i = 0; i < n; i++) memcpy(bleBonds[i], list[i].bd_addr, 6);
  bleBonded = n;
}
static bool bleAway() {                              // a bonded BLE pad not connected now
  for (int i = 0; i < bleBonded && i < 4; i++) if (slotOfBda(bleBonds[i]) < 0) return true;
  return false;
}
static void forgetAll() {
  inquiryOff(); scanOff();
  for (int i = 0; i < NSLOT; i++) {
    if (S[i].used == U_CLASSIC) post(M_DISCONNECT, i);
    else if (S[i].used == U_BLE && S[i].dev) esp_hidh_dev_close(S[i].dev);
  }
  int n = esp_bt_gap_get_bond_device_num();
  if (n > 0) {
    esp_bd_addr_t *l = (esp_bd_addr_t *)malloc(n * sizeof(esp_bd_addr_t));
    if (l && esp_bt_gap_get_bond_device_list(&n, l) == ESP_OK) for (int i = 0; i < n; i++) esp_bt_gap_remove_bond_device(l[i]);
    free(l);
  }
  int m = esp_ble_get_bond_device_num();
  if (m > 0) {
    esp_ble_bond_dev_t *l = (esp_ble_bond_dev_t *)malloc(m * sizeof(esp_ble_bond_dev_t));
    if (l && esp_ble_get_bond_device_list(&m, l) == ESP_OK) for (int i = 0; i < m; i++) esp_ble_remove_bond_device(l[i].bd_addr);
    free(l);
  }
  bleBonded = 0;
  ev("forgot %d Classic and %d BLE pads", n > 0 ? n : 0, m > 0 ? m : 0);
}
static void openBle(const Found &f) {
  scanOff(); inquiryOff();
  if (!freeSlots()) return;
  ev("opening BLE %s %s", mac(f.bda), f.name);
  esp_bd_addr_t a; memcpy(a, f.bda, 6);
  esp_hidh_dev_t *dev = esp_hidh_dev_open(a, ESP_HID_TRANSPORT_BLE, f.addrType);   // (blocks)
  if (!dev) { ev("BLE open failed"); return; }
  const char *nm = esp_hidh_dev_name_get(dev);
  uint16_t vid = esp_hidh_dev_vendor_id_get(dev);
  bool xbox = vid == 0x045E || (nm && !strncmp(nm, "Xbox", 4)) || !strncmp(f.name, "Xbox", 4);
  int i = xbox ? takeSlot(f.bda, U_BLE) : -1;
  if (i < 0 || S[i].used != U_BLE || S[i].dev) {
    ev("BLE %s %s: %s", mac(f.bda), nm ? nm : "", xbox ? "no free slot" : "not an Xbox pad, dropped");
    esp_hidh_dev_close(dev);
    if (!xbox) esp_ble_remove_bond_device(a);
    return;
  }
  Slot &s = S[i];
  portENTER_CRITICAL(&mux);
  s.dev = dev; s.pad.on = true; s.pad.kind = K_XBOX_BLE;
  strlcpy(s.rname, nm ? nm : f.name, sizeof s.rname);
  strlcpy(s.pad.name, KIND_NAME[K_XBOX_BLE], sizeof s.pad.name);
  portEXIT_CRITICAL(&mux);
  ev("%s up (BLE, vid %04x)", mac(f.bda), vid);
}
static bool classicBonded(const uint8_t *bda) {
  int n = esp_bt_gap_get_bond_device_num();
  if (n <= 0) return false;
  esp_bd_addr_t *l = (esp_bd_addr_t *)malloc(n * sizeof(esp_bd_addr_t));
  bool hit = false;
  if (l && esp_bt_gap_get_bond_device_list(&n, l) == ESP_OK) for (int i = 0; i < n; i++) if (!memcmp(l[i], bda, 6)) hit = true;
  free(l);
  return hit;
}
static void finder(void *) {
  uint32_t lastBonds = 0; int phase = 0;
  for (;;) {
    vTaskDelay(pdMS_TO_TICKS(20));
    int r = req; req = REQ_NONE;
    if (r == REQ_FORGET) forgetAll();
    else if (r == REQ_PAIR_ON) { pairing = true; pairUntil = millis() + 120000; }
    else if (r == REQ_PAIR_OFF) { pairing = false; pairUntil = millis(); inquiryOff(); scanOff(); }
    if (millis() - lastBonds > 3000) { lastBonds = millis(); refreshBonds(); }
    // a Classic pad being bonded / called: until it is up or gone (30 s at most)
    if (callT) {
      int i = slotOfBda(callBda);
      uint32_t age = millis() - callT;
      if (!((i >= 0 && S[i].cst == C_UP) || (!callBonding && i < 0 && age > 3000) || age > 30000)) continue;
      if (callBonding) ev("%s: bonding timed out", mac(callBda));
      callBonding = false; callT = 0;
    }
    if (classicFound.valid) {
      Found f; portENTER_CRITICAL(&foundMux); f = classicFound; classicFound.valid = false; portEXIT_CRITICAL(&foundMux);
      if (freeSlots() && slotOfBda(f.bda) < 0) {
        inquiryOff(); scanOff();
        if (classicBonded(f.bda)) {                         // (a pad in pairing mode has a new key coming)
          esp_bt_gap_remove_bond_device(f.bda);
          vTaskDelay(pdMS_TO_TICKS(300));
        }
        memcpy(callBda, f.bda, 6); strlcpy(callName, f.name, sizeof callName);
        callBonding = true; callT = millis();
        ev("bonding with %s %s", mac(f.bda), f.name);
        bd::BTA_DmBond(callBda);
      }
      continue;
    }
    if (bleFound.valid) {
      Found f; portENTER_CRITICAL(&foundMux); f = bleFound; bleFound.valid = false; portEXIT_CRITICAL(&foundMux);
      if (freeSlots() && slotOfBda(f.bda) < 0) openBle(f);
      continue;
    }
    if (!freeSlots()) { inquiryOff(); scanOff(); continue; }
    if (pairingNow()) {
      // Classic inquiry (6.4 s) and an active BLE scan (4 s), in turns
      if (!inquiring && !scanning) {
        if (phase == 0) { if (esp_bt_gap_start_discovery(ESP_BT_INQ_MODE_GENERAL_INQUIRY, 5, 0) == ESP_OK) inquiring = true; }
        else scanOn(true, 0x50, 0x30, 4);
        phase ^= 1;
      }
    } else if (bleAway()) {
      // a bonded BLE pad may come back: listen, lightly (30 ms in every 320)
      if (!scanning) { inquiryOff(); scanOn(false, 0x200, 0x30, 30); }
    } else {
      inquiryOff(); scanOff();
    }
  }
}

// a tick into the BTU task while a Classic pad is being set up
static void tickTimer(void *) {
  for (auto &s : S) if (s.used == U_CLASSIC && s.cst == C_UP && (s.step != ST_DONE || s.nameNew)) { post(M_TICK); return; }
}

// --- the outside -----------------------------------------------------------------------------------
static bool begin() {
  esp_err_t e;
  if (esp_bt_controller_get_status() == ESP_BT_CONTROLLER_STATUS_IDLE) {
    esp_bt_controller_config_t cfg = BT_CONTROLLER_INIT_CONFIG_DEFAULT();
    cfg.mode = ESP_BT_MODE_BTDM;
    if ((e = esp_bt_controller_init(&cfg)) != ESP_OK) { ev("controller init: %s", esp_err_to_name(e)); return false; }
  }
  if (esp_bt_controller_get_status() == ESP_BT_CONTROLLER_STATUS_INITED &&
      (e = esp_bt_controller_enable(ESP_BT_MODE_BTDM)) != ESP_OK) { ev("controller enable: %s", esp_err_to_name(e)); return false; }
  if (esp_bluedroid_get_status() == ESP_BLUEDROID_STATUS_UNINITIALIZED && (e = esp_bluedroid_init()) != ESP_OK) {
    ev("bluedroid init: %s", esp_err_to_name(e)); return false;
  }
  if (esp_bluedroid_get_status() != ESP_BLUEDROID_STATUS_ENABLED && (e = esp_bluedroid_enable()) != ESP_OK) {
    ev("bluedroid enable: %s", esp_err_to_name(e)); return false;
  }
  esp_bt_gap_set_device_name("SiSTer console");
  esp_bt_gap_register_callback(gapEvent);
  esp_ble_gap_register_callback(bleGapEvent);
  esp_ble_gattc_register_callback(esp_hidh_gattc_event_handler);
  // pairing: Classic SSP "just works" (no keys, no screen), legacy PIN 0000; BLE bonded, just works
  esp_bt_sp_param_t iocapT = ESP_BT_SP_IOCAP_MODE; esp_bt_io_cap_t iocap = ESP_BT_IO_CAP_NONE;
  esp_bt_gap_set_security_param(iocapT, &iocap, sizeof iocap);
  esp_bt_pin_code_t pin = {};
  esp_bt_gap_set_pin(ESP_BT_PIN_TYPE_VARIABLE, 0, pin);
  esp_ble_auth_req_t auth = ESP_LE_AUTH_REQ_SC_BOND; esp_ble_io_cap_t bio = ESP_IO_CAP_NONE;
  uint8_t keySize = 16, keys = ESP_BLE_ENC_KEY_MASK | ESP_BLE_ID_KEY_MASK;
  esp_ble_gap_set_security_param(ESP_BLE_SM_AUTHEN_REQ_MODE, &auth, 1);
  esp_ble_gap_set_security_param(ESP_BLE_SM_IOCAP_MODE, &bio, 1);
  esp_ble_gap_set_security_param(ESP_BLE_SM_MAX_KEY_SIZE, &keySize, 1);
  esp_ble_gap_set_security_param(ESP_BLE_SM_SET_INIT_KEY, &keys, 1);
  esp_ble_gap_set_security_param(ESP_BLE_SM_SET_RSP_KEY, &keys, 1);
  esp_hidh_config_t hc = {};
  hc.callback = hidhEvent; hc.event_stack_size = 4096; hc.callback_arg = nullptr;
  if ((e = esp_hidh_init(&hc)) != ESP_OK) ev("esp_hidh: %s (no BLE pads)", esp_err_to_name(e));
  // the Classic HID host, in the BTU task
  bd::bta_sys_register(bd::BTA_ID_HH, &btuReg);
  post(M_INIT);
  // reconnecting pads page us: connectable always, discoverable never (we do the calling)
  esp_bt_gap_set_scan_mode(ESP_BT_CONNECTABLE, ESP_BT_NON_DISCOVERABLE);
  // (6 kB: esp_hidh_dev_open runs the GATT discovery on this stack -- ESP-IDF's own example gives it 6 kB)
  xTaskCreatePinnedToCore(finder, "padbt", 6144, nullptr, 2, nullptr, 0);
  esp_timer_create_args_t ta = {};
  ta.callback = tickTimer; ta.name = "padtick";
  esp_timer_handle_t t;
  if (esp_timer_create(&ta, &t) == ESP_OK) esp_timer_start_periodic(t, 50000);
  for (int i = 0; i < 50 && !up; i++) vTaskDelay(pdMS_TO_TICKS(10));
  return up;
}
static void read(int i, Pad &out) {
  portENTER_CRITICAL(&mux);
  out = S[i].pad;
  if (!S[i].used) out.on = false;
  portEXIT_CRITICAL(&mux);
}
static void forget() { req = REQ_FORGET; }
static void setPairing(bool on) { req = on ? REQ_PAIR_ON : REQ_PAIR_OFF; }
// rumble, 0..255 each (DS4, DualSense, Xbox BLE; the Switch's HD rumble is not done)
static void rumble(int i, uint8_t strong, uint8_t weak) {
  if (i < 0 || i >= NSLOT) return;
  Slot &s = S[i];
  if (s.used == U_CLASSIC) {
    if (s.rumbleS == strong && s.rumbleW == weak) return;
    s.rumbleS = strong; s.rumbleW = weak;
    post(M_RUMBLE, i);
  } else if (s.used == U_BLE && s.dev) {
    // output report 3, as SDL sends it: motors enabled, triggers, strong, weak (0..100), duration,
    // delay, repeat
    uint8_t b[8] = { 0x0F, 0, 0, (uint8_t)(strong * 100 / 255), (uint8_t)(weak * 100 / 255), 0xFF, 0x00, 0xEB };
    esp_hidh_dev_output_set(s.dev, 0, 3, b, sizeof b);
  }
}
static void debug(Print &o) {
  static const char *const U[] = { "free", "Classic", "BLE" };
  o.printf("  Bluedroid: %s, pairing %s, inquiry %d, BLE scan %d, BLE bonds %d, Classic bonds %d, internal free %u\n",
           up ? "up" : "DOWN", pairingNow() ? "on" : "off", (int)inquiring, (int)scanning, (int)bleBonded,
           esp_bt_gap_get_bond_device_num(), (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL));
  for (int i = 0; i < NSLOT; i++) {
    Slot &s = S[i];
    o.printf("  BT slot %d: %s", i, U[s.used % 3]);
    if (s.used) o.printf(" %s %s (\"%s\"), state %u step %u, ctrl %04x intr %04x, %lu reports, last 0x%02x/%u, battery %d",
                         mac(s.bda), KIND_NAME[s.pad.kind % 7], s.rname, s.cst, s.step, s.ctrl, s.intr,
                         (unsigned long)s.reports, s.lastId, s.lastLen, s.pad.battery);
    if (s.used == 1 && s.gapN)
      o.printf("\n    reports every %lu us on average, longest gap %lu us (since last asked); link %s",
               (unsigned long)(s.gapSum / s.gapN), (unsigned long)s.gapMax,
               s.pm == 0 ? "active" : s.pm == 2 ? "SNIFF" : s.pm == 1 ? "hold" : "?");
    if (s.used == 1) { s.gapMax = s.gapSum = s.gapN = 0; }
    o.println();
  }
  uint8_t n = evN;
  for (int k = n > 12 ? n - 12 : 0; k < n; k++) o.printf("    %s\n", evLog[k % 12]);
}

}  // namespace padbt
