"""Which RDP features a game uses, and how much: Super Mario 64 run in the
model (tools/n64/n64model.py, with tools/n64/n64rdp.py drawing), every primitive it
draws recorded with the RDP's state at the time, weighted by its pixels.

    python tools/n64/n64rdpcensus.py [--rom ROM] [--frames N] [--out DIR]
                                 [--snap-every N] [--resume SNAPSHOT]
                                 [--inputs SCHEDULE] [--phases PHASES]
    python tools/n64/n64rdpcensus.py --report-only DIR/sm64_census.json [--phases PHASES]

Nothing in the model is changed: the census wraps the RDP object's execute()
and draw_primitive() at runtime, and a handful of n64rdp's per-pixel stage
functions (compute_coverage, sample_texture, compute_lod, depth_test,
store_color, store_depth), which the pixel loop looks up by name.

The model's CPU is far slower than the real one against the VI's clock (about
105k instructions a VI frame), so SM64 runs at one game frame per 2-30 VI
frames here instead of one per two: emulated seconds mean little, and the
per-frame figures are per game frame (between two SYNC_FULLs). A game frame
costs 5-20 s of wall time; power-on to Mario in the castle grounds is hours.
Do not give the cartridge an EEPROM (--eeprom): with one the game stalls
before it draws anything (a model issue, not looked into).

What a primitive's "pixels" are, as the measures in the tables:
  px      the pixels that reach the memory stage: in 1/2-cycle mode, those
          with coverage that pass the alpha compare (the depth test comes
          after); in fill and copy mode, every pixel of the spans
          (rdp.pixels, as the model counts it)
  span    the pixels the rasteriser walks: every x of every span (1/2-cycle:
          compute_coverage calls; fill/copy: = px)
  written colour writes that happened (after the depth test, coverage, alpha)

The controller: n64pif.Joybus.pads[0] is the word a controller read returns
(buttons in [31:16] -- A B Z Start Up Down Left Right, -, -, L R CU CD CL CR --
then the stick's X and Y as signed bytes). --inputs is a schedule of
"FRAME+LEN=BUTTONS[@X/Y][~PERIOD:UNTIL]" items, comma separated (VI frames;
BUTTONS joined with '|' from A B Z START UP DOWN LEFT RIGHT L R CU CD CL CR,
or '-' for none; ~ repeats the item every PERIOD frames until UNTIL). The
game reads the controller once a game frame, so a press must be held for
many VI frames. The default schedule is the one that walks SM64 from the
title into the castle grounds.

--snap-dir/--snap-every/--snap-at pickle the whole machine and the census so
far; --resume carries on from such a snapshot (give it the same --inputs).

Output, in --out (default build/n64rdp): sm64_census.json (the raw counts, by
one-second segment, plus every game frame and VI frame), sm64_census.md (the
report), census/sm64_NNNN.png (the VI's picture every --png-every frames).
--phases names the frame ranges for the report ("name:FRAME,name:FRAME,...",
each phase running to the next); --report-only rewrites the report from the
JSON with new phases.
"""
import argparse
import collections
import json
import os
import pickle
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import n64model  # noqa: E402
import n64rdp    # noqa: E402
import n64rdptests  # noqa: E402  (vi_picture, save_picture)

ROM = os.path.join(HERE, '..', '..', 'sim', 'roms', 'n64', 'games', 'sm64.z64')
OUT = os.path.join(HERE, '..', '..', 'build', 'n64rdp')

BUTTONS = dict(A=31, B=30, Z=29, START=28, UP=27, DOWN=26, LEFT=25, RIGHT=24,
               L=21, R=20, CU=19, CD=18, CL=17, CR=16)

# The default walk from power-on into the game (VI frames as the model counts
# them): START on Mario's face; A on the file-select screen (the hand starts on
# MARIO A); A tapped every 120 frames from then on (the intro ignores it), and
# from frame 8000 the stick held forward with a C-left now and then, for Mario
# in the castle grounds. In the model the run never gets there: the RSP's
# graphics task runs away during the Lakitu fly-in (about VI frame 7530) and the
# game waits for that frame forever, so --frames stops at 7800 by default.
DEFAULT_INPUTS = '1960+6=START,2526+40=A,2800+40=A~120:40000,8000+30000=-@0/60,8300+20=CL~600:40000'
DEFAULT_PHASES = ('boot:0,logo:420,face:1500,file_select:2160,intro_peach:2760,intro_lakitu:5940,'
                  'hung:7560,gameplay:100000')

# --- names -----------------------------------------------------------------------------------
CC_RGB_A = {0: 'COMBINED', 1: 'TEXEL0', 2: 'TEXEL1', 3: 'PRIM', 4: 'SHADE', 5: 'ENV', 6: '1', 7: 'NOISE'}
CC_RGB_B = {0: 'COMBINED', 1: 'TEXEL0', 2: 'TEXEL1', 3: 'PRIM', 4: 'SHADE', 5: 'ENV', 6: 'KEY_CENTER', 7: 'K4'}
CC_RGB_C = {0: 'COMBINED', 1: 'TEXEL0', 2: 'TEXEL1', 3: 'PRIM', 4: 'SHADE', 5: 'ENV', 6: 'KEY_SCALE',
            7: 'COMBINED_A', 8: 'TEXEL0_A', 9: 'TEXEL1_A', 10: 'PRIM_A', 11: 'SHADE_A', 12: 'ENV_A',
            13: 'LOD_FRAC', 14: 'PRIM_LOD_FRAC', 15: 'K5'}
CC_RGB_D = {0: 'COMBINED', 1: 'TEXEL0', 2: 'TEXEL1', 3: 'PRIM', 4: 'SHADE', 5: 'ENV', 6: '1', 7: '0'}
CC_A_ABD = {0: 'COMBINED', 1: 'TEXEL0', 2: 'TEXEL1', 3: 'PRIM', 4: 'SHADE', 5: 'ENV', 6: '1', 7: '0'}
CC_A_C = {0: 'LOD_FRAC', 1: 'TEXEL0', 2: 'TEXEL1', 3: 'PRIM', 4: 'SHADE', 5: 'ENV', 6: 'PRIM_LOD_FRAC', 7: '0'}
BL_P = ('PIXEL', 'MEMORY', 'BLEND_COLOR', 'FOG_COLOR')
BL_A = ('PIXEL_A', 'FOG_A', 'SHADE_A', '0')
BL_B = ('1-A', 'MEMORY_CVG', '1', '0')
FMT = ('RGBA', 'YUV', 'CI', 'IA', 'I', 'fmt5', 'fmt6', 'fmt7')
SIZE = ('4b', '8b', '16b', '32b')
CYCLE = ('1cycle', '2cycle', 'copy', 'fill')
FB_NAME = {n64rdp.FB_I4: 'I4', n64rdp.FB_I8: 'I8', n64rdp.FB_RGBA5551: 'RGBA5551', n64rdp.FB_IA88: 'IA88',
           n64rdp.FB_RGBA8888: 'RGBA8888'}
