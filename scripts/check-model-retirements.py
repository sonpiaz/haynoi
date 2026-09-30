#!/usr/bin/env python3
"""Which models does Haynoi ask for, and when do they stop answering? (W37-1672)

The app names some models directly ("gemini-3.5-flash-lite") and some through
aliases the gateway resolves ("transcribe-quality" -> a dated model that
retires on its own schedule). A source-only check cannot see the second kind.
This reads the public catalog (GET https://kymaapi.com/v1/models: `data[].id`,
`data[].retires_on`, `aliases`), finds every string literal in Sources/ that is
a catalog id or an alias, resolves aliases, and reports retirement dates.

Exit 1 when a model the app uses is gone from the catalog or retires within
--days (default 120). No key needed; nothing is sent but the GET.
"""
import argparse, datetime, glob, json, os, re, sys, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def literals(root, names):
    """Catalog ids and aliases named in Swift code (outside // comments), with file:line.

    Some aliases are plain words ("fast", "code", "search") that the app also uses
    as UI tags or JSON keys. A plain-word alias only counts on a line that says
    "model" or also names a hyphenated model/alias ("transcribe" next to
    "transcribe-quality"). Everything with a hyphen or digit counts as is."""
    found = {}
    plain = lambda s: re.fullmatch(r'[a-z]+', s) is not None
    for path in glob.glob(os.path.join(root, 'Sources', '**', '*.swift'), recursive=True):
        for n, line in enumerate(open(path, encoding='utf-8'), 1):
            code = line.split(' //')[0]
            if code.strip().startswith('//'):
                continue
            lits = [l for l in re.findall(r'"([A-Za-z0-9._:/-]{3,80})"', code) if l in names]
            context = 'model' in code.lower() or any(not plain(l) for l in lits)
            for lit in lits:
                if plain(lit) and not context:
                    continue
                found.setdefault(lit, f'{os.path.relpath(path, root)}:{n}')
    return found

def vanished(seen_file, names, root):
    """Names found on a previous run that the catalog no longer lists but Sources still quote."""
    try:
        before = [l.strip() for l in open(seen_file) if l.strip()]
    except FileNotFoundError:
        return []
    code = '\n'.join(open(p, encoding='utf-8').read()
                     for p in glob.glob(os.path.join(root, 'Sources', '**', '*.swift'), recursive=True))
    return [n for n in before if n not in names and f'"{n}"' in code]

def check(catalog, used, today, days):
    ids = {m['id']: m for m in catalog.get('data', [])}
    aliases = catalog.get('aliases') or {}
    rows, bad = [], []
    for name, where in sorted(used.items()):
        if name not in ids and name not in aliases:
            continue
        target = aliases.get(name, name)
        model = ids.get(target)
        if model is None:
            rows.append((name, target, 'NOT IN CATALOG', where)); bad.append(name); continue
        retires = model.get('retires_on')
        rows.append((name, target, retires or '-', where))
        if retires:
            left = (datetime.date.fromisoformat(retires[:10]) - today).days
            if left <= days:
                bad.append(name)
    return rows, bad

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--days', type=int, default=120)
    ap.add_argument('--catalog', help='read the catalog from a file instead of the network (tests)')
    ap.add_argument('--today', help='YYYY-MM-DD (tests)')
    ap.add_argument('--seen', help='file of names found last run; a name that has left the catalog '
                                   'but is still quoted in Sources is reported (the scan alone cannot see it)')
    a = ap.parse_args()
    if a.catalog:
        catalog = json.load(open(a.catalog))
    else:
        with urllib.request.urlopen('https://kymaapi.com/v1/models', timeout=20) as r:
            catalog = json.load(r)
    today = datetime.date.fromisoformat(a.today) if a.today else datetime.date.today()
    names = {m['id'] for m in catalog.get('data', [])} | set(catalog.get('aliases') or {})
    used = literals(ROOT, names)
    rows, bad = check(catalog, used, today, a.days)
    if a.seen:
        gone = vanished(a.seen, names, ROOT)
        for name in gone:
            rows.append((name, name, 'NO LONGER IN CATALOG', 'seen last run, still in Sources')); bad.append(name)
        with open(a.seen, 'w') as f:
            f.write('\n'.join(sorted(set(used) | set(gone))) + '\n')
    if not rows:
        print('no catalog model or alias found in Sources — the scan itself is broken'); return 1
    for name, target, retires, where in rows:
        via = f' -> {target}' if target != name else ''
        print(f'{name}{via}  retires {retires}  ({where})')
    if bad:
        print(f'ATTENTION within {a.days} days or missing: ' + ', '.join(bad)); return 1
    return 0

if __name__ == '__main__':
    sys.exit(main())
