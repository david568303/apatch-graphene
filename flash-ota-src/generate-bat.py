#!/usr/bin/env python3
"""Generates flash-ota.bat from flash-ota.ps1.

Usage: generate-bat.py [<flash-ota.ps1> [<flash-ota.bat>]]
(defaults: flash-ota.ps1 next to this script -> ../flash-ota.bat)

flash-ota.bat is a thin cmd.exe launcher: it writes the PowerShell logic,
base64-encoded, to a %TEMP% file (so no character in it ever needs
batch-escaping) and decodes+runs it with a single `powershell -Command`
call. rooted-ota.sh runs this at release time on a copy of the script that
has been stamped with the build's avbroot version and repo name.
"""
import base64
import pathlib
import sys

SRC_DIR = pathlib.Path(__file__).resolve().parent
CHUNK = 90


def main() -> int:
    ps1_path = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else SRC_DIR / 'flash-ota.ps1'
    bat_path = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else SRC_DIR.parent / 'flash-ota.bat'
    ps1 = ps1_path.read_bytes()

    b64 = base64.b64encode(ps1).decode('ascii')
    lines = [b64[i:i + CHUNK] for i in range(0, len(b64), CHUNK)]

    out = [
        '@echo off',
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

    bat_path.write_text('\r\n'.join(out), newline='')
    print(f'Wrote {bat_path} ({len(lines)} base64 lines)')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
