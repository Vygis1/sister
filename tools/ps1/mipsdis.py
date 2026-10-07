"""mipsdis.py - a small R3000 disassembler (enough to read a game's code out of RAM)."""
import struct
R = ['zero', 'at', 'v0', 'v1', 'a0', 'a1', 'a2', 'a3', 't0', 't1', 't2', 't3', 't4', 't5', 't6', 't7',
     's0', 's1', 's2', 's3', 's4', 's5', 's6', 's7', 't8', 't9', 'k0', 'k1', 'gp', 'sp', 'fp', 'ra']
def s16(v): return struct.unpack('<h', struct.pack('<H', v & 0xFFFF))[0]
def dis(a, w):
    op = w >> 26; rs = (w >> 21) & 31; rt = (w >> 16) & 31; rd = (w >> 11) & 31; sh = (w >> 6) & 31; fn = w & 63
    imm = s16(w); uimm = w & 0xFFFF
    if w == 0: return 'nop'
    if op == 0:
        n = {0: 'sll', 2: 'srl', 3: 'sra', 4: 'sllv', 6: 'srlv', 7: 'srav', 8: 'jr', 9: 'jalr', 12: 'syscall', 13: 'break',
             16: 'mfhi', 17: 'mthi', 18: 'mflo', 19: 'mtlo', 24: 'mult', 25: 'multu', 26: 'div', 27: 'divu',
             32: 'add', 33: 'addu', 34: 'sub', 35: 'subu', 36: 'and', 37: 'or', 38: 'xor', 39: 'nor', 42: 'slt', 43: 'sltu'}.get(fn, '?%d' % fn)
        if fn in (0, 2, 3): return '%s %s, %s, %d' % (n, R[rd], R[rt], sh)
        if fn in (4, 6, 7): return '%s %s, %s, %s' % (n, R[rd], R[rt], R[rs])
        if fn == 8: return 'jr %s' % R[rs]
        if fn == 9: return 'jalr %s, %s' % (R[rd], R[rs])
        if fn in (16, 18): return '%s %s' % (n, R[rd])
        if fn in (17, 19): return '%s %s' % (n, R[rs])
        if fn in (24, 25, 26, 27): return '%s %s, %s' % (n, R[rs], R[rt])
        return '%s %s, %s, %s' % (n, R[rd], R[rs], R[rt])
    if op == 1:
        return '%s %s, %08x' % ({0: 'bltz', 1: 'bgez', 16: 'bltzal', 17: 'bgezal'}.get(rt, 'regimm?'), R[rs], (a + 4 + imm * 4) & 0xFFFFFFFF)
    if op in (2, 3): return '%s %08x' % ('j' if op == 2 else 'jal', ((a + 4) & 0xF0000000) | ((w & 0x3FFFFFF) << 2))
    if op in (4, 5): return '%s %s, %s, %08x' % ('beq' if op == 4 else 'bne', R[rs], R[rt], (a + 4 + imm * 4) & 0xFFFFFFFF)
    if op in (6, 7): return '%s %s, %08x' % ('blez' if op == 6 else 'bgtz', R[rs], (a + 4 + imm * 4) & 0xFFFFFFFF)
    if op in (8, 9, 10, 11): return '%s %s, %s, %d' % ({8: 'addi', 9: 'addiu', 10: 'slti', 11: 'sltiu'}[op], R[rt], R[rs], imm)
    if op in (12, 13, 14): return '%s %s, %s, 0x%x' % ({12: 'andi', 13: 'ori', 14: 'xori'}[op], R[rt], R[rs], uimm)
    if op == 15: return 'lui %s, 0x%x' % (R[rt], uimm)
    if op == 16:
        return 'cop0 %s %s, $%d' % ({0: 'mfc0', 4: 'mtc0'}.get(rs, '?'), R[rt], rd) if rs < 16 else 'rfe'
    if op == 18:
        if (w >> 25) & 1: return 'cop2 %07x' % (w & 0x1FFFFFF)
        return '%s %s, %s%d' % ({0: 'mfc2', 2: 'cfc2', 4: 'mtc2', 6: 'ctc2'}.get(rs, '?'), R[rt], 'c' if rs in (2, 6) else 'd', rd)
    m = {32: 'lb', 33: 'lh', 34: 'lwl', 35: 'lw', 36: 'lbu', 37: 'lhu', 38: 'lwr', 40: 'sb', 41: 'sh', 42: 'swl', 43: 'sw', 46: 'swr'}
    if op in m: return '%s %s, %d(%s)' % (m[op], R[rt], imm, R[rs])
    if op in (50, 58): return '%s d%d, %d(%s)' % ('lwc2' if op == 50 else 'swc2', rt, imm, R[rs])
    return '.word %08x' % w
