"""mkreplay.py - a game's drawing lists (JSON from DuckStation's RAM, see texcache_model.py) as GP0
words for sim/tb_ps1_replay.v: sim/roms/ps1/replay.hex (game data: kept out of the tree).

    python tools/ps1/mkreplay.py build/syphon_drawlists.json [FIRST_LIST] [LISTS]
"""
import json, os, sys
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..')
lists = json.load(open(sys.argv[1]))
first = int(sys.argv[2]) if len(sys.argv) > 2 else 0
n = int(sys.argv[3]) if len(sys.argv) > 3 else 4
words = [w for fr in lists[first:first + n] for pk in fr['packets'] for w in pk]
out = os.path.join(ROOT, 'sim', 'roms', 'ps1', 'replay.hex')
open(out, 'w').write('%08x\n' % len(words) + ''.join('%08x\n' % w for w in words))
print('%d words from %d lists -> %s' % (len(words), n, out))
