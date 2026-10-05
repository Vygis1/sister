#!/usr/bin/env python3
"""srcstamp.py - what an FPGA image was built from, so a release can tell whether it is stale.

    sha256sum rtl/* boards/*/*.xdc > snap                        (at the build's start)
    python tools/srcstamp.py build/core_md.log snap > cores/md.src   (tools/core.sh does both)
    python tools/srcstamp.py --check cores/md.src                (tools/release.sh does this)

A stamp lists, with their SHA-256, the project files Vivado read for that image:
every source module it synthesised (from the log's "synthesizing module" lines),
the files those `include, and the constraints -- hashed as they were when the
build STARTED (the snapshot), so a file edited during a long build does not make
the image look current. An image is current while every
file in its stamp is unchanged -- a change to the NES does not make the Mega
Drive's image stale, which "older than the newest RTL file" did.
"""
import hashlib, os, re, sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))


def sha(path):
    with open(os.path.join(ROOT, path), 'rb') as f:
        return hashlib.sha256(f.read()).hexdigest()


def used_files(log):
    text = open(log, encoding='utf-8', errors='replace').read()
    root = ROOT.replace('\\', '/').lower() + '/'
    files = set()
    for m in re.finditer(r"synthesizing module '[^']+' \[(.+?):\d+\]", text):
        p = m.group(1).replace('\\', '/')
        if p.lower().startswith(root) and '/rtl/' in p.lower():
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
    if len(sys.argv) == 3 and sys.argv[1] == '--check':
        stale = []
        for line in open(sys.argv[2], encoding='utf-8'):
            if not line.strip() or line.startswith('#'):
                continue
            h, p = line.split(None, 1)
            p = p.strip()
            if not os.path.exists(os.path.join(ROOT, p)) or sha(p) != h:
                stale.append(p)
        for p in stale:
            print('changed since the build: ' + p)
        sys.exit(1 if stale else 0)
    if len(sys.argv) not in (2, 3):
        sys.exit(__doc__)
    files = used_files(sys.argv[1])
    if not files:
        sys.exit('no project sources named in ' + sys.argv[1])
    snap = {}
    if len(sys.argv) == 3:
        for line in open(sys.argv[2], encoding='utf-8'):
            if line.strip():
                h, p = line.split(None, 1)
                snap[p.strip().lstrip('*').replace('\\', '/')] = h
    for p in files:
        if snap and p not in snap:
            sys.exit(p + ' is not in the snapshot ' + sys.argv[2])
        print('%s  %s' % (snap.get(p) or sha(p), p))


if __name__ == '__main__':
    main()