OPS = {0x00: 'NOP', 0x08: 'TRI_FILL', 0x09: 'TRI_FILL_Z', 0x0A: 'TRI_TEX', 0x0B: 'TRI_TEX_Z', 0x0C: 'TRI_SHADE',
       0x0D: 'TRI_SHADE_Z', 0x0E: 'TRI_SHADE_TEX', 0x0F: 'TRI_SHADE_TEX_Z', 0x24: 'TEX_RECT',
       0x25: 'TEX_RECT_FLIP', 0x26: 'SYNC_LOAD', 0x27: 'SYNC_PIPE', 0x28: 'SYNC_TILE', 0x29: 'SYNC_FULL',
       0x2A: 'SET_KEY_GB', 0x2B: 'SET_KEY_R', 0x2C: 'SET_CONVERT', 0x2D: 'SET_SCISSOR', 0x2E: 'SET_PRIM_DEPTH',
       0x2F: 'SET_OTHER_MODES', 0x30: 'LOAD_TLUT', 0x32: 'SET_TILE_SIZE', 0x33: 'LOAD_BLOCK', 0x34: 'LOAD_TILE',
       0x35: 'SET_TILE', 0x36: 'FILL_RECT', 0x37: 'SET_FILL_COLOR', 0x38: 'SET_FOG_COLOR',
       0x39: 'SET_BLEND_COLOR', 0x3A: 'SET_PRIM_COLOR', 0x3B: 'SET_ENV_COLOR', 0x3C: 'SET_COMBINE',
       0x3D: 'SET_TEXTURE_IMAGE', 0x3E: 'SET_MASK_IMAGE', 0x3F: 'SET_COLOR_IMAGE'}
DITHER_RGB = ('magic square', 'bayer', 'noise', 'none')
DITHER_A = ('pattern', '~pattern', 'noise', 'none')
Z_MODE = ('opaque', 'interpenetrating', 'transparent', 'decal')
CVG_DEST = ('clamp', 'wrap', 'zap (full)', 'save')


def cc_cycle(c):
    """one combiner cycle as text, and the inputs it reads"""
    ra, rb, rc, rd = CC_RGB_A.get(c[0], '0'), CC_RGB_B.get(c[1], '0'), CC_RGB_C.get(c[2], '0'), CC_RGB_D[c[3]]
    aa, ab, ac, ad = CC_A_ABD[c[4]], CC_A_ABD[c[5]], CC_A_C[c[6]], CC_A_ABD[c[7]]
    text = '(%s-%s)*%s+%s / (%s-%s)*%s+%s' % (ra, rb, rc, rd, aa, ab, ac, ad)
    used = set()
    if rc != '0' and ra != rb:
        used.update((ra, rb))
    used.update((rc, rd))
    if ac != '0' and aa != ab:
        used.update(('A:' + aa, 'A:' + ab))
    used.update(('A:' + ac, 'A:' + ad))
    used = {u for u in used if u not in ('0', '1', 'A:0', 'A:1')}
    return text, used


def bl_cycle(m):
    return '%s*%s + %s*%s' % (BL_P[m[0]], BL_A[m[1]], BL_P[m[2]], BL_B[m[3]])


def size_bucket(n):
    for lim, name in ((0, '0'), (8, '1-8'), (32, '9-32'), (128, '33-128'), (512, '129-512'),
                      (2048, '513-2048'), (8192, '2049-8192')):
        if n <= lim:
            return name
    return '>8192'


def load_bucket(n):
    for lim in (16, 64, 256, 1024, 2048, 4096):
        if n <= lim:
            return '<=%d' % lim
    return '>4096'


