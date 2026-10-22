/* abi_check.c - pads_bluedroid.h re-declares a few of Bluedroid's internal types and constants
 * (they are not in the arduino-esp32 libraries' headers). This compiles Bluedroid's own headers,
 * from the ESP-IDF the platform was built from, next to our copies, and fails if any size, offset
 * or constant differs. Run tools/bt_abi/check.sh after changing the esp32:esp32 platform version.
 * The struct copies below must stay the same as pads_bluedroid.h's namespace bd. */
#include "common/bt_target.h"
#include "stack/bt_types.h"
#include "stack/l2c_api.h"
#include "stack/btm_api.h"
#include "bta/bta_sys.h"
#include "bta/bta_api.h"
#include <stddef.h>
#include <stdbool.h>
#include <stdint.h>
/* our copies (pads_bluedroid.h, namespace bd) */
typedef struct { uint16_t event, len, offset, layer_specific; } my_BT_HDR;
typedef struct { uint8_t qos_flags, service_type; uint32_t token_rate, token_bucket_size, peak_bandwidth, latency, delay_variation; } my_FLOW_SPEC;
typedef struct { uint8_t mode, tx_win_sz, max_transmit; uint16_t rtrans_tout, mon_tout, mps; } my_FCR;
typedef struct { uint8_t id, stype; uint16_t max_sdu_size; uint32_t sdu_inter_time, access_latency, flush_timeout; } my_EXT;
typedef struct {
  uint16_t result; bool mtu_present; uint16_t mtu; bool qos_present; my_FLOW_SPEC qos; bool flush_to_present; uint16_t flush_to;
  bool fcr_present; my_FCR fcr; bool fcs_present; uint8_t fcs; bool ext_flow_spec_present; my_EXT ext_flow_spec; uint16_t flags;
} my_CFG;
typedef struct { void *a[11]; } my_APPL;
typedef struct { void *a, *b; } my_REG;
#define SAME(T, M) _Static_assert(sizeof(T) == sizeof(M), #T " size")
#define OFF(T, f, M, g) _Static_assert(offsetof(T, f) == offsetof(M, g), #T "." #f)
SAME(BT_HDR, my_BT_HDR);
OFF(BT_HDR, event, my_BT_HDR, event); OFF(BT_HDR, len, my_BT_HDR, len); OFF(BT_HDR, offset, my_BT_HDR, offset);
SAME(tL2CAP_CFG_INFO, my_CFG);
OFF(tL2CAP_CFG_INFO, result, my_CFG, result); OFF(tL2CAP_CFG_INFO, mtu_present, my_CFG, mtu_present);
OFF(tL2CAP_CFG_INFO, mtu, my_CFG, mtu); OFF(tL2CAP_CFG_INFO, flush_to_present, my_CFG, flush_to_present);
OFF(tL2CAP_CFG_INFO, flush_to, my_CFG, flush_to); OFF(tL2CAP_CFG_INFO, flags, my_CFG, flags);
SAME(tL2CAP_APPL_INFO, my_APPL);
OFF(tL2CAP_APPL_INFO, pL2CA_ConnectInd_Cb, my_APPL, a[0]); OFF(tL2CAP_APPL_INFO, pL2CA_DataInd_Cb, my_APPL, a[8]);
OFF(tL2CAP_APPL_INFO, pL2CA_TxComplete_Cb, my_APPL, a[10]);
SAME(tBTA_SYS_REG, my_REG);
_Static_assert(L2CAP_MIN_OFFSET == 13, "min offset");
_Static_assert(BTA_ID_HH == 23, "hh id"); _Static_assert(BTA_ID_HH < BTA_ID_MAX, "id max");
_Static_assert(BTM_SEC_SERVICE_HIDH_SEC_CTRL == 32 && BTM_SEC_SERVICE_HIDH_INTR == 34, "service ids");
_Static_assert(BTM_SEC_IN_AUTHENTICATE == 2 && BTM_SEC_IN_ENCRYPT == 4 && BTM_SEC_OUT_AUTHENTICATE == 0x10 && BTM_SEC_OUT_ENCRYPT == 0x20, "sec");
_Static_assert(HCI_ROLE_MASTER == 0 && BT_TRANSPORT_BR_EDR == 1 && L2CAP_CONN_OK == 0 && L2CAP_CONN_NO_RESOURCES == 4 && L2CAP_CFG_OK == 0, "consts");
_Static_assert(L2CAP_UCD_INCLUDED == FALSE, "BTM_SetSecurityLevel takes a BOOLEAN originator");
_Static_assert(HID_HOST_INCLUDED == FALSE || HID_HOST_INCLUDED == 0, "hid host compiled out: BTA slot 23 free");
/* the function prototypes, checked against ours by the compiler */
UINT16 L2CA_Register (UINT16 psm, tL2CAP_APPL_INFO *p_cb_info);
int abi_ok(void) { return CLASSIC_BT_INCLUDED; }
