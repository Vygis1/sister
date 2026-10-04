// usbpad.ino - a USB gamepad on the ESP32-S3's native USB port (the left USB-C on the
// YD-ESP32-23), read as USB host: prints what is plugged in (VID/PID), then the
// D-pad and buttons whenever they change, on the CH343 serial port (115200).
// PS5 DualSense (054C:0CE6) and PS4 DualShock 4 (054C:05C4 / 09CC) reports are
// decoded; anything else has its raw report printed.
//
// The native port only powers a device once the board's USB-OTG solder jumper is
// closed (it joins the two USB-C sockets' VBUS).

#include "usb/usb_host.h"

static usb_host_client_handle_t client;
static volatile uint8_t new_addr = 0;
static volatile bool gone = false;
static usb_device_handle_t dev = nullptr;
static uint16_t vid = 0, pid = 0;

static void host_task(void *) {
	for (;;) {
		uint32_t flags;
		usb_host_lib_handle_events(portMAX_DELAY, &flags);
	}
}

static void client_cb(const usb_host_client_event_msg_t *msg, void *) {
	if (msg->event == USB_HOST_CLIENT_EVENT_NEW_DEV) new_addr = msg->new_dev.address;
	else if (msg->event == USB_HOST_CLIENT_EVENT_DEV_GONE) gone = true;
}

// the NES's view of the pad: bit 0 A, 1 B, 2 Select, 3 Start, 4 Up, 5 Down, 6 Left, 7 Right
static uint8_t last = 0xFF;
static void show(uint8_t hat, bool cross, bool circle, bool square, bool triangle, bool create, bool options) {
	bool up = hat == 7 || hat == 0 || hat == 1, right = hat == 1 || hat == 2 || hat == 3;
	bool down = hat == 3 || hat == 4 || hat == 5, left = hat == 5 || hat == 6 || hat == 7;
	uint8_t nes = (cross || square) << 0 | (circle || triangle) << 1 | create << 2 | options << 3 | up << 4 | down << 5 | left << 6 | right << 7;
	if (nes != last) {
		last = nes;
		Serial.printf("pad: %s%s%s%s%s%s%s%s (NES bits %02X)\n", up ? "UP " : "", down ? "DOWN " : "", left ? "LEFT " : "", right ? "RIGHT " : "",
		              (cross || square) ? "A " : "", (circle || triangle) ? "B " : "", create ? "SELECT " : "", options ? "START " : "", nes);
	}
}

static void xfer_cb(usb_transfer_t *x) {
	if (x->status == USB_TRANSFER_STATUS_COMPLETED && x->actual_num_bytes > 0) {
		const uint8_t *r = x->data_buffer;
		if (vid == 0x054C && pid == 0x0CE6 && r[0] == 0x01 && x->actual_num_bytes >= 11) {
			// DualSense over USB: report 1, byte 8 = hat | square 10 cross 20 circle 40 triangle 80; byte 9 create 10 options 20
			show(r[8] & 0x0F, r[8] & 0x20, r[8] & 0x40, r[8] & 0x10, r[8] & 0x80, r[9] & 0x10, r[9] & 0x20);
		} else if (vid == 0x054C && r[0] == 0x01 && x->actual_num_bytes >= 8) {
			// DualShock 4 over USB: report 1, byte 5 = hat | buttons as above; byte 6 share 10 options 20
			show(r[5] & 0x0F, r[5] & 0x20, r[5] & 0x40, r[5] & 0x10, r[5] & 0x80, r[6] & 0x10, r[6] & 0x20);
		} else {
			static uint32_t t = 0;
			if (millis() - t > 500) {
				t = millis();
				Serial.printf("report (%d bytes):", x->actual_num_bytes);
				for (int i = 0; i < x->actual_num_bytes && i < 16; i++) Serial.printf(" %02X", r[i]);
				Serial.println();
			}
		}
	}
	if (dev && !gone) usb_host_transfer_submit(x);
}

static void open_device(uint8_t addr) {
	if (usb_host_device_open(client, addr, &dev) != ESP_OK) { Serial.println("open failed"); return; }
	const usb_device_desc_t *dd;
	usb_host_get_device_descriptor(dev, &dd);
	vid = dd->idVendor; pid = dd->idProduct;
	Serial.printf("device: VID %04X PID %04X%s\n", vid, pid,
	              (vid == 0x054C && pid == 0x0CE6) ? " (PS5 DualSense)" : (vid == 0x054C) ? " (Sony, PS4 pad?)" : "");
	// the first HID interface's interrupt IN endpoint
	const usb_config_desc_t *cd;
	usb_host_get_active_config_descriptor(dev, &cd);
	const uint8_t *p = (const uint8_t *)cd;
	int iface = -1, cur_if = -1, cur_class = -1; uint8_t ep = 0; uint16_t mps = 64;
	for (int off = 0; off < cd->wTotalLength && p[off] > 0; off += p[off]) {
		if (p[off + 1] == 4) { cur_if = p[off + 2]; cur_class = p[off + 5]; }
		if (p[off + 1] == 5 && cur_class == 3 && iface < 0 && (p[off + 2] & 0x80) && (p[off + 3] & 3) == 3) {
			iface = cur_if; ep = p[off + 2]; mps = p[off + 4] | (p[off + 5] << 8);
		}
	}
	if (iface < 0) { Serial.println("no HID input endpoint"); return; }
	if (usb_host_interface_claim(client, dev, iface, 0) != ESP_OK) { Serial.println("claim failed"); return; }
	usb_transfer_t *x;
	usb_host_transfer_alloc(mps, 0, &x);
	x->device_handle = dev; x->bEndpointAddress = ep; x->callback = xfer_cb; x->context = nullptr; x->num_bytes = mps;
	Serial.printf("HID interface %d, endpoint %02X, %d bytes: reading\n", iface, ep, mps);
	usb_host_transfer_submit(x);
}

void setup() {
	Serial.begin(115200);
	delay(300);
	Serial.println("\nusbpad: waiting for a USB device on the native (left) port");
	usb_host_config_t cfg = {};
	cfg.skip_phy_setup = false;
	cfg.intr_flags = ESP_INTR_FLAG_LEVEL1;
	if (usb_host_install(&cfg) != ESP_OK) Serial.println("usb_host_install failed");
	xTaskCreatePinnedToCore(host_task, "usbh", 4096, nullptr, 2, nullptr, 0);
	usb_host_client_config_t cc = {};
	cc.is_synchronous = false;
	cc.max_num_event_msg = 5;
	cc.async.client_event_callback = client_cb;
	cc.async.callback_arg = nullptr;
	usb_host_client_register(&cc, &client);
}

void loop() {
	usb_host_client_handle_events(client, pdMS_TO_TICKS(10));
	if (new_addr) { uint8_t a = new_addr; new_addr = 0; open_device(a); }
	if (gone) { gone = false; Serial.println("device unplugged"); dev = nullptr; }
	static uint32_t t = 0;
	if (!dev && millis() - t > 3000) { t = millis(); Serial.println("usbpad: nothing on the port yet"); }
}
