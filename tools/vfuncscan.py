"""Finds two Verilog function patterns that xsim (2026.1) simulates wrongly
while synthesis gets them right:

  1. a user function called inside another user function call's arguments,
     inside a for loop (in a function or an always block)
     (xsim hands the inner call the PREVIOUS call's result);
  2. a function that reads module signals it is not passed, called from an
     assign, a `wire x = ...`, or an always @(*) (it is only re-evaluated when
     its arguments change, so the value goes stale).

    python tools/vfuncscan.py rtl/*.v          (exit status 1 if anything is found)
"""
import re
import sys

KW = set('begin end if else case casez casex endcase default for integer reg wire input output signed '
         'automatic function endfunction while repeat assign always posedge negedge or and not localparam '
         'parameter genvar generate endgenerate'.split())
FUNC = r'function\s+(?:automatic\s+)?(?:signed\s+)?(?:\[[^\]]*\]\s*)?(\w+)\s*;(.*?)endfunction'


def scan(path):
    found = False
    src = re.sub(r'//[^\n]*', '', open(path).read())
    params = set(re.findall(r'(?:localparam|parameter)\s+(?:\[[^\]]*\]\s*)?(\w+)', src))
    for decl in re.findall(r'localparam[^;]*;', src):
        params |= set(re.findall(r',\s*(\w+)\s*=', decl))
    funcs = {}
    for m in re.finditer(FUNC, src, re.S):
        name, body = m.group(1), m.group(2)
        locs = set()
        for decl in re.findall(r'(?:input|reg|integer|wire)\s+(?:signed\s+)?(?:\[[^\]]*\]\s*)?([\w\s,]+?);', body):
            locs |= set(x.strip() for x in decl.split(','))
        body = re.sub(r"\d*'[sS]?[bhdoBHDO][0-9a-fA-FxXzZ_]+", '', body)
        body = re.sub(r'\$\w+', '', body)
        funcs[name] = set(re.findall(r'\b([A-Za-z_]\w*)\b', body)) - KW - locs - params - {name}
    if not funcs:
        return False
    fpat = r'\b(%s)\s*\(' % '|'.join(funcs)

    # 1: a call inside another call's arguments, within a for loop's body (outside a
    # loop xsim gets it right)
    lines = src.split('\n')
    in_loop = [False] * len(lines)
    for ln, line in enumerate(lines):
        if not re.search(r'\bfor\s*\(', line):
            continue
        in_loop[ln] = True
        tail = line[re.search(r'\bfor\s*\(', line).end():]
        if re.search(r'\bbegin\b', tail):                   # a begin ... end body: mark to its end
            depth = len(re.findall(r'\bbegin\b', tail)) - len(re.findall(r'\bend\b', tail))
            j = ln + 1
            while depth > 0 and j < len(lines):
                in_loop[j] = True
                depth += len(re.findall(r'\bbegin\b', lines[j])) - len(re.findall(r'\bend\b', lines[j]))
                j += 1
        elif not re.search(r';', tail.split(')', 1)[-1] if ')' in tail else ''):
            if ln + 1 < len(lines):
                in_loop[ln + 1] = True                      # a one-statement body on the next line
    for ln, line in enumerate(lines, 1):
        if not in_loop[ln - 1]:
            continue
        for m in re.finditer(fpat, line):
            depth, i = 1, m.end()
            while i < len(line) and depth:
                depth += line[i] == '('
                depth -= line[i] == ')'
                i += 1
            if re.search(fpat, line[m.end():i - 1]):
                print('%s:%d NESTED  %s' % (path, ln, line.strip()[:100]))
                found = True
                break

    # 2: hidden state read from a continuous context
    hidden = {f: ids - set(funcs) for f, ids in funcs.items() if ids - set(funcs)}
    for f, ids in funcs.items():                 # calling a hidden-state function hides state too
        if f not in hidden and ids & set(hidden):
            hidden[f] = ids & set(hidden)
    if hidden:
        hpat = r'\b(%s)\s*\(' % '|'.join(hidden)
        for m in re.finditer(r'(assign[^;]*;|wire[^;]*=[^;]*;)', src):
            c = re.search(hpat, m.group(1))
            if c:
                print('%s HIDDEN  %s reads %s  | %s' % (path, c.group(1), sorted(hidden[c.group(1)])[:6],
                                                      ' '.join(m.group(1).split())[:90]))
                found = True
        for m in re.finditer(r'always\s*@\s*\(\s*\*\s*\)(.*?)(?=always\s*@|\bendmodule|\bfunction\b|\bassign\b)', src, re.S):
            for c in sorted(set(re.findall(hpat, m.group(1)))):
                print('%s HIDDEN  %s reads %s  | in an always @(*)' % (path, c, sorted(hidden[c])[:6]))
                found = True
    return found


if __name__ == '__main__':
    bad = False
    for p in sys.argv[1:]:
        bad |= scan(p)
    print('vfuncscan: %s' % ('see above' if bad else 'nothing found'))
    sys.exit(1 if bad else 0)
