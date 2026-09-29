"""Read the console's RAM off the board through the DDR3 line window, and
show it as words or as MIPS instructions.
    python tools/ps1ram.py ADDR [N]        N words (default 16) from RAM address ADDR (hex, 0x80xxxxxx or 0x00xxxxxx)
    python tools/ps1ram.py ADDR N dis      ...disassembled
"""
import os, sys, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "pc"))
import fpgalink as fl
N = 0x0008_0000
RAM_LINE = 0x10000

def read_line(link, line):
    link.write(N + 0x7C, line)
    for _ in range(50):
        if link.read(N + 0x7C) >> 31: break
    return [link.read(N + 0x80 + 4 * k) for k in range(4)]

def read_words(link, addr, n):
    out = []
    a = addr & 0x1FFFFF
    while len(out) < n:
        ws = read_line(link, RAM_LINE + (a >> 4))
        k = (a & 15) >> 2
        out += ws[k:]
        a = (a & ~15) + 16
    return out[:n]

REG = "zero at v0 v1 a0 a1 a2 a3 t0 t1 t2 t3 t4 t5 t6 t7 s0 s1 s2 s3 s4 s5 s6 s7 t8 t9 k0 k1 gp sp fp ra".split()
def dis(pc, w):
    op, rs, rt, rd, sa, fn = w >> 26, (w >> 21) & 31, (w >> 16) & 31, (w >> 11) & 31, (w >> 6) & 31, w & 63
    imm = w & 0xFFFF; simm = imm - 0x10000 if imm & 0x8000 else imm
    tgt = (pc + 4 + simm * 4) & 0xFFFFFFFF
    R = lambda i: REG[i]
    if op == 0:
        names = {0:"sll",2:"srl",3:"sra",4:"sllv",6:"srlv",7:"srav",8:"jr",9:"jalr",12:"syscall",16:"mfhi",17:"mthi",18:"mflo",19:"mtlo",
                 24:"mult",25:"multu",26:"div",27:"divu",32:"add",33:"addu",34:"sub",35:"subu",36:"and",37:"or",38:"xor",39:"nor",42:"slt",43:"sltu"}
        n = names.get(fn, "spec%d" % fn)
        if w == 0: return "nop"
        if fn in (0,2,3): return "%s %s,%s,%d" % (n, R(rd), R(rt), sa)
        if fn == 8: return "jr %s" % R(rs)
        if fn == 9: return "jalr %s" % R(rs)
        if fn in (24,25,26,27): return "%s %s,%s" % (n, R(rs), R(rt))
        if fn in (16,18): return "%s %s" % (n, R(rd))
        return "%s %s,%s,%s" % (n, R(rd), R(rs), R(rt))
    if op == 1: return "%s %s,%08x" % ({0:"bltz",1:"bgez",16:"bltzal",17:"bgezal"}.get(rt,"regimm"), R(rs), tgt)
    if op in (2, 3): return "%s %08x" % ("j" if op == 2 else "jal", ((pc + 4) & 0xF0000000) | ((w & 0x3FFFFFF) << 2))
    if op in (4, 5): return "%s %s,%s,%08x" % ("beq" if op == 4 else "bne", R(rs), R(rt), tgt)
    if op in (6, 7): return "%s %s,%08x" % ("blez" if op == 6 else "bgtz", R(rs), tgt)
    imms = {8:"addi",9:"addiu",10:"slti",11:"sltiu",12:"andi",13:"ori",14:"xori"}
    if op in imms: return "%s %s,%s,0x%x" % (imms[op], R(rt), R(rs), imm)
    if op == 15: return "lui %s,0x%x" % (R(rt), imm)
    if op == 16: return "cop0 %08x" % w
    if op == 18: return "cop2 %08x" % w
    mems = {32:"lb",33:"lh",34:"lwl",35:"lw",36:"lbu",37:"lhu",38:"lwr",40:"sb",41:"sh",42:"swl",43:"sw",46:"swr",50:"lwc2",58:"swc2"}
    if op in mems: return "%s %s,%d(%s)" % (mems[op], R(rt), simm, R(rs))
    return ".word %08x" % w

if __name__ == "__main__":
    addr = int(sys.argv[1], 16); n = int(sys.argv[2]) if len(sys.argv) > 2 else 16
    link = fl.Link(fl.DEFAULT_HOST, 5005, timeout=1.0, retries=4)
    ws = read_words(link, addr, n)
    for k, w in enumerate(ws):
        a = (addr & ~3) + 4 * k
        print("%08x: %08x  %s" % (a, w, dis(a, w) if "dis" in sys.argv else ""))
