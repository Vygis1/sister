#!/usr/bin/env python3
"""srcstamp.py - what an FPGA image was built from, so a release can tell whether it is stale.

    python tools/srcstamp.py --snapshot > snap                     (at the build's start)
    python tools/srcstamp.py build/core_md.log snap > cores/md.src (after it; tools/core.sh does both)
    python tools/srcstamp.py --check cores/md.src                  (tools/release.sh does this)

A stamp lists, hashed, the project files Vivado read for that image: every source
module it synthesised (from the log's "synthesizing module" lines), the files
those `include, and the constraints -- as they were when the build STARTED (the
snapshot), so a file edited during a long build does not make the image look
current. An image is current while every file in its stamp is unchanged: a change
to the NES does not make the Mega Drive's image stale, which "older than the
newest RTL file" did.

Verilog is hashed without its comments and with its white space collapsed: a
comment cannot change the hardware, and rewording one must not call for a
three-hour rebuild of every console.
"""
import glob, hashlib, os, re, sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))

# a string, a comment, or anything else, in Verilog
TOKEN = re.compile(r'"(?:\\.|[^"\\\n])*"|//[^\n]*|/\*.*?\*/', re.S)


def code(text):
    """the Verilog without its comments (strings kept whole), white space collapsed"""
    out = TOKEN.sub(lambda m: m.group(0) if m.group(0).startswith('"') else ' ', text)
    return ' '.join(out.split())


def sha(path):
    with open(os.path.join(ROOT, path), 'rb') as f:
        data = f.read()
    if path.endswith(('.v', '.vh', '.sv')):
        data = code(data.decode('utf-8', errors='surrogateescape')).encode('utf-8', errors='surrogateescape')
    return hashlib.sha256(data).hexdigest()


def used_files(log):
    text = open(log, encoding='utf-8', errors='replace').read()
    root = ROOT.replace('\\', '/').lower() + '/'
    files = set()
    for m in re.finditer(r"synthesizing module '[^']+' \[(.+?):\d+\]", text):
        p = m.group(1).replace('\\', '/')
        # (the project's own rtl/ only: a memory controller generated under build/ has an rtl
        # folder of its own, is not in the snapshot, and is rebuilt from its .xci anyway)
        if p.lower().startswith(root) and p[len(root):].lower().startswith('rtl/'):
            files.add(p[len(root):])
    for m in re.finditer(r"[A-Za-z]:/[^\s\]\[']+\.xdc", text):
        p = m.group(0)
        if p.lower().startswith(root + 'boards/'):
            files.add(p[len(root):])
    # the files those sources `include (not named in the log)
    for f in sorted(files):
        if f.endswith('.v'):
            for inc in re.findall(r'^\s*`include\s+"([^"]+)"', open(os.path.join(ROOT, f), encoding='utf-8', errors='replace').read(), re.M):
                p = os.path.join(os.path.dirname(f), inc).replace('\\', '/')
                if os.path.exists(os.path.join(ROOT, p)):
                    files.add(p)
    return sorted(files)


def main():
    a = sys.argv[1:]
    if a == ['--snapshot']:
        for p in sorted(glob.glob(os.path.join(ROOT, 'rtl', '*')) + glob.glob(os.path.join(ROOT, 'boards', '*', '*.xdc'))):
            if os.path.isfile(p):
                r = os.path.relpath(p, ROOT).replace('\\', '/')
                print('%s  %s' % (sha(r), r))
        return
    if len(a) == 2 and a[0] == '--check':
        stale = []
        for line in open(a[1], encoding='utf-8'):
            if not line.strip() or line.startswith('#'):
                continue
            h, p = line.split(None, 1)
            p = p.strip()
            if not os.path.exists(os.path.join(ROOT, p)) or sha(p) != h:
                stale.append(p)
        for p in stale:
            print('changed since the build: ' + p)
        sys.exit(1 if stale else 0)
    if len(a) not in (1, 2):
        sys.exit(__doc__)
    files = used_files(a[0])
    if not files:
        sys.exit('no project sources named in ' + a[0])
    snap = {}
    if len(a) == 2:
        for line in open(a[1], encoding='utf-8'):
            if line.strip():
                h, p = line.split(None, 1)
                snap[p.strip()] = h
    for p in files:
        if snap and p not in snap:
            sys.exit(p + ' is not in the snapshot ' + a[1])
        print('%s  %s' % (snap.get(p) or sha(p), p))


if __name__ == '__main__':
    main()
