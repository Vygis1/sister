#!/usr/bin/env python
"""Rewrite the MIG .prj pin assignments from ddr3.xdc.

ddr3.xdc is the record of the board: which FPGA ball each DDR_* net reaches,
read off the vendor schematic. The MIG carries its own copy of that in its .prj,
because the controller constrains the memory pins itself and the build never
reads ddr3.xdc (constraining them twice is what made the PHY unroutable once
already -- see tools/core.sh).

Two copies of a pinout is one too many. This regenerates the .prj's copy from
the .xdc so there is still exactly one place the numbers are written down.

Editing pins in the MIG wizard instead is what put ddr3_addr[2] on F16 -- a
VCCO_16 power pad -- by inserting one row and shifting eleven address lines
down, which is invisible in a list of 48 near-identical ball names and fatal
at route time.

    python tools/migpins.py          # rewrite in place, report what changed
    python tools/migpins.py --check  # exit 1 if they disagree, change nothing
"""
import re, sys, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
XDC  = ROOT / "boards/qmtech_a100t/ddr3.xdc"
PRJ  = ROOT / "boards/qmtech_a100t/mig_a100t.prj"

# The MIG indexes two signals the .xdc leaves bare.
ALIAS = {"ddr3_ck_p": "ddr3_ck_p[0]", "ddr3_ck_n": "ddr3_ck_n[0]"}

def board_pins():
    """signal name -> package pin, from the schematic record."""
    text = XDC.read_text()
    out = {}
    pat = r"PACKAGE_PIN\s+(\S+)\s+IOSTANDARD\s+(\S+)\s*\}\s*\[get_ports\s*\{([^}]+)\}"
    for pin, _std, name in re.findall(pat, text):
        name = name.strip()
        out[ALIAS.get(name, name)] = pin
    return out

def main():
    check = "--check" in sys.argv
    pins  = board_pins()
    prj   = PRJ.read_text()

    # The memory rail decides the I/O standard, not the .xdc -- which still
    # carries SSTL15 from the older schematic and says so.
    volt = re.search(r"<MemoryVoltage>([\d.]+)V</MemoryVoltage>", prj).group(1)
    std  = {"1.35": "SSTL135", "1.5": "SSTL15"}[volt]

    changed, missing = [], []

    dropped = []

    def fix(m):
        line, name = m.group(0), m.group("name")
        if name.startswith("ddr3_") and name not in pins:
            # A memory signal the board does not route. Leaving it in the .prj
            # hands the controller a pin to allocate for something that does not
            # exist -- which is how ddr3_cs_n ended up on E22, outside every byte
            # group, wrecking the byte lane above it.
            dropped.append(name)
            return ""
        if name not in pins:                       # sys_rst and friends
            return line
        want = pins.pop(name)
        have = re.search(r'PADName="([^"]*)"', line).group(1)
        diff = "_p[" in name or "_n[" in name or name in ("ddr3_ck_p[0]", "ddr3_ck_n[0]")
        wstd = ("DIFF_" if diff else "") + std
        hstd = re.search(r'IOSTANDARD="([^"]*)"', line).group(1)
        if have != want or hstd != wstd:
            changed.append((name, have, want, hstd, wstd))
        line = re.sub(r'PADName="[^"]*"',    f'PADName="{want}"',    line)
        line = re.sub(r'IOSTANDARD="[^"]*"', f'IOSTANDARD="{wstd}"', line)
        return line

    body = re.sub(r'<Pin\b[^/]*name="(?P<name>[^"]+)"\s*/>', fix, prj)
    missing = sorted(pins)                          # in the .xdc, not in the .prj

    for name, have, want, hstd, wstd in changed:
        note = f"{have} -> {want}" if have != want else f"{hstd} -> {wstd}"
        print(f"  {name:18s} {note}")
    for name in dropped:
        print(f"  {name:18s} dropped -- not routed on this board")
    if missing:
        print(f"  *** in ddr3.xdc but not in the .prj: {', '.join(missing)}")

    if not changed and not missing and not dropped:
        print("  pinout already matches ddr3.xdc")
        write_unused(std)      # still regenerate: it may be missing or stale
        return 0
    if check:
        print(f"  *** .prj disagrees with ddr3.xdc in "
              f"{len(changed)+len(missing)+len(dropped)} place(s)")
        return 1
    PRJ.write_text(body)
    print(f"  rewrote {PRJ.relative_to(ROOT)} from ddr3.xdc ({std}, {volt} V rail)")
    write_unused(std)
    return 0


