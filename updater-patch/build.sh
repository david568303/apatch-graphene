#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
#
# Builds the rooted-graphene patched GrapheneOS Updater APK.
#
# The Updater is a platform app (platform_apis + SettingsLib static libs) and
# cannot be built standalone from the public SDK. Instead this recompiles ONLY
# the classes the patch changes, type-checked by a real compiler against the
# stock app's own classes, and swaps them into the stock APK's dex. Everything
# else in the APK is kept byte-for-byte. The result is re-signed with the OTA
# key. No hand-written smali, no AOSP tree.
#
# Pipeline:
#   1. Extract the stock Updater.apk + framework.jar from the stock OTA.
#   2. Integrity gates (fail closed): structural check of the stock APK, signer
#      pin, and an upstream-source drift check against updater-patch/UPSTREAM.
#   3. dex2jar the framework + stock APK -> javac classpath.
#   4. javac our updater-patch/src/*.java -> d8 -> smali.
#   5. baksmali the stock dex(es), drop stock Service*/Settings*, drop in our
#      recompiled Service*/Settings*/OtaFeed*, reassemble (multidex preserved).
#   6. Repackage (stock resources untouched), zipalign, apksigner sign.
#   7. Verify: signer, package, components/permissions unchanged, classes present.
#
# !!! UNTESTED against a real APK/device in this form. Treat a first green build
# !!! as the start of on-device testing (see updater-patch/README.md), not the
# !!! end. Every step fails closed, so it will error out rather than emit a
# !!! broken Updater.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

STOCK_OTA=''
KEY_OTA=''
CERT_OTA=''
OUT=''
TOOLS_DIR=''
ANDROID_JAR="${ANDROID_JAR:-/usr/lib/android-sdk/platforms/android-23/android.jar}"
DEVICE_ID=''

usage() {
  cat >&2 <<EOF
usage: build.sh --stock-ota <zip> --key-ota <pem> --cert-ota <pem> \\
                --out <apk> --tools-dir <dir> --device <codename> \\
                [--android-jar <android.jar>]

--tools-dir must contain the avbroot and afsr binaries (rooted-ota.sh places
them in .tmp). PASSPHRASE_OTA may be set in the environment for the OTA key.
Set UPDATER_SKIP_DRIFT_CHECK=1 only to build offline; it disables the upstream
source-drift gate and is unsafe for release builds.
EOF
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stock-ota) STOCK_OTA="$2"; shift 2;;
    --key-ota) KEY_OTA="$2"; shift 2;;
    --cert-ota) CERT_OTA="$2"; shift 2;;
    --out) OUT="$2"; shift 2;;
    --tools-dir) TOOLS_DIR="$2"; shift 2;;
    --device) DEVICE_ID="$2"; shift 2;;
    --android-jar) ANDROID_JAR="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; usage;;
  esac
done
[[ -n "$STOCK_OTA" && -n "$KEY_OTA" && -n "$CERT_OTA" && -n "$OUT" && -n "$TOOLS_DIR" && -n "$DEVICE_ID" ]] || usage

# Tool overrides (CI may name these differently).
DEX2JAR="${DEX2JAR:-d2j-dex2jar}"
BAKSMALI="${BAKSMALI:-baksmali}"
SMALI="${SMALI:-smali}"
D8="${D8:-d8}"

say() { printf '\n== %s\n' "$*"; }
die() { printf 'build.sh: %s\n' "$*" >&2; exit 1; }

for tool in java javac unzip zip openssl apksigner zipalign aapt2 sha256sum \
            "$DEX2JAR" "$BAKSMALI" "$SMALI" "$D8"; do
  command -v "$tool" >/dev/null || die "required tool not found: $tool"
done
[[ -f "$ANDROID_JAR" ]] || die "android.jar not found at $ANDROID_JAR"
[[ -x "$TOOLS_DIR/avbroot" || -f "$TOOLS_DIR/avbroot" ]] || die "avbroot not in $TOOLS_DIR"
[[ -x "$TOOLS_DIR/afsr" || -f "$TOOLS_DIR/afsr" ]] || die "afsr not in $TOOLS_DIR"

# shellcheck source=/dev/null
source "$HERE/UPSTREAM"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/updater-build.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
TOOLS_ABS="$(cd "$TOOLS_DIR" && pwd)"

########################################################################
say "1/7 extract stock Updater.apk + framework.jar from $STOCK_OTA"
########################################################################
# Same extraction path the fork's verifyAPatchPartitions uses.
EXDIR="$WORK/system"
mkdir -p "$EXDIR"
"$TOOLS_ABS/avbroot" ota extract --input "$STOCK_OTA" --directory "$EXDIR" --partition system
( cd "$EXDIR" && "$TOOLS_ABS/avbroot" avb unpack --quiet --input system.img \
    && "$TOOLS_ABS/afsr" unpack --input raw.img )
