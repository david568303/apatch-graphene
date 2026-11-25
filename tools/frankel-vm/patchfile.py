#!/usr/bin/env python3
"""Edit files inside an Android ext4 (shared_blocks) image in place, keeping byte
lengths, so the image layout stays valid. Each edit replaces one exact line by the
same line with its first character turned into '#'.

usage: patchfile.py <in.img> <out.img> <path-in-image>::<exact line> [...]
"""
import re
import shutil
import subprocess
import sys

src, out = sys.argv[1], sys.argv[2]
if src != out:
    shutil.copyfile(src, out)
for spec in sys.argv[3:]:
    path, line = spec.split('::', 1)
    stat = subprocess.run(['debugfs', '-R', f'stat {path}', out], capture_output=True, text=True).stdout
    size = int(re.search(r'Size: (\d+)', stat).group(1))
    blocks = []
    for lo, hi, plo, phi in re.findall(r'\((\d+)(?:-(\d+))?\):(\d+)(?:-(\d+))?', stat.split('EXTENTS:')[1]):
        blocks += [int(plo) + i for i in range(int(hi or lo) - int(lo) + 1)]
    data = subprocess.run(['debugfs', '-R', f'cat {path}', out], capture_output=True).stdout
    assert len(data) == size
    old = line.encode()
    assert data.count(old + b'\n') == 1, f'{path}: line not found exactly once: {line!r}'
    new = data.replace(old + b'\n', b'#' + old[1:] + b'\n')
    with open(out, 'r+b') as f:
        for i, b in enumerate(blocks):
            chunk = new[i * 4096:(i + 1) * 4096]
            if not chunk:
                break
            f.seek(b * 4096)
            f.write(chunk)
    check = subprocess.run(['debugfs', '-R', f'cat {path}', out], capture_output=True).stdout
    assert check == new, f'{path}: verify failed'
    print(f'{path}: commented out {line.strip()!r}')
