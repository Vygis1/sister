// usbprobe.ino - is a USB device on GPIO19/20 at all? Reads the two USB pins as plain
// inputs: a powered full-speed device pulls D+ to ~3.3 V through 1.5k, which beats the
// ESP32's weak internal pull-down -- so with pull-downs on, the D+ pin reads 1 and D-
// reads 0. Both 0: the device has no power, or the wires do not reach it.

void show(const char *what) {
	delay(20);
	Serial.printf("  %-26s GPIO19 = %d   GPIO20 = %d\n", what, digitalRead(19), digitalRead(20));
}

void setup() {
	Serial.begin(115200);
	delay(500);
}

void loop() {
	Serial.println("usbprobe:");
	pinMode(19, INPUT_PULLDOWN); pinMode(20, INPUT_PULLDOWN); show("pull-downs on (as a host)");
	pinMode(19, INPUT_PULLUP);   pinMode(20, INPUT_PULLUP);   show("pull-ups on");
	pinMode(19, INPUT);          pinMode(20, INPUT);          show("floating");
	delay(2000);
}
