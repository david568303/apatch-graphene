#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Splice the Play Integrity hook into AndroidKeyStoreSpi.

Usage: insert_hook.py <smali-dir>
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
PARAM_REGS = 2

# KeyInfo is the app-facing key descriptor; its two secure-hardware accessors
# are the real client-side probes. android.security.keystore.KeyCharacteristics
# is NOT a framework class (the real one is android.security.keymaster.*, with a
# different shape), so it was never a valid target and is dropped. Each hook is a
# gate (see Hooks): a non-zero return makes the splice return the spoofed
# constant; zero falls through to the stock body.
TEE_HOOK_SPECS = [
    (
        "android/security/keystore/KeyInfo.smali",
        "isInsideSecureHardware()Z",
        "Lio/github/david568303/pi/Hooks;->isInsideSecureHardware()Z",
    ),
    (
        "android/security/keystore/KeyInfo.smali",
        "getSecurityLevel()I",
        "Lio/github/david568303/pi/Hooks;->getSecurityLevel()I",
    ),
]


def die(msg):
    print(f"insert_hook.py: {msg}", file=sys.stderr)
    sys.exit(1)


def locate_method(lines, method_re):
    starts = [i for i, ln in enumerate(lines) if method_re.match(ln)]
    if not starts:
        return None
    if len(starts) > 1:
        return None
    start = starts[0]
    end = next((i for i in range(start + 1, len(lines))
                if lines[i].strip() == ".end method"), None)
    if end is None:
        return None
    return start, end


def locals_directive(lines, start, end, param_regs=PARAM_REGS):
    for i in range(start + 1, end):
        s = lines[i].strip()
        if s.startswith(".locals "):
            return i, int(s.split()[1]), "locals"
        if s.startswith(".registers "):
            total = int(s.split()[1])
            return i, total - param_regs, "registers"
    die("neither .locals nor .registers found (abstract/native method?)")


def param_reg_count(method_line):
    """Parameter register count for a .method line: one per argument word (wide
    types J/D take two) plus one for the implicit `this`, unless the method is
    static. PARAM_REGS is the fixed value for the chain method; the TEE methods
    are no-arg, so their count differs and must be derived per method."""
    m = re.search(r"\((.*)\)", method_line)
    desc = m.group(1) if m else ""
    regs, i = 0, 0
    while i < len(desc):
        c = desc[i]
        if c == "L":
            i = desc.index(";", i) + 1
            regs += 1
        elif c == "[":
            i += 1
            while i < len(desc) and desc[i] == "[":
                i += 1
            if i < len(desc) and desc[i] == "L":
                i = desc.index(";", i) + 1
            else:
                i += 1
            regs += 1
        elif c in "JD":
            regs += 2
            i += 1
        else:  # Z B S C I F
            regs += 1
            i += 1
    if not re.search(r"\bstatic\b", method_line.split("(")[0]):
        regs += 1  # implicit `this`
    return regs


def skip_param(lines, i, end):
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
            return m + 1
    return i + 1


def body_start(lines, after, end):
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
        return i
    die("no method body to insert before")


def splice_method(lines, start, end, hook_desc, ret_const_fmt, ret_op_fmt, label):
    param_regs = param_reg_count(lines[start])
    loc_idx, old_locals, kind = locals_directive(lines, start, end, param_regs)
    new_local = old_locals          # the one freed local slot is v(old_locals)
    indent = lines[loc_idx][:len(lines[loc_idx]) - len(lines[loc_idx].lstrip())]
    if kind == "registers":
        lines[loc_idx] = f"{indent}.registers {old_locals + param_regs + 1}"
    else:
        lines[loc_idx] = f"{indent}.locals {old_locals + 1}"

    skippable = (".prologue", ".line", ".local", ".restart", ".end local", ".source")
    i = loc_idx + 1
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
        break

    ins_at = i
    block = [
        f"    invoke-static {{}}, {hook_desc}",
        "",
        f"    move-result v{new_local}",
        "",
        f"    if-eqz v{new_local}, {label}",
        "",
        f"    {ret_const_fmt.format(new_local=new_local)}",
        f"    {ret_op_fmt.format(new_local=new_local)}",
        "",
        f"    {label}",
    ]
    lines[ins_at:ins_at] = block
    return lines


