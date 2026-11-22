#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Splice the Play Integrity hook into AndroidKeyStoreSpi.

There is exactly one insertion point: the head of

  android.security.keystore2.AndroidKeyStoreSpi
    #engineGetCertificateChain(Ljava/lang/String;)[Ljava/security/cert/Certificate;

Right after the method's header directives (.locals/.param/.annotation) and
before the first instruction, insert:

    invoke-static {p1}, Lio/github/david568303/pi/Hooks;->chain(Ljava/lang/String;)[Ljava/security/cert/Certificate;
    move-result-object vN
    if-eqz vN, :pihook_orig
    return-object vN
    :pihook_orig
    <original body>

.locals is bumped by one and vN is the new top local (index = the old .locals
count). A null return from Hooks.chain means "not a targeted caller": execution
falls through :pihook_orig into the untouched original body. This mirrors
UN1CA's own keystore hook shape (salvogiangri/UN1CA, GPL-3.0); the method,
register bookkeeping and fail-closed checks are original to this repository.

Usage: insert_hook.py <baksmali-dir-or-AndroidKeyStoreSpi.smali>
"""
import pathlib
import re
import sys

TARGET_SUFFIX = "android/security/keystore2/AndroidKeyStoreSpi.smali"
METHOD_RE = re.compile(
    r"^\s*\.method\b.*\bengineGetCertificateChain\("
    r"Ljava/lang/String;\)\[Ljava/security/cert/Certificate;\s*$"
)
HOOK = ("Lio/github/david568303/pi/Hooks;->chain("
        "Ljava/lang/String;)[Ljava/security/cert/Certificate;")
LABEL = ":pihook_orig"
# engineGetCertificateChain(String) is an instance method: p0=this, p1=alias -> 2 param registers.
PARAM_REGS = 2


def die(msg):
    print(f"insert_hook.py: {msg}", file=sys.stderr)
    sys.exit(1)


def find_target(arg):
    p = pathlib.Path(arg)
    if p.is_file():
        return p
    if not p.is_dir():
        die(f"not a file or directory: {arg}")
    matches = [m for m in p.rglob("AndroidKeyStoreSpi.smali")
               if str(m).replace("\\", "/").endswith(TARGET_SUFFIX)]
    if not matches:
        die(f"AndroidKeyStoreSpi.smali not found under {arg}")
    if len(matches) > 1:
        die("multiple AndroidKeyStoreSpi.smali found: " + ", ".join(map(str, matches)))
    return matches[0]


def locate_method(lines):
    starts = [i for i, ln in enumerate(lines) if METHOD_RE.match(ln)]
    if not starts:
        die("engineGetCertificateChain(String)[Certificate; not found")
    if len(starts) > 1:
        die("more than one engineGetCertificateChain(String) method")
    start = starts[0]
    end = next((i for i in range(start + 1, len(lines))
                if lines[i].strip() == ".end method"), None)
    if end is None:
        die(".end method not found for engineGetCertificateChain")
    return start, end


def locals_directive(lines, start, end):
    for i in range(start + 1, end):
        s = lines[i].strip()
        if s.startswith(".locals "):
            return i, int(s.split()[1]), "locals"
        if s.startswith(".registers "):
            total = int(s.split()[1])
            return i, total - PARAM_REGS, "registers"
    die("neither .locals nor .registers found (abstract/native method?)")


def skip_param(lines, i, end):
    """Return the index past a .param at line i, whether single-line or a
    `.param ... .annotation ... .end annotation .end param` block. A single-line
    .param (even with a trailing # comment) has no .end param; a block does, and
    its annotation sits right after the .param line."""
    j = i + 1
    while j < end and lines[j].strip() == "":
        j += 1
    if j < end and lines[j].strip().startswith(".annotation"):
        k = j
        while k < end and lines[k].strip() != ".end annotation":
            k += 1
        k += 1
        m = k
        while m < end and lines[m].strip() == "":
            m += 1
        if m < end and lines[m].strip() == ".end param":
            return m + 1          # block form
    return i + 1                   # single-line form


def body_start(lines, after, end):
    """Index of the first opcode/label of the executable body: skip .param and
    method .annotation blocks plus debug directives, so the insertion lands at
    method entry and assembles cleanly."""
    skippable = (".prologue", ".line", ".local", ".restart", ".end local", ".source")
    i = after + 1
    while i < end:
        s = lines[i].strip()
        if s == "" or s.startswith("#"):
            i += 1
            continue
        if s.startswith(".param"):
            i = skip_param(lines, i, end)
            continue
        if s.startswith(".annotation"):
            while i < end and lines[i].strip() != ".end annotation":
                i += 1
            i += 1
            continue
        if s.startswith(skippable):
            i += 1
            continue
        return i                   # opcode or label
    die("no method body to insert before")


def main(arg):
    target = find_target(arg)
    text = target.read_text(encoding="utf-8")
    if HOOK in text:
        die(f"{target} already carries the hook (double patch?)")

    lines = text.splitlines()
    start, end = locate_method(lines)
    loc_idx, old_locals, kind = locals_directive(lines, start, end)

    new_local = old_locals          # new top local register index
    # Only invoke-static {p1} (35c form, 4-bit reg fields) constrains us: after
    # the bump p1 sits at v(old_locals+2). Keep it addressable.
    if old_locals + PARAM_REGS > 15:
        die(f"too many locals ({old_locals}); p1 would exceed v15 for invoke-static")
    if new_local > 255:
        die(f"new local v{new_local} exceeds v255")

    # Bump the register count directive by one.
    indent = lines[loc_idx][:len(lines[loc_idx]) - len(lines[loc_idx].lstrip())]
    lines[loc_idx] = f"{indent}.{kind} {old_locals + PARAM_REGS + 1 if kind == 'registers' else old_locals + 1}"

    ins_at = body_start(lines, loc_idx, end)
    block = [
        f"    invoke-static {{p1}}, {HOOK}",
        "",
        f"    move-result-object v{new_local}",
        "",
        f"    if-eqz v{new_local}, {LABEL}",
        "",
        f"    return-object v{new_local}",
        "",
        f"    {LABEL}",
    ]
    lines[ins_at:ins_at] = block

    # Keep the trailing newline the file had.
    out = "\n".join(lines)
    if text.endswith("\n"):
        out += "\n"
    target.write_text(out, encoding="utf-8")
    print(f"insert_hook.py: patched {target} "
          f"(.{kind} {old_locals + (PARAM_REGS if kind == 'registers' else 0)} -> "
          f"{old_locals + PARAM_REGS + 1 if kind == 'registers' else old_locals + 1}, "
          f"new local v{new_local})")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        die("usage: insert_hook.py <baksmali-dir-or-AndroidKeyStoreSpi.smali>")
    main(sys.argv[1])
