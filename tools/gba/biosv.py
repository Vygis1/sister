"""The open BIOS (build/dl/gba-bios/bios.bin, Cult-of-GBA, MIT) as rtl/gba_bios_data.vh: the
initial value of gba_top's bios memory, so the console boots with no file on the card.
    python tools/gba/biosv.py
"""
import struct

d = open('build/dl/gba-bios/bios.bin', 'rb').read()
w = struct.unpack('<4096I', d)
out = ["// the open Game Boy Advance BIOS (Cult-of-GBA/BIOS, MIT) as the bios memory's initial value;",
       '// made by tools/gba/biosv.py from build/dl/gba-bios/bios.bin', 'initial begin']
for i in range(0, 4096, 4):
    out.append('	' + ' '.join("bios[%d] = 32'h%08x;" % (i + j, w[i + j]) for j in range(4)))
out.append('end')
open('rtl/gba_bios_data.vh', 'w', newline='').write('\n'.join(out) + '\n')