def splice_tee_hooks(smali_root: pathlib.Path) -> None:
    for rel_path, method_sig, hook_desc in TEE_HOOK_SPECS:
        target = smali_root / rel_path
        if not target.is_file():
            print(f"insert_hook.py: TEE target not found, skipping: {rel_path}")
            continue

        text = target.read_text(encoding="utf-8")
        if hook_desc in text:
            print(f"insert_hook.py: {rel_path} already carries {method_sig} hook, skipping")
            continue
        lines = text.splitlines()

        method_re = re.compile(
            r"^\s*\.method\b.*\b" + re.escape(method_sig) + r"\s*$"
        )
        located = locate_method(lines, method_re)
        if located is None:
            print(f"insert_hook.py: method {method_sig} not found in {rel_path}")
            continue

        start, end = located

        # Dalvik has no return-boolean: Z and I are both 32-bit values returned
        # with the plain `return vAA`. The spoofed constant is what the splice
        # returns when the hook gate fires: 0x1 is `true` for ()Z, and
        # SECURITY_LEVEL_TRUSTED_ENVIRONMENT (1) for ()I -- matching the TEE level
        # the forged attestation chain claims (KeyboxChainGenerator).
        if method_sig.endswith("()Z"):
            ret_const_fmt = "const/4 v{new_local}, 0x1"
            ret_op_fmt = "return v{new_local}"
        elif method_sig.endswith("()I"):
            ret_const_fmt = "const/4 v{new_local}, 0x1"
            ret_op_fmt = "return v{new_local}"
        else:
            print(f"insert_hook.py: unsupported return type for {method_sig}, skipping")
            continue

        lines = splice_method(
            lines, start, end, hook_desc,
            ret_const_fmt, ret_op_fmt, ":tee_orig",
        )

        out = "\n".join(lines)
        if text.endswith("\n"):
            out += "\n"
        target.write_text(out, encoding="utf-8")
        print(f"insert_hook.py: spliced TEE hook {method_sig} into {rel_path}")


def main(arg):
    smali_root = pathlib.Path(arg)
    if not smali_root.is_dir():
        die(f"not a directory: {arg}")

    # Find AndroidKeyStoreSpi.smali in this dex (if present)
    target_file = None
    for m in smali_root.rglob("AndroidKeyStoreSpi.smali"):
        if str(m).replace("\\", "/").endswith(TARGET_SUFFIX):
            target_file = m
            break

    if target_file is not None:
        text = target_file.read_text(encoding="utf-8")
        if HOOK in text:
            die(f"{target_file} already carries the hook (double patch?)")

        lines = text.splitlines()
        located = locate_method(lines, METHOD_RE)
        if located is None:
            die("engineGetCertificateChain(String)[Certificate; not found")

        start, end = located
        loc_idx, old_locals, kind = locals_directive(lines, start, end)

        new_local = old_locals
        if old_locals + PARAM_REGS > 15:
            die(f"too many locals ({old_locals}); p1 would exceed v15 for invoke-static")
        if new_local > 255:
            die(f"new local v{new_local} exceeds v255")

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

        out = "\n".join(lines)
        if text.endswith("\n"):
            out += "\n"
        target_file.write_text(out, encoding="utf-8")
        print(f"insert_hook.py: patched {target_file} "
              f"(.{kind} {old_locals + (PARAM_REGS if kind == 'registers' else 0)} -> "
              f"{old_locals + PARAM_REGS + 1 if kind == 'registers' else old_locals + 1}, "
              f"new local v{new_local})")
    else:
        print(f"insert_hook.py: no AndroidKeyStoreSpi in {smali_root}, skipping chain splice")

    # Always try TEE hooks
    splice_tee_hooks(smali_root)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        die("usage: insert_hook.py <smali-dir>")
    main(sys.argv[1])