UNUSED = ROOT / "boards/qmtech_a100t/ddr3_unused.xdc"


def write_unused(std):
    """Constraints for the cores that have no memory controller in them.

    eth_top declares the DDR3 ports whether or not MD_DDR3 is set -- Verilog has
    no way to make a port list conditional -- so every core carries them. The
    Mega Drive gets them constrained by the controller's own .xdc. Nothing else
    includes that file, which leaves 27 output ports with no LOC and no
    IOSTANDARD, and write_bitstream refuses:

        ERROR: [DRC UCIO-1] Unconstrained Logical Port: 27 out of 39 ...

    So the NES and Master System cores stopped building the day DDR3 arrived,
    and the failure is at the very last step, twenty minutes in, naming pins
    that have nothing to do with the console being built.

    The pins are the same pins; only the source differs. Ports that synthesis
    trimmed (the bidirectional dq and dqs, undriven in these cores) are skipped
    rather than named, because constraining a port that no longer exists is an
    error of its own.
    """
    pins = board_pins()
    # Only the ports that survive in a core with no controller. The sixteen dq
    # and the two dqs pairs are bidirectional and nothing drives them here, so
    # synthesis trims them away -- and set_property on a port that no longer
    # exists is an error. What is left is exactly the 27 outputs DRC asks for.
    skip = ("ddr3_dq[", "ddr3_dqs_p[", "ddr3_dqs_n[")
    out = [
        "# Generated by tools/migpins.py from ddr3.xdc -- do not edit.",
        "#",
        "# For cores built WITHOUT the memory controller. eth_top declares the DDR3",
        "# ports whether or not MD_DDR3 is set, so every core has 27 output pins to",
        "# place; only the Mega Drive gets them from the controller's own .xdc.",
        "# Without this, write_bitstream stops on DRC UCIO-1 after a full run.",
        "#",
        "# The Mega Drive must NOT read this file. Constraining these pins twice is",
        "# what makes the PHY's byte-lane clocking unroutable.",
        "#",
        "# Plain set_property only. An XDC is Tcl, and an `if` in one runs the",
        "# moment the file is parsed -- before the design exists -- so get_ports",
        "# finds nothing, every branch is skipped, and the constraints silently do",
        "# not happen. set_property is deferred and resolved against the elaborated",
        "# design, which is why the rest of this tree's XDC files work.",
        "",
    ]
    # Every one of these is single-ended HERE, ck_p and ck_n included. eth_top
    # declares them as two separate 1-bit ports; it is the controller that turns
    # them into a pair by instantiating an OBUFDS. With no controller there is
    # no buffer, so asking for DIFF_SSTL135 gets:
    #
    #   [DRC IOSTDTYPE-1] port ddr3_ck_p[0] is Single-Ended but has an
    #   IOStandard of DIFF_SSTL135 which can only support Differential
    #
    # They are static outputs into a DRAM this core holds in reset, so a plain
    # SSTL135 level on each is exactly right.
    for name, pin in sorted(pins.items()):
        if name.startswith(skip):
            continue
        out.append(f"set_property -dict {{PACKAGE_PIN {pin} IOSTANDARD {std}}} "
                   f"[get_ports {{{name}}}]")
    UNUSED.write_text(chr(10).join(out) + chr(10))
    n = sum(1 for k in pins if not k.startswith(skip))
    print(f"  wrote {UNUSED.relative_to(ROOT)} ({n} output pins, {std})")

if __name__ == "__main__":
    sys.exit(main())