# --- the census ----------------------------------------------------------------------------------
class Census:
    """the counts; .hook(m) wraps the model's RDP"""

    def __init__(self):
        self.segments = []                  # per SEG VI frames: {'vi': first, 'cats': ..., 'loads': ...}
        self.seg = None
        self.game_frames = []               # one per SYNC_FULL
        self.vi_frames = []                 # one per VI frame
        self.gf = self.new_frame()
        self.vf = self.new_frame()
        self.raw_tiles = [dict(cms=0, cmt=0, mask_s=0, mask_t=0, shift_s=0, shift_t=0) for _ in range(8)]
        self.op = 0
        self.vi = 0

    SEG = 60

    @staticmethod
    def new_frame():
        return dict(prims=0, tris=0, rects=0, fills=0, px=0, span=0, written=0, rows=0, tmem_bytes=0,
                    loads=0, clocks=0, zwrites=0, cmds=0, blended=0)

    def segment(self, vi):
        s = vi // self.SEG
        if self.seg is None or self.seg['n'] != s:
            self.seg = dict(n=s, vi=s * self.SEG, cats={}, loads={})
            self.segments.append(self.seg)
        return self.seg

    def add(self, cat, key, prims, px, span, written):
        d = self.seg['cats'].setdefault(cat, {})
        v = d.get(key)
        if v is None:
            d[key] = [prims, px, span, written]
        else:
            v[0] += prims; v[1] += px; v[2] += span; v[3] += written

    def add_load(self, cat, key, texels, nbytes):
        d = self.seg['loads'].setdefault(cat, {})
        v = d.get(key)
        if v is None:
            d[key] = [1, texels, nbytes]
        else:
            v[0] += 1; v[1] += texels; v[2] += nbytes

    def vi_tick(self, vi):
        """a new VI frame begins"""
        self.vf['vi'] = self.vi
        self.vi_frames.append(self.vf)
        self.vf = self.new_frame()
        self.vi = vi
        self.segment(vi)

    # --- the hooks --------------------------------------------------------------------------------
    def hook(self, m):
        rdp = m.rdp
        cen = self
        self.segment(m.vi_frames)
        self.vi = m.vi_frames
        orig_execute = n64rdp.RDP.execute.__get__(rdp)
        orig_draw = n64rdp.RDP.draw_primitive.__get__(rdp)
        tile_index = {id(t): i for i, t in enumerate(rdp.tiles)}
        cnt = self.cnt = [0] * 8           # coverage calls, stores, z stores, blends, z fails, lod calls
        samples = self.samples = [0] * 8
        lod_pairs = self.lod_pairs = collections.Counter()

        def execute(op, w):
            cen.op = op
            cen.gf['cmds'] += 1
            cen.vf['cmds'] += 1
            cen.add('opcode', OPS.get(op, 'op%02X' % op), 1, 0, 0, 0)
            if op == 0x35:                                  # SET_TILE: the raw clamp/mirror bits
                rt = cen.raw_tiles[(w[1] >> 24) & 7]
                rt['cms'] = (w[1] >> 8) & 3
                rt['cmt'] = (w[1] >> 18) & 3
                rt['mask_s'] = (w[1] >> 4) & 15
                rt['mask_t'] = (w[1] >> 14) & 15
                rt['shift_s'] = w[1] & 15
                rt['shift_t'] = (w[1] >> 10) & 15
            elif op in (0x30, 0x33, 0x34):
                cen.record_load(rdp, op, w)
            r = orig_execute(op, w)
            if op == 0x29:
                cen.gf['vi'] = cen.vi
                cen.game_frames.append(cen.gf)
                cen.gf = cen.new_frame()
            return r

        def draw_primitive(t, a):
            p0 = rdp.pixels
            c0 = list(cnt)
            s0 = list(samples)
            lod_pairs.clear()
            orig_draw(t, a)
            px = rdp.pixels - p0
            d = [cnt[i] - c0[i] for i in range(8)]
            ds = [samples[i] - s0[i] for i in range(8)]
            cen.record_prim(rdp, t, px, d, ds, dict(lod_pairs))

        rdp.execute = execute
        rdp.draw_primitive = draw_primitive

        # the per-pixel stage functions, by name in n64rdp's namespace
        if not hasattr(n64rdp, '_census_orig'):
            n64rdp._census_orig = {k: getattr(n64rdp, k) for k in
                                   ('compute_coverage', 'store_color', 'store_depth', 'sample_texture',
                                    'compute_lod', 'depth_test', 'blender')}
        o = n64rdp._census_orig

        def compute_coverage(xl, xr, x, _f=o['compute_coverage']):
            cnt[0] += 1
            return _f(xl, xr, x)

        def store_color(*args, _f=o['store_color']):
            cnt[1] += 1
            return _f(*args)

        def store_depth(*args, _f=o['store_depth']):
            cnt[2] += 1
            return _f(*args)

        def sample_texture(tm, tile, *args, _f=o['sample_texture']):
            samples[tile_index.get(id(tile), 0)] += 1
            return _f(tm, tile, *args)

        def compute_lod(tile0, tile1, *args, _f=o['compute_lod']):
            r = _f(tile0, tile1, *args)
            lod_pairs[(r[0], r[1])] += 1
            return r

        def depth_test(*args, _f=o['depth_test']):
            r = _f(*args)
            if not r[0]:
                cnt[4] += 1
            elif r[2]:
                cnt[3] += 1                                  # blend enabled for this pixel
            return r

        n64rdp.compute_coverage = compute_coverage
        n64rdp.store_color = store_color
        n64rdp.store_depth = store_depth
        n64rdp.sample_texture = sample_texture
        n64rdp.compute_lod = compute_lod
        n64rdp.depth_test = depth_test

    def unhook(self, m):
        for k in ('execute', 'draw_primitive'):
            m.rdp.__dict__.pop(k, None) if hasattr(m.rdp, '__dict__') else None
        for k, f in getattr(n64rdp, '_census_orig', {}).items():
            setattr(n64rdp, k, f)

    def __getstate__(self):
        d = dict(self.__dict__)
        for k in ('cnt', 'samples', 'lod_pairs', 'seg'):
            d.pop(k, None)
        d['seg_n'] = self.seg['n'] if self.seg else None
        return d

    def __setstate__(self, d):
        n = d.pop('seg_n')
        self.__dict__.update(d)
        self.seg = self.segments[-1] if self.segments and self.segments[-1]['n'] == n else None

    # --- recording --------------------------------------------------------------------------------
    def record_load(self, rdp, op, w):
        tile = (w[1] >> 24) & 7
        slo, tlo = (w[0] >> 12) & 0xFFF, w[0] & 0xFFF
        shi, thi = (w[1] >> 12) & 0xFFF, w[1] & 0xFFF
        addr, width, ifmt, isize = rdp.timg
        meta = rdp.tiles[tile]
        if op == 0x33:
            kind = 'LOAD_BLOCK'
            texels = max(0, ((shi - slo) & 0xFFF) + 1)
            extra = 'dxt=%s' % ('0' if thi == 0 else 'set')
        elif op == 0x34:
            kind = 'LOAD_TILE'
            texels = max(0, ((shi >> 2) - (slo >> 2) + 1)) * max(0, ((thi >> 2) - (tlo >> 2) + 1))
            extra = ''
        else:
            kind = 'LOAD_TLUT'
            texels = max(0, ((shi >> 2) - (slo >> 2) + 1)) * max(0, ((thi >> 2) - (tlo >> 2) + 1))
            extra = ''
        nbytes = (texels << isize) >> 1           # bytes read from RDRAM (4/8/16/32-bit texels)
        key = '%s img %s%s -> tile %s%s' % (kind, FMT[ifmt], SIZE[isize], FMT[meta.fmt], SIZE[meta.size])
        self.add_load('load_kind', key, texels, nbytes)
        self.add_load('load_size', '%s texels %s' % (kind, load_bucket(texels)), texels, nbytes)
        if extra:
            self.add_load('load_block_dxt', '%s %s' % (kind, extra), texels, nbytes)
        for fr in (self.gf, self.vf):
            fr['tmem_bytes'] += nbytes
            fr['loads'] += 1

    def tile_desc(self, rdp, i):
        tl = rdp.tiles[i]
        return '%s%s' % (FMT[tl.fmt], SIZE[tl.size])

    def tile_dims(self, rdp, i):
        tl = rdp.tiles[i]
        w = ((tl.shi >> 2) - (tl.slo >> 2)) + 1
        h = ((tl.thi >> 2) - (tl.tlo >> 2)) + 1
        return '%dx%d' % (w, h)

    def wrap_desc(self, i, axis):
        rt = self.raw_tiles[i]
        cm = rt['cm' + axis]
        mask = rt['mask_' + axis]
        shift = rt['shift_' + axis]
        parts = []
        if cm & 2:
            parts.append('clamp')
        if cm & 1:
            parts.append('mirror')
        if mask == 0:
            parts.append('mask0(clamp)')
        else:
            parts.append('wrap mask=%d' % mask if not cm & 1 else 'mask=%d' % mask)
        parts.append('shift=%d' % shift if shift else 'no shift')
        return ' '.join(parts)

    def record_prim(self, rdp, t, px, d, ds, lod_pairs):
        op = self.op
        om0, om1 = rdp.om0, rdp.om1
        cyc = (om0 >> 20) & 3
        fill_copy = cyc >= 2
        if fill_copy:
            span = px
        else:
            span = d[0]
        written = px if cyc == 3 else d[1]
        add = self.add

        def A(cat, key):
            add(cat, key, 1, px, span, written)

        is_tri = 0x08 <= op <= 0x0F
        cmd = OPS.get(op, 'op%02X' % op)
        sc = rdp.scissor
        ylo = max(t.yh, sc[1]) >> 2
        yhi = min(t.yl - 1, sc[3] - 1) >> 2
        rows = max(0, yhi - ylo + 1) if rdp.fb_width else 0
        # clocks of an ideal pipeline: a pixel a clock in 1-cycle, two in 2-cycle,
        # 64 bits a clock in fill and copy
        fbsize = {n64rdp.FB_I4: 0.5, n64rdp.FB_I8: 1, n64rdp.FB_RGBA5551: 2, n64rdp.FB_IA88: 2,
                  n64rdp.FB_RGBA8888: 4}[rdp.fb_fmt]
        clocks = span * (1, 2)[cyc] if cyc < 2 else span * fbsize / 8.0
        for fr in (self.gf, self.vf):
            fr['prims'] += 1
            fr['tris'] += is_tri
            fr['rects'] += op in (0x24, 0x25)
            fr['fills'] += op == 0x36
            fr['px'] += px
            fr['span'] += span
            fr['written'] += written
            fr['rows'] += rows
            fr['clocks'] += clocks
            fr['zwrites'] += d[2]
            fr['blended'] += d[3]
        A('command', cmd)
        A('cycle', CYCLE[cyc])
        A('command x cycle', '%s %s' % (cmd, CYCLE[cyc]))
        A('primitive size (px)', '%s %s' % ('tri' if is_tri else 'rect', size_bucket(px)))
        is_z = rdp.fb_addr == rdp.z_addr
        A('framebuffer', '%s w%d%s' % (FB_NAME[rdp.fb_fmt], rdp.fb_width, ' (= Z image: Z clear)' if is_z else ''))
        A('color image address', '%06X%s' % (rdp.fb_addr, ' (Z)' if is_z else ''))
        A('scissor', '%d,%d-%d,%d%s' % (sc[0] >> 2, sc[1] >> 2, sc[2] >> 2, sc[3] >> 2,
                                        ' field' if rdp.scissor_field else ''))
        add('pixel counts', 'z-test fails (1/2-cycle)', 0, d[4], 0, 0)
        add('pixel counts', 'blend enabled (1/2-cycle)', 0, d[3], 0, 0)
        add('pixel counts', 'z writes', 0, d[2], 0, 0)
        if px == 0:
            A('zero-pixel primitives', '%s %s' % (cmd, 'offscreen/scissored/thin' if rows == 0 else 'no covered pixels'))
        if cyc == 3:
            A('fill', 'fill color %s' % ('32-bit pattern' if (rdp.fill_color >> 16) != (rdp.fill_color & 0xFFFF)
                                         else '16-bit repeated'))
            return
        f = rdp.static_flags(t.tile & 7)
        # --- texture ------------------------------------------------------------------------
        tiles_used = []
        if cyc == 2:
            tiles_used = [t.tile & 7]
            A('copy', 'copy %s%s' % (self.tile_desc(rdp, t.tile & 7), ' TLUT' if f & n64rdp.R_TLUT else ''))
            A('copy', 'copy alpha compare' if f & n64rdp.R_ALPHA_TEST else 'copy no alpha compare')
        sampled = [(i, ds[i]) for i in range(8) if ds[i]]
        if cyc < 2:
            for i, n in sampled:
                tiles_used.append(i)
        textured = cyc == 2 or bool(f & (n64rdp.R_USES_TEXEL0 | n64rdp.R_USES_TEXEL1 | n64rdp.R_USES_PIPELINED_TEXEL1))
        A('textured', 'textured' if textured else 'untextured')
        if cyc < 2 and textured:
            # the tile descriptors sampled, weighted by samples
            tot = sum(n for _, n in sampled) or 1
            for i, n in sampled:
                w_px = px * n / tot
                w_sp = span * n / tot
                w_wr = written * n / tot
                for cat, key in (('texture format', self.tile_desc(rdp, i)),
                                 ('texture size (tile texels)', '%s %s' % (self.tile_desc(rdp, i), self.tile_dims(rdp, i))),
                                 ('texture wrap S', self.wrap_desc(i, 's')),
                                 ('texture wrap T', self.wrap_desc(i, 't')),
                                 ('tile index sampled', 'tile %d' % i)):
                    add(cat, key, 0, w_px, w_sp, w_wr)
                add('texel samples', 'samples (texel fetch groups)', 0, n, 0, 0)
            t0 = (t.tile & 7)
            uses0 = bool(f & n64rdp.R_USES_TEXEL0)
            uses1 = bool(f & (n64rdp.R_USES_TEXEL1 | n64rdp.R_USES_PIPELINED_TEXEL1))
            combo = '%s / %s' % (self.tile_desc(rdp, t0) if uses0 else '-',
                                 ('pipelined(=next TEXEL0)' if f & n64rdp.R_USES_PIPELINED_TEXEL1 else
                                  self.tile_desc(rdp, (t0 + 1) & 7)) if uses1 else '-')
            A('texel0 / texel1', combo)
            A('texel0 / texel1 tiles', 'tile %d%s' % (t0, ' + tile %d' % ((t0 + 1) & 7)
                                                         if f & n64rdp.R_USES_TEXEL1 else ''))
            filt = ('point', 'point+mid', 'bilinear', 'average (bilinear+mid-texel)')[(om0 >> 12) & 3]
            A('texture filter', filt)
            A('texture convert (bilerp0 bilerp1 convert_one)', 'bilerp0=%d bilerp1=%d convert_one=%d'
              % ((om0 >> 11) & 1, (om0 >> 10) & 1, (om0 >> 9) & 1))
            A('perspective', 'on' if om0 >> 19 & 1 else 'off')
            A('tlut', ('off' if not om0 >> 15 & 1 else 'on, %s' % ('IA16' if om0 >> 14 & 1 else 'RGBA16')))
            A('lod / sharpen / detail', 'tex_lod=%d sharpen=%d detail=%d max_level=%d'
              % ((om0 >> 16) & 1, (om0 >> 17) & 1, (om0 >> 18) & 1, t.tile >> 3))
            A('lod frac needed', 'yes' if f & n64rdp.R_USES_LOD else 'no')
            for (a_, b_), n in lod_pairs.items():
                add('lod tile choice (per pixel)', 'tile %d / tile %d' % (a_, b_), 0, n, 0, 0)
            A('distinct tile configs (texel0)', '%s %s mask %d/%d shift %d/%d cm %d/%d pal %d'
              % (self.tile_desc(rdp, t0), self.tile_dims(rdp, t0), self.raw_tiles[t0]['mask_s'],
                 self.raw_tiles[t0]['mask_t'], self.raw_tiles[t0]['shift_s'], self.raw_tiles[t0]['shift_t'],
                 self.raw_tiles[t0]['cms'], self.raw_tiles[t0]['cmt'], rdp.tiles[t0].palette))
        if cyc == 2:
            for cat, key in (('texture format', self.tile_desc(rdp, t.tile & 7)),
                             ('texture size (tile texels)', '%s %s' % (self.tile_desc(rdp, t.tile & 7),
                                                                       self.tile_dims(rdp, t.tile & 7))),
                             ('texture wrap S', self.wrap_desc(t.tile & 7, 's')),
                             ('texture wrap T', self.wrap_desc(t.tile & 7, 't'))):
                A(cat, key)
            A('tlut', ('off' if not om0 >> 15 & 1 else 'on, %s' % ('IA16' if om0 >> 14 & 1 else 'RGBA16')))
            A('perspective', 'on' if om0 >> 19 & 1 else 'off')
            return
        # --- combiner --------------------------------------------------------------------------
        c0, c1 = rdp.comb
        t1, u1 = cc_cycle(c1)
        if cyc == 1:
            t0_, u0 = cc_cycle(c0)
            A('combiner', '2cyc: %s || %s' % (t0_, t1))
            used = {'c0:' + u for u in u0} | {'c1:' + u for u in u1}
        else:
            A('combiner', '1cyc: %s' % t1)
            used = {u for u in u1}
        for u in sorted(used):
            A('combiner inputs', u)
        flat = {u.split(':', 1)[-1] for u in used}
        flat = {u[2:] if u.startswith('A:') else u for u in flat}
        for u in sorted(flat):
            A('combiner inputs (either cycle, rgb or alpha)', u)
        A('chroma key enable', 'on' if om0 >> 8 & 1 else 'off')
        # --- blender, coverage, z ------------------------------------------------------------------
        bm0 = ((om1 >> 30) & 3, (om1 >> 26) & 3, (om1 >> 22) & 3, (om1 >> 18) & 3)
        bm1 = ((om1 >> 28) & 3, (om1 >> 24) & 3, (om1 >> 20) & 3, (om1 >> 16) & 3)
        bl = bl_cycle(bm0) if cyc == 0 else '%s || %s' % (bl_cycle(bm0), bl_cycle(bm1))
        A('blender', '%s %s' % (CYCLE[cyc], bl))
        modes = [bm0] if cyc == 0 else [bm0, bm1]
        fogs = set()
        for m_ in modes:
            if m_[0] == 3 or m_[2] == 3:
                fogs.add('FOG_COLOR')
            if m_[1] == 1:
                fogs.add('FOG_A')
            if m_[1] == 2:
                fogs.add('SHADE_A as factor')
            if m_[0] == 2 or m_[2] == 2:
                fogs.add('BLEND_COLOR')
            if m_[0] == 1 or m_[2] == 1 or m_[3] == 1:
                fogs.add('MEMORY')
        for k in sorted(fogs) or ['none']:
            A('blender inputs', k)
        A('force_blend', 'on' if om1 >> 14 & 1 else 'off')
        A('image_read_en', 'on' if om1 >> 6 & 1 else 'off')
        A('antialias', 'on' if om1 >> 3 & 1 else 'off')
        A('cvg_dest', CVG_DEST[(om1 >> 8) & 3])
        A('color_on_cvg', 'on' if om1 >> 7 & 1 else 'off')
        A('cvg_x_alpha', 'on' if om1 >> 12 & 1 else 'off')
        A('alpha_cvg_select', 'on' if om1 >> 13 & 1 else 'off')
        A('alpha compare', ('off', 'on (blend alpha)', 'off (dither bit only)', 'on (dithered/noise)')[om1 & 3])
        A('dither (rgb / alpha)', '%s / %s' % (DITHER_RGB[(om0 >> 6) & 3], DITHER_A[(om0 >> 4) & 3]))
        A('noise needed', 'yes' if f & n64rdp.R_NEED_NOISE else 'no')
        z_cmp, z_upd = om1 >> 4 & 1, om1 >> 5 & 1
        A('z compare / update', 'cmp=%d upd=%d' % (z_cmp, z_upd))
        A('z mode', Z_MODE[(om1 >> 10) & 3] + ('' if (z_cmp or z_upd) else ' (z off)'))
        A('z source', 'primitive depth' if om1 >> 2 & 1 else 'per-pixel')
        A('render mode (full)', '%s | %s | z %d%d %s | aa=%d cvg=%s con=%d cxa=%d acs=%d fb=%d ir=%d ac=%d'
          % (CYCLE[cyc], bl, z_cmp, z_upd, Z_MODE[(om1 >> 10) & 3], om1 >> 3 & 1, CVG_DEST[(om1 >> 8) & 3],
             om1 >> 7 & 1, om1 >> 12 & 1, om1 >> 13 & 1, om1 >> 14 & 1, om1 >> 6 & 1, om1 & 1))


