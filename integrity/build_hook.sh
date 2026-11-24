#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
#
# Builds the Play Integrity hook dex: javac the io.github.david568303.pi
# sources against android.jar + BouncyCastle, then R8 the result into a single
# classes.dex whose only kept name is Hooks.chain (see hook.pro). BouncyCastle
# is bundled and repackaged here, not taken from the platform's hidden
# com.android.internal copy, so the hook does not depend on a grey-listed API
# and cannot be shadowed by an app's own BouncyCastle.
#
# Driven by rooted-ota.sh (buildIntegrityHook); all heavy inputs are passed in
# so this stays a pure, offline compile step.
#
# Usage: build_hook.sh <output-dex>
# Env:
#   ANDROID_JAR  android.jar to compile/link against (library, not bundled)
#   BC_JARS      space-separated BouncyCastle jars (bcprov + bcpkix + bcutil),
#                bundled. bcutil is required: bcpkix's cert/signer builders pull
#                in its ASN.1 OID registries transitively, and a missing one
#                only surfaces as a runtime NoClassDefFoundError (R8 cannot warn
#                about it through hook.pro's -dontwarn org.bouncycastle.**).
#   R8_JAR       r8.jar, providing com.android.tools.r8.R8
#   MIN_API      optional dex min API level (default 34)

set -o errexit -o nounset -o pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: build_hook.sh <output-dex>" >&2
  exit 2
fi
outDex="$1"
minApi="${MIN_API:-34}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for var in ANDROID_JAR R8_JAR BC_JARS; do
  if [[ -z "${!var:-}" ]]; then
    echo "build_hook.sh: $var must be set" >&2
    exit 1
  fi
done
if [[ ! -f "$ANDROID_JAR" ]]; then echo "build_hook.sh: ANDROID_JAR not found: $ANDROID_JAR" >&2; exit 1; fi
if [[ ! -f "$R8_JAR" ]]; then echo "build_hook.sh: R8_JAR not found: $R8_JAR" >&2; exit 1; fi

# BC_JARS is a space-separated list; verify each exists.
read -r -a bcJars <<< "$BC_JARS"
for jar in "${bcJars[@]}"; do
  if [[ ! -f "$jar" ]]; then echo "build_hook.sh: BouncyCastle jar not found: $jar" >&2; exit 1; fi
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
classes="$work/classes"
mkdir -p "$classes"

# Compile against android.jar + BouncyCastle. BouncyCastle jars are only on the
# compile classpath here; R8 pulls their bytecode in as program input below.
mapfile -t srcs < <(find "$here/src" -name '*.java' | sort)
cp="$ANDROID_JAR"
for jar in "${bcJars[@]}"; do cp="$cp:$jar"; done
echo "build_hook.sh: compiling ${#srcs[@]} sources"
javac -encoding UTF-8 --release 17 -nowarn -cp "$cp" -d "$classes" "${srcs[@]}"

jar --create --file "$work/program.jar" -C "$classes" .

# R8: shrink + obfuscate + repackage + dex. android.jar is the library (its
# java.*/android.* are not emitted); our classes and BouncyCastle are program
# inputs and get repackaged into io.github.david568303.pi.
out="$work/out"
mkdir -p "$out"
mappingOut="$(dirname "$outDex")/mapping.txt"
echo "build_hook.sh: R8 (min-api $minApi)"
java -cp "$R8_JAR" com.android.tools.r8.R8 \
  --release \
  --min-api "$minApi" \
  --pg-conf "$here/hook.pro" \
  --lib "$ANDROID_JAR" \
  --output "$out" \
  --pg-map-output "$out/mapping.txt" \
  "$work/program.jar" "${bcJars[@]}"

if [[ ! -f "$out/classes.dex" ]]; then
  echo "build_hook.sh: R8 produced no classes.dex" >&2
  exit 1
fi
if [[ ! -s "$out/mapping.txt" ]]; then
  echo "build_hook.sh: R8 mapping file missing or empty" >&2
  exit 1
fi

mkdir -p "$(dirname "$outDex")"
cp "$out/classes.dex" "$outDex"
cp "$out/mapping.txt" "$mappingOut"

echo "build_hook.sh: wrote $outDex ($(stat -c%s "$outDex") bytes)"
echo "build_hook.sh: saved R8 mapping to $mappingOut"
