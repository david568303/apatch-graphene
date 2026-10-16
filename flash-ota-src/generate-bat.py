#!/usr/bin/env python3
"""Regenerates ../flash-ota.bat from flash-ota.ps1 in this directory.

flash-ota.bat is a thin cmd.exe launcher: it writes the PowerShell logic
below, base64-encoded, to a %TEMP% file (so no character in it ever needs
batch-escaping) and decodes+runs it with a single `powershell -Command`
call. Run this script after editing flash-ota.ps1, or after bumping the
AVB_ROOT_VERSION pin (keep it identical to rooted-ota.sh's), and commit the
regenerated flash-ota.bat.
"""
import base64
import pathlib
import re
import sys

SRC_DIR = pathlib.Path(__file__).resolve().parent
PS1_PATH = SRC_DIR / 'flash-ota.ps1'
BAT_PATH = SRC_DIR.parent / 'flash-ota.bat'
CHUNK = 90


def main() -> int:
    ps1 = PS1_PATH.read_bytes()
    m = re.search(rb"\$AvbRootVersion = '([^']+)'", ps1)
    if not m:
        print('Could not find $AvbRootVersion in flash-ota.ps1', file=sys.stderr)
        return 1
    avb_version = m.group(1).decode()

    b64 = base64.b64encode(ps1).decode('ascii')
    lines = [b64[i:i + CHUNK] for i in range(0, len(b64), CHUNK)]

    out = [
        '@echo off',
        f'rem avbroot pin: {avb_version} (checked against rooted-ota.sh by the release build)',
        'setlocal',
        'cd /d "%~dp0"',
        '',
        'where powershell >nul 2>nul',
        'if errorlevel 1 (',
        '  echo This installer needs PowerShell, which ships with every supported version of Windows.',
        '  echo If it is missing, install it from https://aka.ms/PSWindows and re-run this script.',
        '  pause',
        '  exit /b 1',
        ')',
        '',
        'set "B64=%TEMP%\\flash-ota-%RANDOM%.b64"',
        '',
        '> "%B64%" echo ' + lines[0],
    ]
    out += ['>>"%B64%" echo ' + l for l in lines[1:]]
    out += [
        '',
        'powershell -NoProfile -ExecutionPolicy Bypass -Command '
        '"$b64 = (Get-Content -Raw \'%B64%\') -replace \'\\s\',\'\'; '
        '$src = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64)); '
        'Invoke-Expression $src"',
        'set "RC=%errorlevel%"',
        'del "%B64%" >nul 2>nul',
        'exit /b %RC%',
        '',
    ]

    BAT_PATH.write_text('\r\n'.join(out), newline='')
    print(f'Wrote {BAT_PATH} (avbroot pin {avb_version}, {len(lines)} base64 lines)')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