# --- the run ---------------------------------------------------------------------------------------
def parse_inputs(text):
    """-> [(first frame, last frame, pad word)]"""
    out = []
    for item in filter(None, (s.strip() for s in text.split(','))):
        period = until = 0
        if '~' in item:                         # ...~PERIOD:UNTIL repeats the item
            item, _, rep = item.partition('~')
            p, _, u = rep.partition(':')
            period, until = int(p), int(u)
        span, _, what = item.partition('=')
        f, _, n = span.partition('+')
        f, n = int(f), int(n or 1)
        stick = (0, 0)
        if '@' in what:
            what, _, xy = what.partition('@')
            x, _, y = xy.partition('/')
            stick = (int(x), int(y))
        word = 0
        for b in filter(None, what.split('|')):
            if b != '-':
                word |= 1 << BUTTONS[b.upper()]
        word |= ((stick[0] & 0xFF) << 8) | (stick[1] & 0xFF)
        out.append((f, f + n - 1, word))
        while period and f + period < until:
            f += period
            out.append((f, f + n - 1, word))
    return out


def pad_at(sched, frame):
    w = 0
    for a, b, word in sched:
        if a <= frame <= b:
            w |= word
    return w


def snapshot(path, m, census, extra):
    census.unhook(m)
    try:
        with open(path + '.tmp', 'wb') as fh:
            pickle.dump((m, census, extra), fh, protocol=5)
        os.replace(path + '.tmp', path)
    finally:
        census.hook(m)