SYSROOT="$EXDIR/fs_tree"
STOCK_APK="$SYSROOT/system/priv-app/Updater/Updater.apk"
FRAMEWORK_JAR="$SYSROOT/system/framework/framework.jar"
[[ -f "$STOCK_APK" ]] || die "stock Updater.apk not found at $STOCK_APK"
[[ -f "$FRAMEWORK_JAR" ]] || die "framework.jar not found at $FRAMEWORK_JAR"

########################################################################
say "2/7 integrity gates"
########################################################################
python3 -I "$HERE/check_updater_target.py" "$STOCK_APK"

# Signer pin: refuse an input that is not GrapheneOS-signed once pinned.
SIGNER="$(apksigner verify --print-certs "$STOCK_APK" \
          | sed -n 's/.*certificate SHA-256 digest: *//p' | head -n1)"
[[ -n "$SIGNER" ]] || die "could not read stock Updater signer"
if [[ -n "${STOCK_UPDATER_SIGNER_SHA256:-}" ]]; then
  [[ "$SIGNER" == "$STOCK_UPDATER_SIGNER_SHA256" ]] \
    || die "stock Updater signer $SIGNER != pinned $STOCK_UPDATER_SIGNER_SHA256"
  echo "stock signer matches pin"
else
  echo "WARNING: STOCK_UPDATER_SIGNER_SHA256 unset in UPSTREAM; record and pin this: $SIGNER"
fi

# Upstream source-drift gate: the files we recompile must still match the pins.
if [[ "${UPDATER_SKIP_DRIFT_CHECK:-0}" == "1" ]]; then
  echo "WARNING: UPDATER_SKIP_DRIFT_CHECK=1, skipping upstream source-drift check"
else
  SRC="$WORK/upstream-src"
  git clone --quiet --depth 1 --branch "$UPDATER_SRC_TAG" "$UPDATER_REPO" "$SRC" \
    || die "could not clone $UPDATER_REPO at $UPDATER_SRC_TAG"
  got_service="$(sha256sum "$SRC/src/app/seamlessupdate/client/Service.java" | cut -d' ' -f1)"
  got_settings="$(sha256sum "$SRC/src/app/seamlessupdate/client/Settings.java" | cut -d' ' -f1)"
  [[ "$got_service" == "$BASELINE_Service_java" ]] \
    || die "upstream Service.java changed ($got_service); re-review updater-patch/src and bump UPSTREAM"
  [[ "$got_settings" == "$BASELINE_Settings_java" ]] \
    || die "upstream Settings.java changed ($got_settings); re-review updater-patch/src and bump UPSTREAM"
  echo "upstream source matches the pinned baseline"
fi

########################################################################
say "3/7 dex2jar framework + stock APK -> compile classpath"
########################################################################
"$DEX2JAR" -f -o "$WORK/framework.jar" "$FRAMEWORK_JAR"   >/dev/null 2>&1 || true
"$DEX2JAR" -f -o "$WORK/updater.jar"   "$STOCK_APK"       >/dev/null 2>&1 || true
[[ -f "$WORK/framework.jar" ]] || die "dex2jar failed on framework.jar"
[[ -f "$WORK/updater.jar"   ]] || die "dex2jar failed on Updater.apk"
CP="$ANDROID_JAR:$WORK/framework.jar:$WORK/updater.jar"

