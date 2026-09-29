"""Talk to the ESP32 over its USB serial port, which works when Wi-Fi does not.

    python tools/esp.py                 just listen for a few seconds
    python tools/esp.py state           ask it what it is
    python tools/esp.py disc            the drive and how many sectors it has served
    python tools/esp.py "disc http://192.168.178.191:8080/api/disc/image"
    python tools/esp.py wstatus         why Wi-Fi is not up
    python tools/esp.py --reset         pulse DTR/RTS to reboot the chip

The web interface is the usual way in; this is the one that still works when
the chip has fallen off the network, which is exactly when you need it.
"""
import os, sys, time, serial

PORT = os.environ.get("ESP_PORT", "COM6")    # ESP_PORT: the ESP32's USB serial port
BAUD = 115200


def main():
    args = [a for a in sys.argv[1:]]
    reset = "--reset" in args
    args = [a for a in args if a != "--reset"]
    cmd = " ".join(args)
    # dsrdtr/rtscts off, and DTR/RTS left alone: on a CH343 they are wired to
    # EN and IO0, and asserting them on open resets the chip or puts it in the
    # bootloader -- which looks exactly like the chip having crashed.
    s = serial.Serial()
    s.port = PORT
    s.baudrate = BAUD
    s.timeout = 0.3
    s.dtr = False
    s.rts = False
    s.open()
    time.sleep(0.2)
    if reset:
        s.setDTR(False); s.setRTS(True); time.sleep(0.1)
        s.setRTS(False); time.sleep(0.3)
        print("(reset pulsed)")
    s.reset_input_buffer()
    if cmd:
        s.write((cmd + "\n").encode())
        s.flush()
    t0 = time.time()
    quiet = 0
    while time.time() - t0 < (12 if (reset or not cmd) else 6):
        line = s.readline()
        if line:
            quiet = 0
            sys.stdout.buffer.write(line)
            sys.stdout.buffer.flush()
        else:
            quiet += 1
            if cmd and not reset and quiet > 6 and time.time() - t0 > 1.5:
                break
    s.close()


if __name__ == "__main__":
    main()