def write_outputs(out, census, meta, phases):
    data = dict(meta=meta, segments=census.segments, game_frames=census.game_frames, vi_frames=census.vi_frames)
    jp = os.path.join(out, 'sm64_census.json')
    with open(jp + '.tmp', 'w') as fh:
        json.dump(data, fh, separators=(',', ':'))
    os.replace(jp + '.tmp', jp)
    with open(os.path.join(out, 'sm64_census.md'), 'w') as fh:
        fh.write(report(data, phases))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--rom', default=ROM)
    ap.add_argument('--frames', type=int, default=7800, help='stop at this VI frame')
    ap.add_argument('--out', default=OUT)
    ap.add_argument('--inputs', default=DEFAULT_INPUTS)
    ap.add_argument('--phases', default=DEFAULT_PHASES)
    ap.add_argument('--snap-dir', default='')
    ap.add_argument('--snap-every', type=int, default=0)
    ap.add_argument('--snap-at', default='')
    ap.add_argument('--resume', default='')
    ap.add_argument('--png-every', type=int, default=30)
    ap.add_argument('--write-every', type=int, default=300)
    ap.add_argument('--prefix', default='sm64')
    ap.add_argument('--report-only', default='')
    ap.add_argument('--eeprom', action='store_true', help='give the cartridge a 4 kbit EEPROM')
    args = ap.parse_args()
    if args.report_only:
        data = json.load(open(args.report_only))
        out = os.path.join(os.path.dirname(args.report_only), 'sm64_census.md')
        open(out, 'w').write(report(data, args.phases))
        print('wrote', out)
        return
    os.makedirs(os.path.join(args.out, 'census'), exist_ok=True)
    sched = parse_inputs(args.inputs)
    snap_at = {int(v) for v in args.snap_at.split(',') if v}
    if args.resume:
        with open(args.resume, 'rb') as fh:
            m, census, extra = pickle.load(fh)
        wall0 = extra.get('wall', 0.0)
        print('resumed at frame %d' % m.vi_frames, flush=True)
    else:
        rom = open(args.rom, 'rb').read()
        if rom[:4] == bytes((0x37, 0x80, 0x40, 0x12)):
            rom = bytes(b for i in range(0, len(rom), 2) for b in (rom[i + 1], rom[i]))
        m = n64model.N64(rom)
        n64rdptests.ensure_rdp(m)
        m.fast_boot()
        if args.eeprom:
            m.joy.eeprom = bytearray(512)      # SM64 has a 4 kbit EEPROM
        census = Census()
        wall0 = 0.0
    census.hook(m)
    c = m.cpu
    t0 = time.time()
    frame = m.vi_frames
    meta = dict(rom=os.path.basename(args.rom), inputs=args.inputs, frames=frame, wall=wall0)
    m.joy.pads[0] = pad_at(sched, frame)
    while frame < args.frames:
        for _ in range(1024):
            c.step()
        if m.vi_frames == frame:
            continue
        frame = m.vi_frames
        census.vi_tick(frame)
        m.joy.pads[0] = pad_at(sched, frame)
        wall = wall0 + time.time() - t0
        meta.update(frames=frame, wall=wall)
        if args.png_every and frame % args.png_every == 0:
            pic = n64rdptests.vi_picture(m)
            n64rdptests.save_picture(pic, os.path.join(args.out, 'census', '%s_%04d.png' % (args.prefix, frame)))
            n64rdptests.save_picture(pic, os.path.join(args.out, 'census', '%s_latest.png' % args.prefix))
            gfs = census.game_frames[-15:]
            print('frame %d (%.1f s emulated): %.0f s wall, pad %08x, RDP %d cmds %d prims %d px; last %d game frames: '
                  '%.0f prims %.0f px' % (frame, frame / 60, wall, m.joy.pads[0], m.rdp.commands, m.rdp.prims,
                                          m.rdp.pixels, len(gfs), sum(g['prims'] for g in gfs) / max(1, len(gfs)),
                                          sum(g['px'] for g in gfs) / max(1, len(gfs))), flush=True)
        if args.write_every and frame % args.write_every == 0:
            write_outputs(args.out, census, meta, args.phases)
        if args.snap_dir and ((args.snap_every and frame % args.snap_every == 0) or frame in snap_at):
            snapshot(os.path.join(args.snap_dir, '%s_%04d.pkl' % (args.prefix, frame)), m, census,
                     dict(wall=wall))
            print('snapshot at frame %d' % frame, flush=True)
    write_outputs(args.out, census, meta, args.phases)
    print('done: frame %d, %.0f s wall' % (frame, wall0 + time.time() - t0))