########################################################################
say "4/7 javac our sources -> d8 -> smali"
########################################################################
mkdir -p "$WORK/classes" "$WORK/new-dex" "$WORK/smali-new"
javac -encoding UTF-8 -source 17 -target 17 -cp "$CP" \
  -d "$WORK/classes" \
  "$HERE"/src/app/seamlessupdate/client/*.java
# d8 our classes to a dex (min-sdk matches the app; no desugaring needed).
mapfile -t OURCLASSES < <(find "$WORK/classes" -name '*.class')
"$D8" --min-api 36 --output "$WORK/new-dex" --lib "$ANDROID_JAR" "${OURCLASSES[@]}"
"$BAKSMALI" disassemble "$WORK/new-dex/classes.dex" -o "$WORK/smali-new"

########################################################################
say "5/7 swap classes into the stock dex (multidex preserved)"
########################################################################
mkdir -p "$WORK/apk"
( cd "$WORK/apk" && unzip -q "$STOCK_APK" )
shopt -s nullglob
STOCK_DEXES=( "$WORK"/apk/classes*.dex )
shopt -u nullglob
[[ ${#STOCK_DEXES[@]} -ge 1 ]] || die "no classes*.dex in stock APK"

CLIENT_REL="app/seamlessupdate/client"
# Disassemble each stock dex to its own dir and remove the classes we replace.
i=0
SMALI_DIRS=()
for dex in "${STOCK_DEXES[@]}"; do
  i=$((i+1))
  d="$WORK/smali-$i"
  "$BAKSMALI" disassemble "$dex" -o "$d"
  rm -f "$d/$CLIENT_REL/Service.smali" "$d/$CLIENT_REL"/'Service$'*.smali \
        "$d/$CLIENT_REL/Settings.smali" "$d/$CLIENT_REL"/'Settings$'*.smali
  SMALI_DIRS+=( "$d" )
done

# Drop our recompiled classes into the primary dir. Fail if our compile did not
# actually produce the classes we are supposed to be swapping in.
for must in Service OtaFeed Settings; do
  compgen -G "$WORK/smali-new/$CLIENT_REL/$must"'*.smali' >/dev/null \
    || die "recompiled smali missing for $must (javac/d8 output unexpected)"
done
cp "$WORK/smali-new/$CLIENT_REL"/Service*.smali  "${SMALI_DIRS[0]}/$CLIENT_REL/"
cp "$WORK/smali-new/$CLIENT_REL"/Settings*.smali "${SMALI_DIRS[0]}/$CLIENT_REL/"
cp "$WORK/smali-new/$CLIENT_REL"/OtaFeed*.smali  "${SMALI_DIRS[0]}/$CLIENT_REL/"

# Reassemble each dir back to its dex.
i=0
for d in "${SMALI_DIRS[@]}"; do
  i=$((i+1))
  out="classes.dex"; [[ $i -gt 1 ]] && out="classes$i.dex"
  "$SMALI" assemble "$d" -o "$WORK/apk/$out"
done

########################################################################
say "6/7 repackage + zipalign + sign"
########################################################################
rm -rf "$WORK/apk/META-INF"   # drop the old signature
UNSIGNED="$WORK/unsigned.apk"
( cd "$WORK/apk" && rm -f "$UNSIGNED" && zip -q -r -X "$UNSIGNED" . )
ALIGNED="$WORK/aligned.apk"
zipalign -p -f 4 "$UNSIGNED" "$ALIGNED"

PK8="$WORK/key.pk8"
passin=()
[[ -v PASSPHRASE_OTA ]] && passin=(-passin env:PASSPHRASE_OTA)
openssl pkcs8 -topk8 -nocrypt -inform PEM -outform DER "${passin[@]}" -in "$KEY_OTA" -out "$PK8"
# v1 signing off (min-sdk 36); v2/v3 like the labels overlay.
apksigner sign --v1-signing-enabled false --key "$PK8" --cert "$CERT_OTA" \
  --out "$OUT" "$ALIGNED"
rm -f "$PK8"

########################################################################
say "7/7 verify the rebuilt APK"
########################################################################
apksigner verify "$OUT"
NEWSIGNER="$(apksigner verify --print-certs "$OUT" \
             | sed -n 's/.*certificate SHA-256 digest: *//p' | head -n1)"
echo "patched Updater signer: $NEWSIGNER"

# Package + components/permissions must be identical to stock (manifest intact).
badging_stock="$(aapt2 dump badging "$STOCK_APK")"
badging_new="$(aapt2 dump badging "$OUT")"
pkg_stock="$(sed -n "s/^package: name='\([^']*\)'.*/\1/p" <<<"$badging_stock")"
pkg_new="$(sed -n "s/^package: name='\([^']*\)'.*/\1/p" <<<"$badging_new")"
[[ "$pkg_new" == "app.seamlessupdate.client" ]] || die "package changed: $pkg_new"
[[ "$pkg_new" == "$pkg_stock" ]] || die "package differs from stock"
diff <(grep -E '^(uses-permission|permission|launchable-activity|provides-component|application-label):' <<<"$badging_stock" | sort) \
     <(grep -E '^(uses-permission|permission|launchable-activity|provides-component|application-label):' <<<"$badging_new" | sort) \
  || die "manifest components/permissions changed vs stock"

# Our classes must be present in the rebuilt dex, stock Service/Settings gone-and-replaced.
for cls in "Lapp/seamlessupdate/client/OtaFeed;" \
           "Lapp/seamlessupdate/client/Service;" \
           "Lapp/seamlessupdate/client/Settings;"; do
  grep -qaF "$cls" "$WORK"/apk/classes*.dex || die "class missing from rebuilt dex: $cls"
done

sha256sum "$OUT" | tee "$OUT.sha256"
echo "OK: patched Updater at $OUT"
