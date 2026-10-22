"""The PlayStation's disc, as tracks, and the sound on it.

A disc is a .cue sheet (or a lone .bin, one data track). The cue's FILEs can be
raw sector images (BINARY) or audio files -- WAVE, MP3, FLAC, OGG, anything
miniaudio decodes -- which is how most rips keep their music: the data track as
a .bin and every audio track as an .mp3. An audio file is decoded once, to
44.1 kHz stereo 16-bit, into a cache next to the build, and from then on its
sectors are just 2352-byte slices of that file: an audio sector IS 588 stereo
samples of 16-bit PCM, so the drive gets them exactly as it would off a CD.

Disc.read_sector(lba) serves any sector of the whole disc, Disc.toc() gives the
table of contents for ps1_cdrom.v.

XaDecoder turns XA-ADPCM sectors into 44.1 kHz stereo samples, exactly as
DuckStation does (CDROM::DecodeXAADPCMChunks, ResampleXAADPCM and
ResampleXAADPCM18900): the four-filter ADPCM, then the seven-phase "zigzag"
interpolator that turns six 37.8 kHz samples into seven at 44.1 kHz, or
Mednafen's table for 18.9 kHz.
"""
import hashlib
import os
import re
import struct
import threading

import numpy as np

SECTOR = 2352
SAMPLES_PER_SECTOR = SECTOR // 4          # stereo 16-bit
CACHE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "build", "cdda_cache")


def msf_to_frames(s):
    m, sec, f = (int(x) for x in s.split(":"))
    return (m * 60 + sec) * 75 + f


# =============================================================================
# the sources: a raw image, or an audio file decoded to raw PCM
# =============================================================================
class RawFile:
    """Sectors straight out of a file of 2352-byte sectors."""

    def __init__(self, path):
        self.path = path
        self.sectors = os.path.getsize(path) // SECTOR
        self.f = open(path, "rb")
        self.lock = threading.Lock()

    def read(self, n):
        with self.lock:
            self.f.seek(n * SECTOR)
            return self.f.read(SECTOR).ljust(SECTOR, b"\0")


