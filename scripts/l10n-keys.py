#!/usr/bin/env python3
"""列出原始碼中所有需要翻譯的繁體中文字串（tr／L10n.token 的 key，與其他會經 L10n.display 顯示的中文字串常值）。
排除：註解、標示 l10n-ignore 的行、Commands.swift（送給 agent 的指令內容）、翻譯表本身。"""
import re, glob, sys, json
cjk = re.compile(r'[一-鿿]')
strlit = re.compile(r'"((?:[^"\\]|\\.)*)"')
skip_files = ('L10nTable.swift', 'L10n.swift', 'Commands.swift')
keys = []
for f in sorted(glob.glob('Sources/**/*.swift', recursive=True)):
    if f.endswith(skip_files): continue
    in_multiline = False
    prev = ''
    for line in open(f, encoding='utf-8'):
        st = line.strip()
        if 'l10n-ignore' in prev:
            prev = line
            continue
        prev = line
        if '"""' in st:
            in_multiline = not in_multiline if st.count('"""') == 1 else in_multiline
            continue
        if in_multiline or st.startswith('//') or 'l10n-ignore' in line or 'precondition' in line: continue
        code = line
        for m in strlit.finditer(code):
            k = m.group(1)
            if not cjk.search(k) or '\\(' in k: continue
            k = k.replace('\\n', '\n').replace('\\"', '"')
            if k not in keys: keys.append(k)
if len(sys.argv) > 1 and sys.argv[1] == '--json':
    print(json.dumps(keys, ensure_ascii=False, indent=0))
else:
    for k in keys: print(repr(k))
    print(len(keys), file=sys.stderr)