# --- the report --------------------------------------------------------------------------------------
def parse_phases(text):
    out = []
    for item in filter(None, (s.strip() for s in text.split(','))):
        name, _, f = item.partition(':')
        out.append((name, int(f)))
    return sorted(out, key=lambda p: p[1])


def phase_of(phases, vi):
    name = phases[0][0] if phases else 'all'
    for n, f in phases:
        if vi >= f:
            name = n
    return name


def merge(segs):
    cats, loads = {}, {}
    for s in segs:
        for cat, d in s['cats'].items():
            dd = cats.setdefault(cat, {})
            for k, v in d.items():
                e = dd.setdefault(k, [0, 0, 0, 0])
                for i in range(4):
                    e[i] += v[i]
        for cat, d in s['loads'].items():
            dd = loads.setdefault(cat, {})
            for k, v in d.items():
                e = dd.setdefault(k, [0, 0, 0])
                for i in range(3):
                    e[i] += v[i]
    return cats, loads


def frame_stats(frames, keys):
    rows = []
    for k in keys:
        vals = [f[k] for f in frames]
        if not vals:
            rows.append((k, 0, 0, 0, 0))
            continue
        s = sorted(vals)
        rows.append((k, sum(vals) / len(vals), s[len(s) // 2], s[min(len(s) - 1, int(len(s) * 0.95))], s[-1]))
    return rows


PER_TILE = ('texture format', 'texture size (tile texels)', 'texture wrap S', 'texture wrap T', 'tile index sampled',
            'texel samples', 'lod tile choice (per pixel)')


def feature_list():
    """(feature, category, predicate on the key) for the summary"""
    F = []
    for c in CYCLE:
        F.append(('cycle: ' + c, 'cycle', lambda k, c=c: k == c))
    for op in (0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x24, 0x25, 0x36):
        F.append(('command: ' + OPS[op], 'command', lambda k, n=OPS[op]: k == n))
    F += [('Z compare', 'z compare / update', lambda k: 'cmp=1' in k),
          ('Z update', 'z compare / update', lambda k: 'upd=1' in k)]
    for z in Z_MODE:
        F.append(('Z mode ' + z + ' (with Z on)', 'z mode', lambda k, z=z: k == z))
    F += [('Z source = primitive depth', 'z source', lambda k: k == 'primitive depth'),
          ('antialias (coverage)', 'antialias', lambda k: k == 'on')]
    for c in CVG_DEST:
        F.append(('cvg_dest ' + c, 'cvg_dest', lambda k, c=c: k == c))
    F += [('color_on_cvg', 'color_on_cvg', lambda k: k == 'on'),
          ('cvg_x_alpha', 'cvg_x_alpha', lambda k: k == 'on'),
          ('alpha_cvg_select', 'alpha_cvg_select', lambda k: k == 'on'),
          ('alpha compare (vs blend alpha)', 'alpha compare', lambda k: k == 'on (blend alpha)'),
          ('alpha compare (dithered)', 'alpha compare', lambda k: k == 'on (dithered/noise)'),
          ('force_blend', 'force_blend', lambda k: k == 'on'),
          ('image_read_en (memory colour read)', 'image_read_en', lambda k: k == 'on'),
          ('blender: MEMORY colour/coverage', 'blender inputs', lambda k: k == 'MEMORY'),
          ('blender: FOG_COLOR', 'blender inputs', lambda k: k == 'FOG_COLOR'),
          ('blender: FOG_A', 'blender inputs', lambda k: k == 'FOG_A'),
          ('blender: SHADE_A as factor (fog)', 'blender inputs', lambda k: k == 'SHADE_A as factor'),
          ('blender: BLEND_COLOR', 'blender inputs', lambda k: k == 'BLEND_COLOR'),
          ('textured (1/2-cycle or copy)', 'textured', lambda k: k == 'textured')]
    for fmt in ('RGBA16b', 'RGBA32b', 'YUV16b', 'CI4b', 'CI8b', 'IA4b', 'IA8b', 'IA16b', 'I4b', 'I8b'):
        F.append(('texture ' + fmt, 'texture format', lambda k, f=fmt: k == f))
    F += [('TLUT, RGBA16 palette', 'tlut', lambda k: k == 'on, RGBA16'),
          ('TLUT, IA16 palette', 'tlut', lambda k: k == 'on, IA16'),
          ('filter: point', 'texture filter', lambda k: k.startswith('point')),
          ('filter: bilinear (3-tap)', 'texture filter', lambda k: k == 'bilinear'),
          ('filter: average / mid-texel', 'texture filter', lambda k: k.startswith('average')),
          ('perspective correction', 'perspective', lambda k: k == 'on'),
          ('texture LOD (mip-mapping)', 'lod / sharpen / detail', lambda k: 'tex_lod=1' in k),
          ('sharpen', 'lod / sharpen / detail', lambda k: 'sharpen=1' in k),
          ('detail', 'lod / sharpen / detail', lambda k: 'detail=1' in k),
          ('LOD fraction computed', 'lod frac needed', lambda k: k == 'yes'),
          ('TEXEL1 used (2nd tile / pipelined)', 'texel0 / texel1', lambda k: not k.endswith('/ -')),
          ('convert_one (texel1 = convert(texel0))', 'texture convert (bilerp0 bilerp1 convert_one)',
           lambda k: 'convert_one=1' in k),
          ('bilerp0 off (colour convert / YUV in cycle 0)', 'texture convert (bilerp0 bilerp1 convert_one)',
           lambda k: 'bilerp0=0' in k)]
    for ax in 'ST':
        cat = 'texture wrap ' + ax
        F += [('%s: wrap (mask, no mirror/clamp)' % ax, cat, lambda k: 'wrap mask' in k and 'clamp' not in k),
              ('%s: mirror' % ax, cat, lambda k: 'mirror' in k),
              ('%s: clamp bit' % ax, cat, lambda k: k.startswith('clamp')),
              ('%s: mask 0 (clamps)' % ax, cat, lambda k: 'mask0' in k),
              ('%s: shift' % ax, cat, lambda k: 'shift=' in k)]
    for inp in ('TEXEL0', 'TEXEL1', 'SHADE', 'PRIM', 'ENV', 'COMBINED', 'COMBINED_A', 'TEXEL0_A', 'TEXEL1_A',
                'SHADE_A', 'PRIM_A', 'ENV_A', 'NOISE', 'LOD_FRAC', 'PRIM_LOD_FRAC', 'KEY_CENTER', 'KEY_SCALE',
                'K4', 'K5'):
        F.append(('combiner input ' + inp, 'combiner inputs (either cycle, rgb or alpha)',
                  lambda k, i=inp: k == i))
    F += [('chroma key', 'chroma key enable', lambda k: k == 'on'),
          ('noise generator needed', 'noise needed', lambda k: k == 'yes')]
    for d in DITHER_RGB:
        F.append(('rgb dither: ' + d, 'dither (rgb / alpha)', lambda k, d=d: k.split(' / ')[0] == d))
    for d in DITHER_A:
        F.append(('alpha dither: ' + d, 'dither (rgb / alpha)', lambda k, d=d: k.split(' / ')[1] == d))
    return F


def feature_summary(cc, loads):
    total = sum(v[1] for v in cc.get('command', {}).values()) or 1
    cy = cc.get('cycle', {})
    shaded = (cy.get('1cycle', [0, 0])[1] + cy.get('2cycle', [0, 0])[1]) or 1
    rows, zero = [], []
    for name, cat, pred in feature_list():
        px = prims = 0
        for k, v in cc.get(cat, {}).items():
            if pred(k):
                prims += v[0]
                px += v[1]
        if prims or px:
            sh = None if name in ('cycle: fill', 'cycle: copy', 'command: FILL_RECT') else 100.0 * px / shaded
            rows.append((name, 100.0 * px / total, sh, '-' if cat in PER_TILE else prims))
        else:
            zero.append(name)
    for kind in ('LOAD_BLOCK', 'LOAD_TILE', 'LOAD_TLUT'):
        n = sum(v[0] for k, v in loads.get('load_kind', {}).items() if k.startswith(kind))
        if n:
            rows.append((kind + ' (count in prims column)', 0.0, 0.0, n))
        else:
            zero.append(kind)
    rows.sort(key=lambda r: (-r[1], r[0]))
    return rows, zero


def report(data, phases_text):
    phases = parse_phases(phases_text)
    meta = data['meta']
    segs = data['segments']
    names = []
    for n, _ in phases:
        if n not in names:
            names.append(n)
    by_phase = {n: [s for s in segs if phase_of(phases, s['vi']) == n] for n in names}
    # phases that drew nothing get no column
    names = [n for n in names if any(s['cats'].get('command') for s in by_phase[n])]
    allc, alll = merge(segs)
    pc = {n: merge(by_phase[n])[0] for n in names}
    L = []
    w = L.append
    w('# RDP feature census: Super Mario 64 in the model\n')
    w('Generated by `tools/n64/n64rdpcensus.py` (ROM `%s`): the game run in `tools/n64/n64model.py` with '
      '`tools/n64/n64rdp.py` drawing, to VI frame %d (%.1f s emulated, %.0f min wall). Every primitive is '
      'recorded with the RDP state it was drawn with.\n' % (meta['rom'], meta['frames'], meta['frames'] / 60,
                                                           meta['wall'] / 60))
    w('Controller schedule (VI frame+length=buttons@stick): `%s`\n' % meta['inputs'])
    w('Measures: **prims** = primitives; **px** = pixels that reach the memory stage (1/2-cycle: covered '
      'and past the alpha compare, before the Z test; fill/copy: every span pixel); **span** = pixels the '
      'rasteriser walks; **written** = colour writes. Percentages are of px. Texture tables split a '
      'primitive\'s pixels over the tiles it sampled, by samples.\n')
    w('Phases (by VI frame; the counts are kept per 60 VI frames, so a phase takes whole 60-frame '
      'segments by where each starts): ' + ', '.join('%s from %d' % (n, f) for n, f in phases) + '\n')
    # --- per frame ---
    w('## Per frame\n')
    gfs = data['game_frames']
    keys = ['prims', 'tris', 'rects', 'fills', 'px', 'span', 'written', 'zwrites', 'blended', 'rows',
            'loads', 'tmem_bytes', 'cmds', 'clocks']
    w('A game frame is the work between two SYNC_FULLs (SM64 draws at 30 fps: one per two VI frames). '
      '"clocks" is an ideal pipeline: 1 per span pixel in 1-cycle, 2 in 2-cycle, 64 bits per clock in '
      'fill/copy; no per-primitive or per-line overhead, no memory stalls.\n')
    for n in names + ['all']:
        fr = [g for g in gfs if (n == 'all' or phase_of(phases, g['vi']) == n) and g['prims']]
        if not fr:
            continue
        w('### Game frames: %s (%d frames that drew)\n' % (n, len(fr)))
        w('| measure | mean | median | p95 | max | mean x30/s |')
        w('|---|---:|---:|---:|---:|---:|')
        for k, mean, med, p95, mx in frame_stats(fr, keys):
            w('| %s | %.0f | %.0f | %.0f | %.0f | %.3g |' % (k, mean, med, p95, mx, mean * 30))
        w('')
    vfs = [v for v in data['vi_frames'] if v['prims']]
    if vfs:
        w('### VI frames that drew (all phases: %d of %d)\n' % (len(vfs), len(data['vi_frames'])))
        w('In the model a game frame spreads over several VI frames (its CPU is slow against the VI), '
          'so these are pieces of game frames, not what a real console\'s VI frame holds.\n')
        w('| measure | mean | median | p95 | max |')
        w('|---|---:|---:|---:|---:|')
        for k, mean, med, p95, mx in frame_stats(vfs, ['prims', 'tris', 'px', 'span', 'tmem_bytes', 'clocks']):
            w('| %s | %.0f | %.0f | %.0f | %.0f |' % (k, mean, med, p95, mx))
        w('')
    # --- the summary ---
    for n in [x for x in names if x == 'gameplay'] + ['all']:
        cc = allc if n == 'all' else pc[n]
        rows, zero = feature_summary(cc, alll if n == 'all' else merge(by_phase[n])[1])
        w('## Feature use: %s (by share of all pixels)\n' % ('whole run' if n == 'all' else n))
        w('%px: share of all pixels (fill included); %shaded: share of the pixels drawn in 1/2-cycle mode '
          '(meaningful for the features of the shading pipeline).\n')
        w('| feature | %px | %shaded | prims |')
        w('|---|---:|---:|---:|')
        for name, share, sh, prims in rows:
            w('| %s | %.2f | %s | %s |' % (name, share, '-' if sh is None else '%.2f' % sh, prims))
        w('')
        w('**Not used at all (%s):** %s\n' % ('whole run' if n == 'all' else n, ', '.join(zero)))
    # --- the tables ---
    order = ['command', 'cycle', 'command x cycle', 'primitive size (px)', 'zero-pixel primitives', 'framebuffer',
             'color image address', 'scissor', 'pixel counts', 'fill', 'copy', 'textured', 'texture format',
             'texture size (tile texels)', 'texel0 / texel1', 'texel0 / texel1 tiles', 'tile index sampled',
             'texture filter', 'texture convert (bilerp0 bilerp1 convert_one)', 'perspective', 'tlut',
             'lod / sharpen / detail', 'lod frac needed', 'lod tile choice (per pixel)', 'texture wrap S',
             'texture wrap T', 'distinct tile configs (texel0)', 'texel samples', 'combiner',
             'combiner inputs (either cycle, rgb or alpha)', 'combiner inputs', 'chroma key enable', 'blender',
             'blender inputs', 'force_blend', 'image_read_en', 'antialias', 'cvg_dest', 'color_on_cvg',
             'cvg_x_alpha', 'alpha_cvg_select', 'alpha compare', 'dither (rgb / alpha)', 'noise needed',
             'z compare / update', 'z mode', 'z source', 'render mode (full)', 'opcode']
    order += [c for c in sorted(allc) if c not in order]
    w('## Feature tables (sorted by pixel share)\n')
    w('Columns: prims, px and %%px over the whole run, then %%px within each phase (%s).\n' % ', '.join(names))
    for cat in order:
        d = allc.get(cat)
        if not d:
            continue
        w('### %s (%d distinct)\n' % (cat, len(d)))
        if cat == 'opcode':
            w('| opcode | count |' + ''.join(' %s |' % n for n in names))
            w('|---|---:|' + '---:|' * len(names))
            for k, v in sorted(d.items(), key=lambda kv: -kv[1][0]):
                w('| %s | %d |' % (k, v[0]) + ''.join(' %d |' % pc[n].get(cat, {}).get(k, [0])[0] for n in names))
            w('')
            continue
        if cat == 'pixel counts':
            w('(%px here is of the pixels drawn in 1/2-cycle mode.)\n')
        elif cat in ('texel samples', 'lod tile choice (per pixel)'):
            w('(px here counts samples / LOD computations, not pixels.)\n')
        w('| value | prims | px | %px |' + ''.join(' %s %%px |' % n for n in names))
        w('|---|---:|---:|---:|' + '---:|' * len(names))
        # the share of what: all pixels; for the per-pixel counters, the 1/2-cycle pixels
        # (pixel counts), all samples, all LOD computations
        def denom(cc):
            if cat == 'pixel counts':
                cy = cc.get('cycle', {})
                return (cy.get('1cycle', [0, 0])[1] + cy.get('2cycle', [0, 0])[1]) or 1
            if cat in ('texel samples', 'lod tile choice (per pixel)'):
                return sum(x[1] for x in cc.get(cat, {}).values()) or 1
            return sum(x[1] for x in cc.get('command', {}).values()) or 1
        denom_all = denom(allc)
        for k, v in sorted(d.items(), key=lambda kv: (-kv[1][1], -kv[1][0])):
            cells = []
            for n in names:
                pv = pc[n].get(cat, {}).get(k)
                if pv is None:
                    cells.append(' - |')
                else:
                    cells.append(' %.2f |' % (100.0 * pv[1] / denom(pc[n])))
            w('| %s | %s | %.0f | %.2f |' % (k.replace('|', '/'), '-' if cat in PER_TILE else v[0], v[1],
                                            100.0 * v[1] / denom_all) + ''.join(cells))
        w('')
    # --- loads ---
    w('## TMEM loads\n')
    w('texels and bytes are what the command reads from RDRAM (bytes = texels x the texture image\'s size).\n')
    for cat in ('load_kind', 'load_size', 'load_block_dxt'):
        d = alll.get(cat)
        if not d:
            continue
        w('### %s\n' % cat)
        w('| value | count | texels | bytes | mean texels |')
        w('|---|---:|---:|---:|---:|')
        for k, v in sorted(d.items(), key=lambda kv: -kv[1][2]):
            w('| %s | %d | %d | %d | %.0f |' % (k, v[0], v[1], v[2], v[1] / max(1, v[0])))
        w('')
    return '\n'.join(L) + '\n'


if __name__ == '__main__':
    main()