class AudioFile:
    """An audio file as CD sectors: decoded once to a raw 44.1 kHz stereo cache.

    The cache is named by the file's path, size and modification time, so a
    changed file is decoded again and an unchanged one never is. Decoding a
    four-minute MP3 takes a second or two; it is done in the background when
    the disc is chosen (prepare()), and on demand if a sector is wanted first.
    """

    def __init__(self, path, kind):
        self.path, self.kind = path, kind
        st = os.stat(path)
        key = hashlib.sha1(("%s|%d|%d" % (os.path.abspath(path), st.st_size, int(st.st_mtime))).encode()).hexdigest()[:16]
        self.cache = os.path.join(CACHE, key + ".pcm")
        self.lock = threading.Lock()
        self.f = None
        if kind == "WAVE" and path.lower().endswith(".wav") and self._wav_is_cd():
            self.cache = None                     # already CD audio: read it in place
            self.data_off = self._wav_data_offset()
            self.sectors = (os.path.getsize(path) - self.data_off + SECTOR - 1) // SECTOR
        else:
            self.data_off = 0
            self.sectors = self._length_sectors()

    def _wav_is_cd(self):
        try:
            with open(self.path, "rb") as f:
                h = f.read(36)
            ch, rate, bits = struct.unpack("<H", h[22:24])[0], struct.unpack("<I", h[24:28])[0], struct.unpack("<H", h[34:36])[0]
            return h[:4] == b"RIFF" and ch == 2 and rate == 44100 and bits == 16
        except (OSError, struct.error):
            return False

    def _wav_data_offset(self):
        with open(self.path, "rb") as f:
            f.seek(12)
            while True:
                hdr = f.read(8)
                if len(hdr) < 8:
                    return 44
                cid, size = hdr[:4], struct.unpack("<I", hdr[4:])[0]
                if cid == b"data":
                    return f.tell()
                f.seek(size + (size & 1), 1)

    def _length_sectors(self):
        if os.path.isfile(self.cache):
            return (os.path.getsize(self.cache) + SECTOR - 1) // SECTOR
        import miniaudio
        info = miniaudio.get_file_info(self.path)
        frames = int(info.num_frames * 44100 / info.sample_rate) if info.sample_rate else 0
        return max(1, (frames + SAMPLES_PER_SECTOR - 1) // SAMPLES_PER_SECTOR)

    def prepare(self):
        """Decode to the cache, if it is not there yet."""
        if self.cache is None:
            return
        with self.lock:
            if os.path.isfile(self.cache):
                return
            import miniaudio
            os.makedirs(CACHE, exist_ok=True)
            snd = miniaudio.decode_file(self.path, output_format=miniaudio.SampleFormat.SIGNED16,
                                        nchannels=2, sample_rate=44100)
            tmp = self.cache + ".tmp"
            with open(tmp, "wb") as f:
                f.write(snd.samples.tobytes())
            os.replace(tmp, self.cache)
            self.sectors = (os.path.getsize(self.cache) + SECTOR - 1) // SECTOR

    def read(self, n):
        self.prepare()
        with self.lock:
            if self.f is None:
                self.f = open(self.cache or self.path, "rb")
            self.f.seek(self.data_off + n * SECTOR)
            return self.f.read(SECTOR).ljust(SECTOR, b"\0")


# =============================================================================
# the disc
# =============================================================================
class Track:
    def __init__(self, number, mode):
        self.number, self.mode = number, mode
        self.audio = mode == "AUDIO"
        self.start = 0                            # disc LBA of INDEX 01


class Disc:
    """A .cue sheet, or a single raw image, as one run of sectors.

    The disc is a list of segments -- (first LBA, count, source, first sector in
    the source) -- laid end to end, with PREGAPs as silence that is in no file.
    """

    def __init__(self, path):
        self.path = path
        self.tracks = []
        self.segments = []
        if path.lower().endswith(".cue"):
            self._parse_cue(path)
        else:
            src = RawFile(path)
            t = Track(1, "MODE2/2352")
            self.tracks.append(t)
            self.segments.append((0, src.sectors, src, 0))
        last = self.segments[-1]
        self.sectors = last[0] + last[1]

    def _parse_cue(self, path):
        base = os.path.dirname(os.path.abspath(path))
        files = []                                # [(source, [(track, idx00, idx01, pregap)])]
        cur = None
        track = None
        for line in open(path, encoding="utf-8", errors="replace"):
            line = line.strip()
            m = re.match(r'FILE\s+"?(.*?)"?\s+(\w+)$', line, re.I)
            if m:
                name, kind = m.group(1), m.group(2).upper()
                fp = os.path.join(base, name)
                if kind == "BINARY" or kind == "MOTOROLA":
                    src = RawFile(fp)
                else:
                    src = AudioFile(fp, kind)
                cur = (src, [])
                files.append(cur)
                continue
            m = re.match(r"TRACK\s+(\d+)\s+(\S+)", line, re.I)
            if m:
                track = Track(int(m.group(1)), m.group(2).upper())
                cur[1].append([track, None, None, 0])
                self.tracks.append(track)
                continue
            m = re.match(r"INDEX\s+(\d+)\s+(\d+:\d+:\d+)", line, re.I)
            if m and cur and cur[1]:
                which = int(m.group(1))
                if which == 0:
                    cur[1][-1][1] = msf_to_frames(m.group(2))
                elif which == 1:
                    cur[1][-1][2] = msf_to_frames(m.group(2))
                continue
            m = re.match(r"PREGAP\s+(\d+:\d+:\d+)", line, re.I)
            if m and cur and cur[1]:
                cur[1][-1][3] = msf_to_frames(m.group(1))
        pos = 0
        for src, tracks in files:
            consumed = 0                          # sectors of this file laid down so far
            for i, (t, i0, i1, pregap) in enumerate(tracks):
                if pregap:                        # silence that is not in the file
                    self.segments.append((pos, pregap, None, 0))
                    pos += pregap
                start_in_file = i1 if i1 is not None else 0
                # the part of the file before this track's INDEX 01 (its INDEX 00 gap)
                if start_in_file > consumed:
                    self.segments.append((pos, start_in_file - consumed, src, consumed))
                    pos += start_in_file - consumed
                    consumed = start_in_file
                t.start = pos
                end_in_file = tracks[i + 1][1] if i + 1 < len(tracks) and tracks[i + 1][1] is not None else (
                    tracks[i + 1][2] if i + 1 < len(tracks) else src.sectors)
                n = max(0, end_in_file - consumed)
                if n:
                    self.segments.append((pos, n, src, consumed))
                    pos += n
                    consumed += n

    def prepare(self):
        """Decode every compressed audio track into the cache (a thread does this)."""
        for _, _, src, _ in self.segments:
            if isinstance(src, AudioFile):
                try:
                    src.prepare()
                except Exception:
                    pass

    def read_sector(self, lba):
        for first, count, src, off in self.segments:
            if first <= lba < first + count:
                if src is None:
                    return bytes(SECTOR)
                return src.read(off + lba - first)
        return bytes(SECTOR)

    def track_at(self, lba):
        t0 = self.tracks[0]
        for t in self.tracks:
            if t.start <= lba:
                t0 = t
        return t0

    def toc(self):
        """[(address, word)] for ps1_cdrom.v's toc_* port (console_top 0x5000 + 4*address)."""
        out = []
        for t in self.tracks:
            n = t.number & 0x7F
            out.append((n, (1 << 24 if t.audio else 0) | t.start))
            s = (t.start + 150) // 75
            out.append((0x80 | n, ((s // 60) << 6) | (s % 60)))
        out.append((0, self.sectors))                         # the lead-out
        s = (self.sectors + 150) // 75
        out.append((0x80, ((s // 60) << 6) | (s % 60)))
        out.append((0xFF, (self.tracks[0].number << 8) | self.tracks[-1].number))
        return out


# =============================================================================
# XA-ADPCM
# =============================================================================
_POS = (0, 60, 115, 98)
_NEG = (0, 0, -52, -55)

_ZIGZAG = np.array([
    [0, 0x0, 0x0, 0x0, 0x0, -0x0002, 0x000A, -0x0022, 0x0041, -0x0054, 0x0034, 0x0009, -0x010A, 0x0400, -0x0A78,
     0x234C, 0x6794, -0x1780, 0x0BCD, -0x0623, 0x0350, -0x016D, 0x006B, 0x000A, -0x0010, 0x0011, -0x0008, 0x0003, -0x0001],
    [0, 0x0, 0x0, -0x0002, 0x0, 0x0003, -0x0013, 0x003C, -0x004B, 0x00A2, -0x00E3, 0x0132, -0x0043, -0x0267, 0x0C9D,
     0x74BB, -0x11B4, 0x09B8, -0x05BF, 0x0372, -0x01A8, 0x00A6, -0x001B, 0x0005, 0x0006, -0x0008, 0x0003, -0x0001, 0x0],
    [0, 0x0, -0x0001, 0x0003, -0x0002, -0x0005, 0x001F, -0x004A, 0x00B3, -0x0192, 0x02B1, -0x039E, 0x04F8, -0x05A6, 0x7939,
     -0x05A6, 0x04F8, -0x039E, 0x02B1, -0x0192, 0x00B3, -0x004A, 0x001F, -0x0005, -0x0002, 0x0003, -0x0001, 0x0, 0x0],
    [0, -0x0001, 0x0003, -0x0008, 0x0006, 0x0005, -0x001B, 0x00A6, -0x01A8, 0x0372, -0x05BF, 0x09B8, -0x11B4, 0x74BB, 0x0C9D,
     -0x0267, -0x0043, 0x0132, -0x00E3, 0x00A2, -0x004B, 0x003C, -0x0013, 0x0003, 0x0, -0x0002, 0x0, 0x0, 0x0],
    [-0x0001, 0x0003, -0x0008, 0x0011, -0x0010, 0x000A, 0x006B, -0x016D, 0x0350, -0x0623, 0x0BCD, -0x1780, 0x6794, 0x234C,
     -0x0A78, 0x0400, -0x010A, 0x0009, 0x0034, -0x0054, 0x0041, -0x0022, 0x000A, -0x0001, 0x0, 0x0001, 0x0, 0x0, 0x0],
    [0x0002, -0x0008, 0x0010, -0x0023, 0x002B, 0x001A, -0x00EB, 0x027B, -0x0548, 0x0AFA, -0x16FA, 0x53E0, 0x3C07, -0x1249,
     0x080E, -0x0347, 0x015B, -0x0044, -0x0017, 0x0046, -0x0023, 0x0011, -0x0005, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0],
    [-0x0005, 0x0011, -0x0023, 0x0046, -0x0017, -0x0044, 0x015B, -0x0347, 0x080E, -0x1249, 0x3C07, 0x53E0, -0x16FA, 0x0AFA,
     -0x0548, 0x027B, -0x00EB, 0x001A, 0x002B, -0x0023, 0x0010, -0x0008, 0x0002, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0],
], dtype=np.int64)

_T18900 = np.array([
    [0x0, -0x5, 0x11, -0x23, 0x46, -0x17, -0x44, 0x15b, -0x347, 0x80e, -0x1249, 0x3c07, 0x53e0,
     -0x16fa, 0xafa, -0x548, 0x27b, -0xeb, 0x1a, 0x2b, -0x23, 0x10, -0x8, 0x2, 0x0],
    [0x0, -0x2, 0xa, -0x22, 0x41, -0x54, 0x34, 0x9, -0x10a, 0x400, -0xa78, 0x234c, 0x6794,
     -0x1780, 0xbcd, -0x623, 0x350, -0x16d, 0x6b, 0xa, -0x10, 0x11, -0x8, 0x3, -0x1],
    [-0x2, 0x0, 0x3, -0x13, 0x3c, -0x4b, 0xa2, -0xe3, 0x132, -0x43, -0x267, 0xc9d, 0x74bb,
     -0x11b4, 0x9b8, -0x5bf, 0x372, -0x1a8, 0xa6, -0x1b, 0x5, 0x6, -0x8, 0x3, -0x1],
    [-0x1, 0x3, -0x2, -0x5, 0x1f, -0x4a, 0xb3, -0x192, 0x2b1, -0x39e, 0x4f8, -0x5a6, 0x7939,
     -0x5a6, 0x4f8, -0x39e, 0x2b1, -0x192, 0xb3, -0x4a, 0x1f, -0x5, -0x2, 0x3, -0x1],
    [-0x1, 0x3, -0x8, 0x6, 0x5, -0x1b, 0xa6, -0x1a8, 0x372, -0x5bf, 0x9b8, -0x11b4, 0x74bb,
     0xc9d, -0x267, -0x43, 0x132, -0xe3, 0xa2, -0x4b, 0x3c, -0x13, 0x3, 0x0, -0x2],
    [-0x1, 0x3, -0x8, 0x11, -0x10, 0xa, 0x6b, -0x16d, 0x350, -0x623, 0xbcd, -0x1780, 0x6794,
     0x234c, -0xa78, 0x400, -0x10a, 0x9, 0x34, -0x54, 0x41, -0x22, 0xa, -0x2, 0x0],
    [0x0, 0x2, -0x8, 0x10, -0x23, 0x2b, 0x1a, -0xeb, 0x27b, -0x548, 0xafa, -0x16fa, 0x53e0,
     0x3c07, -0x1249, 0x80e, -0x347, 0x15b, -0x44, -0x17, 0x46, -0x23, 0x11, -0x5, 0x0],
], dtype=np.int64)


class XaDecoder:
    """One XA stream's state: the ADPCM history and the resampler's ring.
    reset() at every seek, as the drive does (ResetAudioDecoder)."""

    def __init__(self):
        self.reset()

    def reset(self):
        self.prev = [[0, 0], [0, 0]]
        self.ring = np.zeros((2, 32), dtype=np.int64)
        self.p = 0
        self.sixstep = 6
        self.cur = None                            # (file, channel) being played, without a filter

    @staticmethod
    def info(sector):
        """file, channel, submode, coding of a Mode 2 sector"""
        return sector[16], sector[17], sector[18], sector[19]

    def accept(self, sector, filtered):
        """DuckStation's "current file": with no filter, the first file/channel
        heard is the one played until its EOF; channel 255 is junk."""
        f, c, sub, _ = self.info(sector)
        if filtered:
            return True
        if self.cur is None:
            if c == 255:
                return False
            self.cur = (f, c)
        elif self.cur != (f, c):
            return False
        if sub & 0x80:                             # EOF: the next sector picks the file again
            self.cur = None
        return True

    def _adpcm(self, sector, stereo, eight):
        nblk = 4 if eight else 8
        out = []
        chunk0 = 24
        per_chunk = 28 * nblk
        out = np.zeros(18 * per_chunk, dtype=np.int64)
        for ci in range(18):
            ch = sector[chunk0 + ci * 128: chunk0 + ci * 128 + 128]
            words = struct.unpack("<28I", ch[16:128])
            base = ci * per_chunk
            for blk in range(nblk):
                hdr = ch[4 + blk]
                shift = hdr & 0x0F
                if shift > 12:
                    shift = 9
                flt = (hdr >> 4) & 0x0F
                fp = _POS[flt] if flt < 4 else 0
                fn = _NEG[flt] if flt < 4 else 0
                prev = self.prev[blk & 1] if stereo else self.prev[0]
                if stereo:
                    o = base + (blk // 2) * 56 + (blk % 2)
                    inc = 2
                else:
                    o = base + blk * 28
                    inc = 1
                for w in words:
                    nib = (w >> (blk * 8)) & 0xFF if eight else (w >> (blk * 4)) & 0x0F
                    s = ((nib << (8 if eight else 12)) & 0xFFFF)
                    if s & 0x8000:
                        s -= 0x10000
                    s >>= shift
                    v = s + ((prev[0] * fp) >> 6) + ((prev[1] * fn) >> 6)
                    v = -32768 if v < -32768 else 32767 if v > 32767 else v
                    prev[1] = prev[0]
                    prev[0] = v
                    out[o] = v
                    o += inc
        return out

    def decode(self, sector):
        """One XA sector to 44.1 kHz stereo: an int16 array of shape (n, 2)."""
        coding = sector[19]
        stereo = (coding & 0x03) == 1
        half = ((coding >> 2) & 0x03) == 1
        eight = ((coding >> 4) & 0x03) == 1
        s = self._adpcm(sector, stereo, eight)
        if stereo:
            frames = s.reshape(-1, 2)
        else:
            frames = np.stack([s, s], axis=1)
        return self._resample18900(frames, stereo) if half else self._resample37800(frames, stereo)

    def _resample37800(self, frames, stereo):
        out = []
        ring, p, six = self.ring, self.p, self.sixstep
        idx = (np.arange(29) * -1)
        for fr in frames:
            ring[0, p] = fr[0]
            ring[1, p] = fr[1]
            p = (p + 1) & 31
            six -= 1
            if six == 0:
                six = 6
                win_l = ring[0, (p + idx) & 31]          # ringbuf[(p - i) & 31] for i = 0..28
                win_r = ring[1, (p + idx) & 31]
                l = ((win_l[None, :] * _ZIGZAG) >> 15).sum(axis=1)
                r = ((win_r[None, :] * _ZIGZAG) >> 15).sum(axis=1) if stereo else l
                out.append(np.stack([np.clip(l, -32768, 32767), np.clip(r, -32768, 32767)], axis=1))
        self.p, self.sixstep = p, six
        return np.concatenate(out).astype(np.int16) if out else np.zeros((0, 2), np.int16)

    def _resample18900(self, frames, stereo):
        out = []
        ring, p, six = self.ring, self.p, self.sixstep
        idx = np.arange(25) + 32 - 25
        i = 0
        n = len(frames)
        while i < n:
            if six >= 7:
                six -= 7
                p = (p + 1) & 31
                ring[0, p] = frames[i][0]
                ring[1, p] = frames[i][1]
                i += 1
            win_l = ring[0, (p + idx) & 31]
            l = int(np.clip((win_l * _T18900[six]).sum() >> 15, -32768, 32767))
            if stereo:
                win_r = ring[1, (p + idx) & 31]
                r = int(np.clip((win_r * _T18900[six]).sum() >> 15, -32768, 32767))
            else:
                r = l
            out.append((l, r))
            six += 3
        self.p, self.sixstep = p, six
        return np.array(out, dtype=np.int16).reshape(-1, 2)
