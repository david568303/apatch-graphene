#!/usr/bin/env bash

# Requires git, jq, and curl

KEY_AVB=${KEY_AVB:-avb.key}
KEY_OTA=${KEY_OTA:-ota.key}
CERT_OTA=${CERT_OTA:-ota.crt}
# Or else, set these env vars
KEY_AVB_BASE64=${KEY_AVB_BASE64:-''}
KEY_OTA_BASE64=${KEY_OTA_BASE64:-''}
CERT_OTA_BASE64=${CERT_OTA_BASE64:-''}

# Set these env vars, or else these params will be queries interactively
# PASSPHRASE_AVB
# PASSPHRASE_OTA

# Enable debug output only after sensitive vars have been set, to reduce risk of leak
DEBUG=${DEBUG:-''}
if [[ -n "${DEBUG}" ]]; then set -x; fi

# Mandatory params
DEVICE_ID=${DEVICE_ID:-} # See here for device IDs https://grapheneos.org/releases
GITHUB_TOKEN=${GITHUB_TOKEN:-''}
GITHUB_REPO=${GITHUB_REPO:-''}

# Optional
# Skip creation of rootless OTA by setting to "true"
SKIP_ROOTLESS=${SKIP_ROOTLESS:-'false'}
# APatch (KernelPatch) is the only rooted flavor. Skip creation of the rooted
# OTA by setting to "true".
SKIP_APATCH=${SKIP_APATCH:-'false'}
# A RAM-booted KernelPatch image is not enough to establish that a flashed,
# verified image works. mustang is only hardware-validated with the pinned
# KernelPatch fork commit (see patchAPatchBootImage); this escape hatch lets
# a build use an unpinned/default KernelPatch version instead and is
# intentionally not exposed by the GitHub workflows.
ALLOW_UNVERIFIED_APATCH=${ALLOW_UNVERIFIED_APATCH:-'false'}
# Publishing an APatch OTA (release assets and/or the Custota feed) requires
# this explicit opt-in, so an automated run never ships an unreviewed APatch
# build; the automatic APatch OTA workflow sets this itself. APatch can still
# be built without publishing via SKIP_RELEASE.
ALLOW_APATCH_RELEASE=${ALLOW_APATCH_RELEASE:-'false'}
# Optional suffix appended to the GitHub release tag (e.g. '-apatch' so APatch
# gets its own release and does not share the stable release's tag), and whether
# that release is marked a GitHub pre-release (shown in the list, never "Latest").
RELEASE_TAG_SUFFIX=${RELEASE_TAG_SUFFIX:-''}
RELEASE_PRERELEASE=${RELEASE_PRERELEASE:-'false'}
# https://grapheneos.org/releases#stable-channel
OTA_VERSION=${OTA_VERSION:-'latest'}

# APatch and its matching KernelPatch tools are resolved from their official
# GitHub releases. "latest" always means the newest stable APatch release.
# renovate: datasource=github-releases packageName=bmax121/APatch versioning=loose
DEFAULT_APATCH_VERSION=11282
APATCH_VERSION=${APATCH_VERSION:-${DEFAULT_APATCH_VERSION}}
APATCH_MANAGER_URL=''
APATCH_MANAGER_SHA256=''
# Preinstall the official signed APatch manager APK into the OTA's system image
# (as a system app under /system/app). Default off: injecting it bootloops
# mustang (the no-embed OTA boots without it, and fails to boot with it), so the
# APK is instead bundled next to the OTA for manual install after boot. Set to
# 'true' only to investigate the injection path.
APATCH_PREINSTALL_MANAGER=${APATCH_PREINSTALL_MANAGER:-'false'}
# APatch 11224 pins KernelPatch 0.13.3, but that image does not boot on
# mustang. KernelPatch 0.13.9 has been verified with a nonpersistent
# `fastboot boot` test on mustang. Keep this independently pinned so Renovate
# can propose later KernelPatch releases without silently changing builds.
# renovate: datasource=github-releases packageName=bmax121/KernelPatch versioning=loose
DEFAULT_KERNELPATCH_VERSION=0.13.9
KERNELPATCH_VERSION=${KERNELPATCH_VERSION:-${DEFAULT_KERNELPATCH_VERSION}}
# Optional immutable source commit in KERNELPATCH_SOURCE_REPO. When set, kpimg
# and kptools are both built from this exact commit. This is intended for
# fixes not contained in the latest release.
KERNELPATCH_COMMIT=${KERNELPATCH_COMMIT:-''}
KERNELPATCH_DISPLAY_VERSION=''
KERNELPATCH_KPIMG_URL=''
KERNELPATCH_KPIMG_SHA256=''
KERNELPATCH_KPTOOLS_URL=''
KERNELPATCH_KPTOOLS_SHA256=''
APATCH_BOOT_IMAGE=''

# Fork of bmax121/KernelPatch carrying fixes not yet upstream.
KERNELPATCH_SOURCE_REPO=${KERNELPATCH_SOURCE_REPO:-'https://github.com/david568303/KernelPatch.git'}
KERNELPATCH_TOOLCHAIN_URL='https://armkeil.blob.core.windows.net/developer/Files/downloads/gnu/12.2.rel1/binrel/arm-gnu-toolchain-12.2.rel1-x86_64-aarch64-none-elf.tar.xz'
KERNELPATCH_TOOLCHAIN_SHA256='62d66e0ad7bd7f2a183d236ee301a5c73c737c886c7944aa4f39415aab528daf'
# fix/arm64-mte-image-size in the fork: upstream main ef52c62 plus:
# - kptools reserves the region KernelPatch copies its start image to, so the
#   bootloader cannot place the ramdisk/DTB there
# - cred offset scans stay inside the slab object; GrapheneOS enables MTE with
#   kasan.fault=panic, and the out-of-bounds read was the mustang "Early
#   Kernel PANIC" (reproduced in QEMU with mte=on)
# Used by every device (resolveAPatchRelease defaults KERNELPATCH_COMMIT to
# this when unset), not just mustang.
KERNELPATCH_FORK_COMMIT='280d32d967feb7ddc0fd1848aa1d1388807945d5'

# Ship the APatch OTAs with a static overlay that points the on-device GrapheneOS
# Updater at this repo's rolling release (UPDATER_FEED_TAG) instead of
# releases.grapheneos.org, and publish each built OTA there for it to find. Off
# by default: nothing is overlaid or published unless this is 'true'.
# buildUpdaterOverlay needs aapt, aapt2, apksigner and openssl on the PATH plus
# an android.jar (Debian/Ubuntu: aapt apksigner libandroid-23-java).
UPDATER_FEED=${UPDATER_FEED:-'false'}
UPDATER_FEED_TAG=${UPDATER_FEED_TAG:-'ota'}
ANDROID_JAR=${ANDROID_JAR:-/usr/lib/android-sdk/platforms/android-23/android.jar}

SKIP_CLEANUP=${SKIP_CLEANUP:-''}

# For committing to GH pages in different repo, clone it to a different folder and set this var
PAGES_REPO_FOLDER=${PAGES_REPO_FOLDER:-''}

# Set asset released by this script to latest version, even when OTA_VERSION already exists for this device
FORCE_OTA_SERVER_UPLOAD=${FORCE_OTA_SERVER_UPLOAD:-'false'}
# Forces the artifacts to be built (and uploaded to a release)
# even it a release already contains the combination of device and flavor.
# This will lead to multiple artifacts with different commits on the release (that are not linked in the OTA server and thus are likely never used).
# However, except for test builds, we want the changes to be rolled out with new version.
# So these artifacts are just a waste of storage resources. Example
# shiba-2025020500-3e0add9-rootless.zip
# shiba-2025020500-6718632-rootless.zip
FORCE_BUILD=${FORCE_BUILD:-'false'}
# Skip setting asset released by this script to latest version, even when OTA_VERSION is latest for this device
# Takes precedence over FORCE_OTA_SERVER_UPLOAD
SKIP_OTA_SERVER_UPLOAD=${SKIP_OTA_SERVER_UPLOAD:-'false'}
# Skip patching modules (custota and oemunlockunboot) into OTA
SKIP_MODULES=${SKIP_MODULES:-'false'}
# Upload OTA to test folder on OTA server
UPLOAD_TEST_OTA=${UPLOAD_TEST_OTA:-false}

OTA_CHANNEL=${OTA_CHANNEL:-stable-security-preview} # Alternative: 'stable' or 'alpha'
NO_COLOR=${NO_COLOR:-''}
OTA_BASE_URL="https://releases.grapheneos.org"

# renovate: datasource=github-releases packageName=chenxiaolong/avbroot versioning=semver
AVB_ROOT_VERSION=3.37.0
# renovate: datasource=github-releases packageName=chenxiaolong/Custota versioning=semver-coerced
CUSTOTA_VERSION=6.7
# renovate: datasource=git-refs packageName=https://github.com/chenxiaolong/my-avbroot-setup currentValue=master
PATCH_PY_COMMIT=4c7d09c0eda8cb03c859d8315ea748e1978a8a35
# renovate: datasource=docker packageName=python
PYTHON_VERSION=3.14.8-alpine
# renovate: datasource=github-releases packageName=chenxiaolong/OEMUnlockOnBoot versioning=semver-coerced
OEMUNLOCKONBOOT_VERSION=1.4
# renovate: datasource=github-releases packageName=chenxiaolong/afsr versioning=semver
AFSR_VERSION=2.0.0

CHENXIAOLONG_PK='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDOe6/tBnO7xZhAWXRj3ApUYgn+XZ0wnQiXM8B7tPgv4'
GIT_PUSH_RETRIES=10

set -o nounset -o pipefail -o errexit

declare -A POTENTIAL_ASSETS

function generateKeys() {
  downloadAvBroot
  # https://github.com/chenxiaolong/avbroot/tree/077a80f4ce7233b0e93d4a1477d09334af0da246#generating-keys
  # Generate the AVB and OTA signing keys.
  .tmp/avbroot key generate-key -o $KEY_AVB
  .tmp/avbroot key generate-key -o $KEY_OTA

  # Convert the public key portion of the AVB signing key to the AVB public key metadata format.
  # This is the format that the bootloader requires when setting the custom root of trust.
  .tmp/avbroot key extract-avb -k $KEY_AVB -o avb_pkmd.bin

  # Generate a self-signed certificate for the OTA signing key. This is used by recovery to verify OTA updates when sideloading.
  .tmp/avbroot key generate-cert -k $KEY_OTA -o $CERT_OTA

  echo Upload these to your CI server, if necessary.
  echo The script takes these values as env or file
  key2base64
}

function key2base64() {
  KEY_AVB_BASE64=$(base64 -w0 "$KEY_AVB") && echo "KEY_AVB_BASE64=$KEY_AVB_BASE64"
  KEY_OTA_BASE64=$(base64 -w0 "$KEY_OTA") && echo "KEY_OTA_BASE64=$KEY_OTA_BASE64"
  CERT_OTA_BASE64=$(base64 -w0 "$CERT_OTA") && echo "CERT_OTA_BASE64=$CERT_OTA_BASE64"
  export KEY_AVB_BASE64 KEY_OTA_BASE64 CERT_OTA_BASE64
}

function createAndReleaseRootedOta() {
  if [[ "$SKIP_APATCH" != 'true' && "$ALLOW_APATCH_RELEASE" != 'true' ]]; then
    printRed 'Publishing an APatch OTA requires an explicit opt-in (ALLOW_APATCH_RELEASE=true).'
    printRed 'Set SKIP_APATCH=true to release the rootless flavor only, or SKIP_RELEASE to build APatch without publishing.'
    exit 1
  fi

  createRootedOta
  releaseOta
  if [[ "$UPDATER_FEED" == 'true' && "${POTENTIAL_ASSETS['apatch']+isset}" ]]; then
    publishUpdaterFeed
  fi

  # APatch releases publish downloadable assets but deliberately do not update
  # the Custota OTA feed, so a new (possibly-not-yet-validated) APatch build is
  # never pushed to users as a seamless auto-update — they opt in by flashing.
  if [[ "${SKIP_OTA_SERVER_UPLOAD:-false}" == 'true' ]]; then
    printGreen "SKIP_OTA_SERVER_UPLOAD set, not updating the Custota OTA feed."
  else
    createOtaServerData
    uploadOtaServerData
  fi
}

function createRootedOta() {
  [[ "$SKIP_CLEANUP" != 'true' ]] && trap cleanup EXIT ERR

  findLatestVersion
  checkBuildNecessary
  downloadAndroidDependencies
  patchOTAs
}

function cleanup() {
  print "Cleaning up..."
  rm -rf .tmp
  unset KEY_AVB_BASE64 KEY_OTA_BASE64 CERT_OTA_BASE64
  print "Cleanup complete."
}

function checkBuildNecessary() {
  local currentCommit
  currentCommit=$(git rev-parse --short HEAD)
  POTENTIAL_ASSETS=()
    
  if [[ "$SKIP_APATCH" != 'true' ]]; then
    resolveAPatchRelease
    # e.g. mustang-2026092501-4647f74-apatch-11224-kp0.13.3-test.zip
    POTENTIAL_ASSETS['apatch']="${DEVICE_ID}-${OTA_VERSION}-${currentCommit}-apatch-${APATCH_VERSION}-kp${KERNELPATCH_DISPLAY_VERSION}$(createAssetSuffix).zip"
  else
    printGreen "SKIP_APATCH set, not creating APatch OTA"
  fi
  
  if [[ "$SKIP_ROOTLESS" != 'true' ]]; then
    POTENTIAL_ASSETS['rootless']="${DEVICE_ID}-${OTA_VERSION}-${currentCommit}-rootless$(createAssetSuffix).zip"
  else
    printGreen "SKIP_ROOTLESS set, not creating rootless OTA"
  fi

  RELEASE_ID=''
  local response

  if [[ -z "$GITHUB_REPO" ]]; then print "Env Var GITHUB_REPO not set, skipping check for existing release" && return; fi

  local releaseTag="${OTA_VERSION}${RELEASE_TAG_SUFFIX}"
  print "Potential release: ${releaseTag}"

  local params=()
  local url="https://api.github.com/repos/${GITHUB_REPO}/releases"

  if [ -n "${GITHUB_TOKEN}" ]; then
    params+=("-H" "Authorization: token ${GITHUB_TOKEN}")
  fi

  params+=("-H" "Accept: application/vnd.github.v3+json")
  response=$(
    curl --fail -sL "${params[@]}" "${url}" |
      jq --arg release_tag "${releaseTag}" '.[] | select(.tag_name == $release_tag) | {id, tag_name, name, published_at, assets}'
  )

  if [[ -n ${response} ]]; then
    RELEASE_ID=$(echo "${response}" | jq -r '.id')
    print "Release ${releaseTag} exists. ID=$RELEASE_ID"
    
    for flavor in "${!POTENTIAL_ASSETS[@]}"; do
      local selectedAsset POTENTIAL_ASSET_NAME="${POTENTIAL_ASSETS[$flavor]}"
      print "Checking if asset exists ${POTENTIAL_ASSET_NAME}"
      
      # Save some storage by not building and uploading every new commit as asset
      selectedAsset=$(echo "${response}" | jq -r --arg assetPrefix "${DEVICE_ID}-${OTA_VERSION}" \
        '.assets[] | select(.name | startswith($assetPrefix)) | .name' \
          | grep "${flavor}" || true)
  
      if [[ -n "${selectedAsset}" ]] && [[ "$FORCE_BUILD" != 'true' ]] && [[ "$UPLOAD_TEST_OTA" != 'true' ]]; then
        printGreen "Skipping build of asset name '$POTENTIAL_ASSET_NAME'. Because this flavor already is released with a different commit." \
          "Set FORCE_BUILD or UPLOAD_TEST_OTA to force. Assets found on release: ${selectedAsset//$'\n'/ }"
        unset "POTENTIAL_ASSETS[$flavor]"
      else
        print "No asset found with name '$POTENTIAL_ASSET_NAME'."
      fi
    done
    
    if [ "${#POTENTIAL_ASSETS[@]}" -eq 0 ]; then
      printGreen "All potential assets already exist. Exiting"
      exit 0
    fi
  else
    print "Release ${OTA_VERSION} does not exist."
  fi
}

function checkMandatoryVariable() {
  for var_name in "$@"; do
    local var_value="${!var_name}"

    if [[ -z "$var_value" ]]; then
      printRed "Missing mandatory param $var_name"
      exit 1
    fi
  done
}

# Emits a GitHub Actions matrix of only the devices that still need a build for
# the current GrapheneOS version, so idle scheduled runs can spawn a single gate
# job instead of one job per device. Writes `matrix=<json>` and `any=true|false`
# (append to $GITHUB_OUTPUT).
#
# Fail-safe: any lookup error includes the device, so a flaky API never silently
# skips a needed build. release-single still runs its own checkBuildNecessary, so
# an over-inclusive matrix just early-exits cheaply. If every lookup fails, every
# device is included and behaviour matches the pre-gate workflow.
#
# Usage: emitBuildMatrix <flavorKeyword> <device> [<device> ...]
function emitBuildMatrix() {
  local flavor="$1"; shift
  local releases params=(-H "Accept: application/vnd.github.v3+json")
  [[ -n "${GITHUB_TOKEN:-}" ]] && params+=(-H "Authorization: token ${GITHUB_TOKEN}")
  releases=$(curl --fail -sL "${params[@]}" "https://api.github.com/repos/${GITHUB_REPO}/releases" 2>/dev/null) || releases=''

  local include=() dev ver assets
  for dev in "$@"; do
    ver=$(curl --fail -sL "$OTA_BASE_URL/$dev-$OTA_CHANNEL" 2>/dev/null | head -n1 | awk '{print $1}') || ver=''
    if [[ -n "$ver" && -n "$releases" ]]; then
      # Search assets across all releases so a flavor in its own release tag
      # (e.g. APatch's pre-release) is still detected. The asset name carries
      # the device, version and flavor, so it is matched directly.
      assets=$(jq -r '.[].assets[].name' <<<"$releases" 2>/dev/null) || assets=''
      # Already built for this version/flavor -> skip it.
      if grep -q -E "^${dev}-${ver}-.*${flavor}" <<<"$assets"; then
        continue
      fi
    fi
    include+=("{\"device-id\":\"${dev}\"}")
  done

  local joined
  joined=$(IFS=,; echo "${include[*]:-}")
  echo "matrix={\"include\":[${joined}]}"
  if [[ ${#include[@]} -gt 0 ]]; then echo "any=true"; else echo "any=false"; fi
}

function createAssetSuffix() {
  local suffix=''
  if [[ "${SKIP_MODULES}" == 'true' ]]; then
    suffix+='-minimal'
  fi 
  if [[ "${UPLOAD_TEST_OTA}" == 'true' ]]; then
    suffix+='-test'
  fi
  if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
    suffix+='-dirty'
  fi
  echo "$suffix"
}

function downloadAndroidDependencies() {
  checkMandatoryVariable 'OTA_TARGET'

  mkdir -p .tmp
  if [[ "${POTENTIAL_ASSETS['apatch']+isset}" ]]; then
    downloadAPatchDependencies
  fi

  if ! ls ".tmp/$OTA_TARGET.zip" >/dev/null 2>&1; then
    curl --fail -sLo ".tmp/$OTA_TARGET.zip" "$OTA_URL"
  fi
}

function findLatestVersion() {
  checkMandatoryVariable DEVICE_ID

  if [[ "$SKIP_APATCH" != 'true' ]]; then
    resolveAPatchRelease
    print "APatch version: $APATCH_VERSION; KernelPatch version: $KERNELPATCH_DISPLAY_VERSION"
    print "Install the matching official APatch manager after flashing: $APATCH_MANAGER_URL"
  fi

  # Search for a new version grapheneos.
  # e.g. https://releases.grapheneos.org/shiba-stable

  if [[ "$OTA_VERSION" == 'latest' ]]; then
    OTA_VERSION=$(curl --fail -sL "$OTA_BASE_URL/$DEVICE_ID-$OTA_CHANNEL" | head -n1 | awk '{print $1;}')
  fi
  GRAPHENE_TYPE=${GRAPHENE_TYPE:-'ota_update'} # Other option: factory
  OTA_TARGET="$DEVICE_ID-$GRAPHENE_TYPE-$OTA_VERSION"
  OTA_URL="$OTA_BASE_URL/$OTA_TARGET.zip"
  # e.g.  shiba-ota_update-2023121200
  print "OTA target: $OTA_TARGET; OTA URL: $OTA_URL"
}

function githubApiGet() {
  local url="$1"
  local params=(--fail --retry 3 --retry-all-errors -sL \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28')

  if [[ -n "$GITHUB_TOKEN" ]]; then
    params+=(-H "Authorization: Bearer $GITHUB_TOKEN")
  fi

  curl "${params[@]}" "$url"
}

function validateReleaseVersion() {
  local name="$1"
  local value="$2"
  if [[ ! "$value" =~ ^[A-Za-z0-9._+-]+$ ]]; then
    printRed "Invalid $name: $value"
    exit 1
  fi
}

function githubAssetMetadata() {
  local releaseJson="$1"
  local assetName="$2"
  local assetJson digest

  assetJson=$(jq -cer --arg name "$assetName" \
    '([.assets[] | select(.name == $name)] | first) // error("release asset not found: " + $name)' \
    <<< "$releaseJson")
  digest=$(jq -er '.digest' <<< "$assetJson")
  if [[ "$digest" != sha256:* || ! "${digest#sha256:}" =~ ^[0-9a-f]{64}$ ]]; then
    printRed "GitHub did not provide a valid SHA-256 digest for $assetName"
    exit 1
  fi

  jq -cn \
    --arg url "$(jq -er '.browser_download_url' <<< "$assetJson")" \
    --arg sha256 "${digest#sha256:}" \
    '{url: $url, sha256: $sha256}'
}

# Prints the KernelPatch version an APatch release pins. Older APatch tags
# state it as a literal in build.gradle.kts; newer ones compute it from the
# MAJOR/MINOR/PATCH defines in app/src/main/cpp/version. Fails loudly if neither
# layout yields a version, instead of a silent exit from a failed grep.
function apatchPinnedKernelPatchVersion() {
  local raw="https://raw.githubusercontent.com/bmax121/APatch/$1" gradle header version
  gradle=$(curl --fail --retry 3 -sL "$raw/build.gradle.kts")
  version=$(sed -nE 's/.*project\.ext\.set\("kernelPatchVersion", "([A-Za-z0-9._+-]+)"\).*/\1/p' <<< "$gradle" | head -n1)
  if [[ -z "$version" ]]; then
    header=$(curl --fail --retry 3 -sL "$raw/app/src/main/cpp/version")
    version=$(awk '$1 == "#define" && $2 ~ /^(MAJOR|MINOR|PATCH)$/ { v[$2] = $3 } END { if (v["MAJOR"] != "" && v["MINOR"] != "" && v["PATCH"] != "") print v["MAJOR"] "." v["MINOR"] "." v["PATCH"] }' <<< "$header")
  fi
  validateReleaseVersion "KernelPatch version pinned by APatch $1" "$version"
  echo "$version"
}

function resolveAPatchRelease() {
  local endpoint releaseJson managerJson
  local kernelReleaseJson='' kpimgJson kptoolsJson

  # Every device builds APatch's KernelPatch from this repo's fork (not the
  # official release): it carries fixes GrapheneOS's kernel needs (notably
  # the MTE-safe cred scan) that upstream does not have yet. Only mustang is
  # hardware-validated on it so far; other devices are untested here, same
  # as they were untested on the official release before this changed.
  : "${KERNELPATCH_COMMIT:=$KERNELPATCH_FORK_COMMIT}"

  if [[ -n "$APATCH_MANAGER_URL" && -n "$KERNELPATCH_KPIMG_URL" && -n "$KERNELPATCH_KPTOOLS_URL" ]]; then
    return
  fi

  if [[ "$APATCH_VERSION" == 'latest' ]]; then
    endpoint='https://api.github.com/repos/bmax121/APatch/releases/latest'
  else
    validateReleaseVersion 'APATCH_VERSION' "$APATCH_VERSION"
    endpoint="https://api.github.com/repos/bmax121/APatch/releases/tags/$APATCH_VERSION"
  fi

  releaseJson=$(githubApiGet "$endpoint")
  if [[ "$(jq -er '.draft' <<< "$releaseJson")" != 'false' || "$(jq -er '.prerelease' <<< "$releaseJson")" != 'false' ]]; then
    printRed "Refusing to use a draft or prerelease APatch release"
    exit 1
  fi

  APATCH_VERSION=$(jq -er '.tag_name' <<< "$releaseJson")
  validateReleaseVersion 'APATCH_VERSION' "$APATCH_VERSION"

  managerJson=$(jq -cer --arg prefix "APatch_${APATCH_VERSION}_" \
    '([.assets[] | select(.name | startswith($prefix)) | select(.name | endswith("-release-signed.apk"))] | first) // error("official signed APatch manager asset not found")' \
    <<< "$releaseJson")
  APATCH_MANAGER_URL=$(jq -er '.browser_download_url' <<< "$managerJson")
  APATCH_MANAGER_SHA256=$(jq -er '.digest' <<< "$managerJson")
  APATCH_MANAGER_SHA256=${APATCH_MANAGER_SHA256#sha256:}
  if [[ ! "$APATCH_MANAGER_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
    printRed "GitHub did not provide a valid SHA-256 digest for the APatch manager"
    exit 1
  fi

  if [[ -z "$KERNELPATCH_VERSION" || "$KERNELPATCH_VERSION" == 'apatch' ]]; then
    KERNELPATCH_VERSION=$(apatchPinnedKernelPatchVersion "$APATCH_VERSION")
  elif [[ "$KERNELPATCH_VERSION" == 'latest' ]]; then
    kernelReleaseJson=$(githubApiGet \
      'https://api.github.com/repos/bmax121/KernelPatch/releases/latest')
    KERNELPATCH_VERSION=$(jq -er '.tag_name' <<< "$kernelReleaseJson")
  fi
  validateReleaseVersion 'KERNELPATCH_VERSION' "$KERNELPATCH_VERSION"

  if [[ -n "$KERNELPATCH_COMMIT" ]]; then
    if [[ ! "$KERNELPATCH_COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
      printRed 'KERNELPATCH_COMMIT must be a full 40-character lowercase commit SHA.'
      exit 1
    fi
    KERNELPATCH_DISPLAY_VERSION="${KERNELPATCH_VERSION}-g${KERNELPATCH_COMMIT:0:7}"
  else
    KERNELPATCH_DISPLAY_VERSION="$KERNELPATCH_VERSION"
  fi

  if [[ -z "$kernelReleaseJson" ]]; then
    kernelReleaseJson=$(githubApiGet \
      "https://api.github.com/repos/bmax121/KernelPatch/releases/tags/$KERNELPATCH_VERSION")
  fi
  kpimgJson=$(githubAssetMetadata "$kernelReleaseJson" 'kpimg-android')
  kptoolsJson=$(githubAssetMetadata "$kernelReleaseJson" 'kptools-linux')
  KERNELPATCH_KPIMG_URL=$(jq -er '.url' <<< "$kpimgJson")
  KERNELPATCH_KPIMG_SHA256=$(jq -er '.sha256' <<< "$kpimgJson")
  KERNELPATCH_KPTOOLS_URL=$(jq -er '.url' <<< "$kptoolsJson")
  KERNELPATCH_KPTOOLS_SHA256=$(jq -er '.sha256' <<< "$kptoolsJson")
}

function downloadVerifiedFile() {
  local targetFile="$1"
  local url="$2"
  local sha256="$3"
  local downloadFile="${targetFile}.download"

  if [[ -f "$targetFile" ]] && echo "$sha256  $targetFile" | sha256sum --check --status; then
    return
  fi

  rm -f "$targetFile" "$downloadFile"
  curl --fail --retry 3 -sLo "$downloadFile" "$url"
  echo "$sha256  $downloadFile" | sha256sum --check --status
  mv "$downloadFile" "$targetFile"
}

function downloadAPatchDependencies() {
  resolveAPatchRelease

  if [[ -s '.tmp/kpimg-android' && -s '.tmp/kptools-linux' ]]; then
    # Supplied by a shared build-kp job (one source build reused by every
    # device), so each device job does not recompile KernelPatch.
    chmod +x '.tmp/kptools-linux' || true
    print "Using pre-supplied KernelPatch kpimg/kptools (shared build)."
  elif [[ -n "$KERNELPATCH_COMMIT" ]]; then
    buildPinnedKernelPatch
  else
    downloadVerifiedFile '.tmp/kptools-linux' "$KERNELPATCH_KPTOOLS_URL" "$KERNELPATCH_KPTOOLS_SHA256"
    chmod +x '.tmp/kptools-linux'
    downloadVerifiedFile '.tmp/kpimg-android' "$KERNELPATCH_KPIMG_URL" "$KERNELPATCH_KPIMG_SHA256"
  fi
}

# Checks out the pinned KernelPatch commit and extracts the pinned aarch64
# toolchain, both idempotent so repeated calls in one job reuse them. Sets
# KERNELPATCH_SOURCE_DIR and KERNELPATCH_COMPILE_PREFIX.
KERNELPATCH_SOURCE_DIR='.tmp/kernelpatch-source'
KERNELPATCH_COMPILE_PREFIX=''
function prepareKernelPatchSource() {
  local sourceDir="$KERNELPATCH_SOURCE_DIR"
  local toolchainArchive='.tmp/kernelpatch-aarch64-toolchain.tar.xz'
  local toolchainDir='.tmp/kernelpatch-toolchain'

  if [[ ! "$KERNELPATCH_COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
    printRed 'KERNELPATCH_COMMIT must be a full 40-character commit SHA to build from source.'
    exit 1
  fi

  if [[ "$(git -C "$sourceDir" rev-parse HEAD 2>/dev/null)" != "$KERNELPATCH_COMMIT" ]]; then
    rm -rf "$sourceDir"
    git init -q "$sourceDir"
    git -C "$sourceDir" remote add origin "$KERNELPATCH_SOURCE_REPO"
    git -C "$sourceDir" fetch --depth 1 origin "$KERNELPATCH_COMMIT"
    git -C "$sourceDir" checkout -q --detach FETCH_HEAD
    if [[ "$(git -C "$sourceDir" rev-parse HEAD)" != "$KERNELPATCH_COMMIT" ]]; then
      printRed 'KernelPatch checkout did not resolve to the requested commit.'
      exit 1
    fi
  fi

  if [[ ! -x "$toolchainDir/bin/aarch64-none-elf-gcc" ]]; then
    downloadVerifiedFile "$toolchainArchive" "$KERNELPATCH_TOOLCHAIN_URL" "$KERNELPATCH_TOOLCHAIN_SHA256"
    rm -rf "$toolchainDir"
    mkdir -p "$toolchainDir"
    tar -xJf "$toolchainArchive" -C "$toolchainDir" --strip-components=1
  fi
  KERNELPATCH_COMPILE_PREFIX="$(pwd)/$toolchainDir/bin/aarch64-none-elf-"
}

function buildPinnedKernelPatch() {
  prepareKernelPatchSource
  local sourceDir="$KERNELPATCH_SOURCE_DIR"
  local compilerPrefix="$KERNELPATCH_COMPILE_PREFIX"

  make -C "$sourceDir/kernel" clean
  make -C "$sourceDir/kernel" hdr kpimg ANDROID=1 TARGET_COMPILE="$compilerPrefix"
  cp "$sourceDir/kernel/kpimg" '.tmp/kpimg-android'
  if [[ ! -s '.tmp/kpimg-android' ]]; then
    printRed 'Pinned KernelPatch build did not produce kpimg-android.'
    exit 1
  fi
  print "Built KernelPatch kpimg from commit $KERNELPATCH_COMMIT ($(sha256sum '.tmp/kpimg-android' | awk '{print $1}'))"

  # kptools must come from the same patched source: some fixes are in the
  # patch tool, not in kpimg.
  ANDROID=1 cmake -S "$sourceDir/tools" -B "$sourceDir/tools/build" -DCMAKE_BUILD_TYPE=Release
  ANDROID=1 cmake --build "$sourceDir/tools/build" -j "$(nproc)"
  cp "$sourceDir/tools/build/kptools" '.tmp/kptools-linux'
  chmod +x '.tmp/kptools-linux'
  print "Built KernelPatch kptools from commit $KERNELPATCH_COMMIT ($(sha256sum '.tmp/kptools-linux' | awk '{print $1}'))"
}

# Builds only the KernelPatch-patched boot.img for hardware testing, without
# signing keys, avbroot OTA patching or any release. Flash it with
# `fastboot flash boot` on stock GrapheneOS of the same OTA_VERSION with an
# unlocked bootloader.
function createAPatchTestBootImage() {
  SKIP_APATCH='false'
  APATCH_BOOT_TEST='true'

  findLatestVersion
  mkdir -p .tmp
  downloadAPatchDependencies
  if ! ls ".tmp/$OTA_TARGET.zip" >/dev/null 2>&1; then
    curl --fail -sLo ".tmp/$OTA_TARGET.zip" "$OTA_URL"
  fi
  downloadAvBroot
  patchAPatchBootImage

  local outDir='.tmp/apatch-test'
  local name="${DEVICE_ID}-${OTA_VERSION}-apatch-boot-kp${KERNELPATCH_DISPLAY_VERSION}"
  local workDir=".tmp/apatch-${DEVICE_ID}-${OTA_VERSION}"
  mkdir -p "$outDir"
  cp "$APATCH_BOOT_IMAGE" "$outDir/$name.img"
  cp "$workDir/extracted/boot.img" "$outDir/${DEVICE_ID}-${OTA_VERSION}-stock-boot.img"
  cp "$workDir/kptools-patch.log" "$outDir/$name.log"
  (cd "$outDir" && sha256sum ./*.img > SHA256SUMS)
  printGreen "APatch test boot image: $outDir/$name.img"
}

function patchAPatchBootImage() {
  local workDir=".tmp/apatch-${DEVICE_ID}-${OTA_VERSION}"
  local extractedDir="$workDir/extracted"

  if [[ "$ALLOW_UNVERIFIED_APATCH" != 'true' && "${APATCH_BOOT_TEST:-}" != 'true' ]]; then
    # Every device builds from the pinned KernelPatch fork commit (only
    # mustang is hardware-validated on it so far). Allow any build that uses
    # the pin; block one that doesn't, so a stray default build can't ship
    # an unpinned image.
    if [[ "$KERNELPATCH_COMMIT" != "$KERNELPATCH_FORK_COMMIT" ]]; then
      printRed 'APatch requires the pinned KernelPatch fork commit.'
      printRed "Set KERNELPATCH_COMMIT=$KERNELPATCH_FORK_COMMIT (or ALLOW_UNVERIFIED_APATCH=true to override)."
      exit 1
    fi
  fi

  APATCH_BOOT_IMAGE="$workDir/new-boot.img"
  if [[ -f "$APATCH_BOOT_IMAGE" ]]; then
    printGreen "File $APATCH_BOOT_IMAGE already exists locally, not patching it again."
    return
  fi

  rm -rf "$workDir"
  mkdir -p "$workDir"
  .tmp/avbroot ota extract \
    --input ".tmp/$OTA_TARGET.zip" \
    --directory "$extractedDir" \
    --partition boot

  cp '.tmp/kptools-linux' "$workDir/kptools"
  cp '.tmp/kpimg-android' "$workDir/kpimg"

  (
    cd "$workDir"
    ./kptools unpack 'extracted/boot.img'

    if ! ./kptools -i kernel -f | grep -q 'CONFIG_KALLSYMS=y'; then
      printRed 'APatch requires CONFIG_KALLSYMS=y, but it was not found in the boot kernel.'
      exit 1
    fi

    mv kernel kernel.ori
    # Omitting -S uses APatch 11219+'s signature-authorized manager mode. This
    # avoids putting a reusable, root-equivalent SuperKey into CI or the image.
    ./kptools -p -i kernel.ori -k kpimg -o kernel 2>&1 | tee kptools-patch.log

    # KernelPatch can exit successfully and mark an image as patched even when
    # it failed to locate the arm64 relocation table. Such an image is not
    # bootable (observed on the Android 17 Pixel kernel used by mustang). Do not
    # let a syntactically patched but known-bad image reach a release.
    if grep -Eqi \
      "can'?t find arm64 relocation table|arm64 relocation kernel_va: 0xffffffffffffffff" \
      kptools-patch.log; then
      printRed 'Warning: KernelPatch could not resolve the arm64 relocation table and used its relative-base kallsyms path.'
    fi

    # memblock_alloc_try_nid changed from a three-argument physical allocator
    # to a five-argument virtual allocator in Linux 4.20. KernelPatch 0.13.3
    # can select it as the physical fallback and then call it through the old
    # prototype, which is an early-boot ABI violation (KernelPatch #300/#303).
    if grep -Fq 'use memblock_alloc_try_nid as map phys alloc' kptools-patch.log; then
      printRed 'KernelPatch selected the ABI-ambiguous memblock_alloc_try_nid physical fallback; refusing to publish the image.'
      exit 1
    fi

    ./kptools repack 'extracted/boot.img'

    if [[ ! -s new-boot.img ]]; then
      printRed 'APatch did not produce new-boot.img'
      exit 1
    fi
  )
}

function verifyAPatchOta() {
  local otaFile="$1"
  local verifyDir=".tmp/apatch-verify-${DEVICE_ID}-${OTA_VERSION}"

  rm -rf "$verifyDir"
  mkdir -p "$verifyDir"
  .tmp/avbroot ota extract \
    --input "$otaFile" \
    --directory "$verifyDir/extracted" \
    --partition boot
  cp '.tmp/kptools-linux' "$verifyDir/kptools"

  (
    cd "$verifyDir"
    ./kptools unpack 'extracted/boot.img'
    if ! ./kptools -i kernel -l | grep -q 'patched=true'; then
      printRed 'Final OTA verification failed: boot kernel is not patched with KernelPatch.'
      exit 1
    fi
  )

  printGreen "Verified APatch in final OTA boot image: $otaFile"
}

# Fails unless the patched OTA's filesystems are identical to the stock ones
# apart from the intended changes: /system/etc/security/otacerts.zip, which
# avbroot replaces on purpose (it makes the on-device updater reject official
# GrapheneOS OTAs, which a bootloader locked to our AVB key could not boot), and,
# with UPDATER_FEED, the one new /product/overlay/UpdaterOverlay.apk (which must
# be the APK we built, over a stock Updater it can actually override). Anything
# else differing means a module or patch is still writing where it should not.
function verifyAPatchPartitions() {
  local otaFile="$1"
  local tools="$PWD/.tmp"
  local dir=".tmp/apatch-partitions-${DEVICE_ID}-${OTA_VERSION}"
  local partitions=(system) expected name input part

  [[ "$UPDATER_FEED" == 'true' ]] && partitions+=(product)

  rm -rf "$dir"
  for name in stock patched; do
    input=".tmp/$OTA_TARGET.zip"
    [[ "$name" == 'patched' ]] && input="$otaFile"
    for part in "${partitions[@]}"; do
      mkdir -p "$dir/$name/$part"
      "$tools/avbroot" ota extract --input "$input" --directory "$dir/$name" --partition "$part"
      (
        cd "$dir/$name/$part"
        "$tools/avbroot" avb unpack --quiet --input "../$part.img"
        "$tools/afsr" unpack --input raw.img
      )
      rm -f "$dir/$name/$part.img" "$dir/$name/$part/raw.img"
    done
  done

  expected=("Files $dir/stock/system/fs_tree/system/etc/security/otacerts.zip and $dir/patched/system/fs_tree/system/etc/security/otacerts.zip differ")
  if [[ "$UPDATER_FEED" == 'true' ]]; then
    expected+=("Only in $dir/patched/product/fs_tree/overlay: UpdaterOverlay.apk")
    python3 -I updater-overlay/check_target.py "$dir/stock/system/fs_tree/system/priv-app/Updater/Updater.apk"
    cmp "$dir/patched/product/fs_tree/overlay/UpdaterOverlay.apk" .tmp/updater-overlay.apk
  fi

  local differences=''
  for part in "${partitions[@]}"; do
    differences+=$(diff -rq "$dir/stock/$part/fs_tree" "$dir/patched/$part/fs_tree" || true)
    differences+=$'\n'
  done
  differences=$(grep -v -F -x -f <(printf '%s\n' "${expected[@]}" '') <<<"$differences" || true)
  rm -rf "$dir"

  if [[ -n "$differences" ]]; then
    printRed 'APatch OTA changes the partitions beyond what is intended:'
    echo "$differences"
    exit 1
  fi
  printGreen "Verified ${partitions[*]} partitions are stock apart from the intended changes: $otaFile"
}

function downloadAvBroot() {
  downloadAndVerifyFromChenxiaolong 'avbroot' "$AVB_ROOT_VERSION"
}

function downloadAndVerifyFromChenxiaolong() {
  local repo="$1"
  local version="$2"
  local artifact="${3:-$1}" # optional: If not set, use repo name
  
  local url="https://github.com/chenxiaolong/${repo}/releases/download/v${version}/${artifact}-${version}-x86_64-unknown-linux-gnu.zip"
  local downloadedZipFile
  downloadedZipFile="$(mktemp)"
  
  mkdir -p .tmp

  if ! ls ".tmp/${artifact}" >/dev/null 2>&1; then
    curl --fail -sL "${url}" > "${downloadedZipFile}"
    curl --fail -sL "${url}.sig" > "${downloadedZipFile}.sig"
    
    # Validate against author's public key
    ssh-keygen -Y verify -I chenxiaolong -f <(echo "chenxiaolong $CHENXIAOLONG_PK") -n file \
      -s "${downloadedZipFile}.sig" < "${downloadedZipFile}"
    
    echo N | unzip "${downloadedZipFile}" -d .tmp
    rm "${downloadedZipFile}"*
    chmod +x ".tmp/${artifact}" # e.g. .tmp/custota-tool
  fi
}

# Copies one of our injection modules (patch-modules/<file>) into the pinned
# my-avbroot-setup clone and registers it in all_modules() so patch.py can load
# it. The clone is pinned by PATCH_PY_COMMIT, so the all_modules() text is
# stable; registration is grep-guarded to stay idempotent across re-runs.
function registerPatchModule() {
  local file="$1" class="$2"
  local modulesDir='.tmp/my-avbroot-setup/lib/modules'
  if [[ ! -d "$modulesDir" ]]; then
    printRed "my-avbroot-setup modules dir not found at $modulesDir"
    exit 1
  fi
  cp "patch-modules/$file" "$modulesDir/$file"
  if ! grep -q "$class" "$modulesDir/__init__.py"; then
    sed -i \
      -e "/from lib.modules.oemunlockonboot import OEMUnlockOnBootModule/a\\    from lib.modules.${file%.py} import $class" \
      -e "/^        OEMUnlockOnBootModule,\$/a\\        $class," \
      "$modulesDir/__init__.py"
    if ! grep -q "$class" "$modulesDir/__init__.py"; then
      printRed "Failed to register $class in my-avbroot-setup all_modules()."
      exit 1
    fi
  fi
}

# Downloads the official signed APatch manager APK (verified by the SHA-256
# digest GitHub publishes) and registers our system-app injection module.
function installApatchManagerModule() {
  resolveAPatchRelease
  checkMandatoryVariable 'APATCH_MANAGER_URL' 'APATCH_MANAGER_SHA256'
  downloadVerifiedFile '.tmp/apatch-manager.apk' "$APATCH_MANAGER_URL" "$APATCH_MANAGER_SHA256"
  registerPatchModule 'apatch_manager.py' 'APatchManagerModule'
  print "Preinstalling APatch manager $APATCH_VERSION into the OTA system image."
}

# Builds and signs the Updater overlay APK (updater-overlay/) whose only content
# is string/url, set to this repo's rolling release (UPDATER_FEED_TAG). It is
# signed with the OTA key so the signer is the same on every build; the OS does
# not rely on that signature for a preinstalled overlay, but a package whose
# signer changes between OTAs is avoided. Fails closed if the hidden isStatic
# attribute or the URL did not make it into the APK.
# Test builds (UPLOAD_TEST_OTA) get their own feed, so a device carrying a test
# overlay never reads, and a test OTA never lands in, the regular feed.
function updaterFeedTag() {
  if [[ "$UPLOAD_TEST_OTA" == 'true' ]]; then echo "${UPDATER_FEED_TAG}-test"; else echo "$UPDATER_FEED_TAG"; fi
}

function buildUpdaterOverlay() {
  checkMandatoryVariable 'GITHUB_REPO' 'UPDATER_FEED_TAG'
  if [[ ! "$GITHUB_REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ || ! "$UPDATER_FEED_TAG" =~ ^[A-Za-z0-9._-]+$ ]]; then
    printRed "Refusing to build the Updater overlay for GITHUB_REPO='$GITHUB_REPO' UPDATER_FEED_TAG='$UPDATER_FEED_TAG'"
    exit 1
  fi
  local tool
  for tool in aapt aapt2 apksigner openssl; do
    if ! command -v "$tool" >/dev/null; then
      printRed "$tool is required to build the Updater overlay (Debian/Ubuntu: apt install aapt apksigner libandroid-23-java)"
      exit 1
    fi
  done
  if [[ ! -f "$ANDROID_JAR" ]]; then
    printRed "android.jar not found at ANDROID_JAR=$ANDROID_JAR"
    exit 1
  fi

  local dir='.tmp/updater-overlay' url
  url="https://github.com/${GITHUB_REPO}/releases/download/$(updaterFeedTag)/"
  rm -rf "$dir"
  mkdir -p "$dir/res/values"
  printf '<resources>\n    <string name="url" translatable="false">%s</string>\n</resources>\n' "$url" > "$dir/res/values/strings.xml"

  aapt package -f -x -M updater-overlay/stub/AndroidManifest.xml -S updater-overlay/stub/res -I "$ANDROID_JAR" -F "$dir/stub.apk"
  aapt2 compile --dir "$dir/res" -o "$dir/res.zip"
  aapt2 link -o "$dir/unsigned.apk" --manifest updater-overlay/AndroidManifest.xml \
    -I "$ANDROID_JAR" -I "$dir/stub.apk" --min-sdk-version 36 --target-sdk-version 37 "$dir/res.zip"

  local passin=()
  [[ -v PASSPHRASE_OTA ]] && passin=(-passin env:PASSPHRASE_OTA)
  openssl pkcs8 -topk8 -nocrypt -inform PEM -outform DER "${passin[@]}" -in "$KEY_OTA" -out "$dir/key.pk8"
  apksigner sign --v1-signing-enabled false --key "$dir/key.pk8" --cert "$CERT_OTA" \
    --out ".tmp/updater-overlay.apk" "$dir/unsigned.apk"
  rm -f "$dir/key.pk8"
  apksigner verify ".tmp/updater-overlay.apk"

  if ! aapt2 dump xmltree --file AndroidManifest.xml ".tmp/updater-overlay.apk" | grep -qF 'isStatic(0x0101055a)=true' ||
    ! aapt2 dump resources ".tmp/updater-overlay.apk" | grep -qF "$url"; then
    printRed 'The Updater overlay is missing isStatic or the update URL; not using it.'
    exit 1
  fi
  printGreen "Built Updater overlay pointing the Updater at $url"
}

function patchOTAs() {

  downloadAvBroot
  downloadAndVerifyFromChenxiaolong 'afsr' "$AFSR_VERSION"
  if ! ls ".tmp/custota.zip" >/dev/null 2>&1; then
    curl --fail -sL "https://github.com/chenxiaolong/Custota/releases/download/v${CUSTOTA_VERSION}/Custota-${CUSTOTA_VERSION}-release.zip" > .tmp/custota.zip
    curl --fail -sL "https://github.com/chenxiaolong/Custota/releases/download/v${CUSTOTA_VERSION}/Custota-${CUSTOTA_VERSION}-release.zip.sig" > .tmp/custota.zip.sig
  fi
  if ! ls ".tmp/oemunlockonboot.zip" >/dev/null 2>&1; then
    curl --fail -sL "https://github.com/chenxiaolong/OEMUnlockOnBoot/releases/download/v${OEMUNLOCKONBOOT_VERSION}/OEMUnlockOnBoot-${OEMUNLOCKONBOOT_VERSION}-release.zip" > .tmp/oemunlockonboot.zip
    curl --fail -sL "https://github.com/chenxiaolong/OEMUnlockOnBoot/releases/download/v${OEMUNLOCKONBOOT_VERSION}/OEMUnlockOnBoot-${OEMUNLOCKONBOOT_VERSION}-release.zip.sig" > .tmp/oemunlockonboot.zip.sig
  fi
  if ! ls ".tmp/my-avbroot-setup" >/dev/null 2>&1; then
    git clone https://github.com/chenxiaolong/my-avbroot-setup .tmp/my-avbroot-setup
    (cd .tmp/my-avbroot-setup && git checkout ${PATCH_PY_COMMIT})
  fi

  base642key

  if [[ "${POTENTIAL_ASSETS['apatch']+isset}" ]]; then
    patchAPatchBootImage
    if [[ "$APATCH_PREINSTALL_MANAGER" == 'true' ]]; then
      installApatchManagerModule
    fi
    if [[ "$UPDATER_FEED" == 'true' ]]; then
      buildUpdaterOverlay
      registerPatchModule 'updater_overlay.py' 'UpdaterOverlayModule'
    fi
  fi

  for flavor in "${!POTENTIAL_ASSETS[@]}"; do
    local targetFile=".tmp/${POTENTIAL_ASSETS[$flavor]}"

    if ls "$targetFile" >/dev/null 2>&1; then
      printGreen "File $targetFile already exists locally, not patching."
    else
      local args=()
      local dockerEnvArgs=()

      args+=("--output" "$targetFile")
      args+=("--input" ".tmp/$OTA_TARGET.zip")
      args+=("--sign-key-avb" "$KEY_AVB")
      args+=("--sign-key-ota" "$KEY_OTA")
      args+=("--sign-cert-ota" "$CERT_OTA")
      if [[ "$flavor" == 'apatch' ]]; then
        args+=("--patch-arg=--prepatched" "--patch-arg" "$APATCH_BOOT_IMAGE")
        if [[ "$APATCH_PREINSTALL_MANAGER" == 'true' ]]; then
          args+=("--module-apatch-manager" ".tmp/apatch-manager.apk")
        fi
        if [[ "$UPDATER_FEED" == 'true' ]]; then
          args+=("--module-updater-overlay" ".tmp/updater-overlay.apk")
        fi
      fi

      # If env vars not set, passphrases will be queried interactively
      if [ -v PASSPHRASE_AVB ]; then
        args+=("--pass-avb-env-var" "PASSPHRASE_AVB")
        export PASSPHRASE_AVB
        dockerEnvArgs+=("--env" "PASSPHRASE_AVB")
      fi

      if [ -v PASSPHRASE_OTA ]; then
        args+=("--pass-ota-env-var" "PASSPHRASE_OTA")
        export PASSPHRASE_OTA
        dockerEnvArgs+=("--env" "PASSPHRASE_OTA")
      fi

      # Custota and OEMUnlockOnBoot both write into the system partition. The
      # APatch flavor ships without them (it is updated through the Updater overlay
      # or by sideloading, not a Custota feed), so its system image stays stock
      # apart from avbroot's own otacerts.zip replacement; verifyAPatchPartitions
      # proves that after patching.
      if [[ "${SKIP_MODULES}" != 'true' && "$flavor" != 'apatch' ]]; then
        args+=("--module-custota" ".tmp/custota.zip")
        args+=("--module-oemunlockonboot" ".tmp/oemunlockonboot.zip")
      fi
      # We create csig and device JSON for OTA later if necessary
      args+=("--skip-custota-tool")

      # We need to add .tmp to PATH, but we can't use $PATH: because this would be the PATH of the host not the container
      # Python image is designed to run as root, so chown the files it creates back at the end
      # ... room for improvement 😐️
      # shellcheck disable=SC2046
      docker run --rm -i $(tty &>/dev/null && echo '-t') \
    -v "$PWD:/app" \
    -w /app \
    -e PATH='/bin:/usr/local/bin:/sbin:/usr/bin:/app/.tmp' \
    "${dockerEnvArgs[@]}" \
    python:${PYTHON_VERSION} sh -c "set -e && \
        apk add --no-cache openssh uv && \
        uv sync --locked --project .tmp/my-avbroot-setup && \
        uv run --project .tmp/my-avbroot-setup \
            .tmp/my-avbroot-setup/patch.py ${args[*]} && \
        chown -R $(id -u):$(id -g) .tmp"

      if [[ "$flavor" == 'apatch' ]]; then
        verifyAPatchOta "$targetFile"
        verifyAPatchPartitions "$targetFile"
      fi

      printGreen "Finished patching file ${targetFile}"
    fi
    
  done
}

function base642key() {
  set +x # Don't expose secrets to log
  if [ -n "$KEY_AVB_BASE64" ]; then
    echo "$KEY_AVB_BASE64" | base64 -d >.tmp/$KEY_AVB
    KEY_AVB=.tmp/$KEY_AVB
  fi

  if [ -n "$KEY_OTA_BASE64" ]; then
    echo "$KEY_OTA_BASE64" | base64 -d >.tmp/$KEY_OTA
    KEY_OTA=.tmp/$KEY_OTA
  fi

  if [ -n "$CERT_OTA_BASE64" ]; then
    echo "$CERT_OTA_BASE64" | base64 -d >.tmp/$CERT_OTA
    CERT_OTA=.tmp/$CERT_OTA
  fi

  if [[ -n "${DEBUG}" ]]; then set -x; fi
}

function releaseOta() {

  createReleaseIfNecessary

  for flavor in "${!POTENTIAL_ASSETS[@]}"; do
    local assetName="${POTENTIAL_ASSETS[$flavor]}"
    uploadFile ".tmp/$assetName" "$assetName" "application/zip"
    # Checksum in sha256sum format ("<hash>  <name>"), uploaded only after the
    # OTA itself, so it never refers to a file that is not on the release.
    (cd .tmp && sha256sum "$assetName" > "$assetName.sha256")
    uploadFile ".tmp/$assetName.sha256" "$assetName.sha256" "text/plain"
  done

  uploadInstallerAssets
}

# Attaches the flash-ota installer (flash-ota.sh, flash-ota.bat) and this
# repo's avb_pkmd.bin to every release, so a release is self-contained for a
# first/full fastboot install. Every device's matrix job calls releaseOta for
# the same release tag, so uploads here tolerate the asset already being
# attached (uploadFileIfAbsent), instead of failing like the per-flavor OTA
# uploads above (which are each unique per device).
function uploadInstallerAssets() {
  renderFlashOtaInstallers

  uploadFileIfAbsent '.tmp/flash-ota/flash-ota.sh' 'flash-ota.sh' 'text/x-shellscript'
  uploadFileIfAbsent '.tmp/flash-ota/flash-ota.bat' 'flash-ota.bat' 'text/plain'
  uploadFileIfAbsent 'avb_pkmd.bin' 'avb_pkmd.bin' 'application/octet-stream'
}

# Builds the installers that get released from flash-ota.sh and
# flash-ota-src/flash-ota.ps1, stamping this build's own AVB_ROOT_VERSION (the
# avbroot that signed the OTA, so the installer downloads the same one) and
# GITHUB_REPO (so no copy of the repo's name can go stale if it is renamed).
# flash-ota.bat is generated from the stamped PowerShell by
# flash-ota-src/generate-bat.py and is never committed. Fails closed if a
# stamp did not take, instead of releasing an installer with the wrong pin.
function renderFlashOtaInstallers() {
  local out='.tmp/flash-ota' releasesUrl="https://github.com/${GITHUB_REPO}/releases"
  if [[ ! "$AVB_ROOT_VERSION" =~ ^[0-9A-Za-z._-]+$ || ! "$GITHUB_REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
    printRed "Refusing to stamp the flash-ota installers with AVB_ROOT_VERSION='$AVB_ROOT_VERSION' GITHUB_REPO='$GITHUB_REPO'"
    exit 1
  fi

  rm -rf "$out"
  mkdir -p "$out"
  sed -E -e "s|^AVB_ROOT_VERSION=.*|AVB_ROOT_VERSION=${AVB_ROOT_VERSION}|" \
    -e "s|^RELEASES_URL=.*|RELEASES_URL='${releasesUrl}'|" flash-ota.sh > "$out/flash-ota.sh"
  chmod +x "$out/flash-ota.sh"
  sed -E -e "s|^\\\$AvbRootVersion = .*|\\\$AvbRootVersion = '${AVB_ROOT_VERSION}'|" \
    -e "s|^\\\$ReleasesUrl = .*|\\\$ReleasesUrl = '${releasesUrl}'|" flash-ota-src/flash-ota.ps1 > "$out/flash-ota.ps1"
  python3 flash-ota-src/generate-bat.py "$out/flash-ota.ps1" "$out/flash-ota.bat"

  if ! grep -qxF "AVB_ROOT_VERSION=${AVB_ROOT_VERSION}" "$out/flash-ota.sh" ||
    ! grep -qxF "RELEASES_URL='${releasesUrl}'" "$out/flash-ota.sh" ||
    ! grep -qxF "\$AvbRootVersion = '${AVB_ROOT_VERSION}'" "$out/flash-ota.ps1" ||
    ! grep -qxF "\$ReleasesUrl = '${releasesUrl}'" "$out/flash-ota.ps1"; then
    printRed 'Stamping the flash-ota installers failed; not releasing them.'
    exit 1
  fi
}

function createReleaseIfNecessary() {
  checkMandatoryVariable 'GITHUB_REPO' 'GITHUB_TOKEN'

  local response changelog src_repo current_commit
  local releaseTag="${OTA_VERSION}${RELEASE_TAG_SUFFIX}"

  if [[ -z "$RELEASE_ID" ]]; then
    src_repo=$(extractGithubRepo "$(git config --get remote.origin.url)")

    # Security-preview releases end in suffix 01,but anchor links on release page always end in 00
    # e.g. 25092501 -> 25092500
    OTA_VERSION_ANCHOR="${OTA_VERSION/%01/00}"
    if [[ "${GITHUB_REPO}" == "${src_repo}" ]]; then
      changelog=$(curl -sL -X POST -H "Authorization: token $GITHUB_TOKEN" \
        -d "{
                \"tag_name\": \"$releaseTag\",
                \"target_commitish\": \"main\"
              }" \
        "https://api.github.com/repos/$GITHUB_REPO/releases/generate-notes" | jq -r '.body // empty')
      # Replace \n by \\n to keep them as chars
      changelog="Update to [GrapheneOS ${OTA_VERSION}](https://grapheneos.org/releases#${OTA_VERSION_ANCHOR}).\n\n$(echo "${changelog}" | sed ':a;N;$!ba;s/\n/\\n/g')"
    else
      # When pushing to different repo's GH pages, generating notes does not make too much sense. Refer to the used repo's "version" instead.
      current_commit=$(git rev-parse --short HEAD)
      changelog="Update to [GrapheneOS ${OTA_VERSION}](https://grapheneos.org/releases#${OTA_VERSION_ANCHOR}).\n\nRelease created using ${src_repo}@${current_commit}. See [Changelog](https://github.com/${src_repo}/blob/${current_commit}/README.md#notable-changelog)."
    fi

    response=$(curl -sL -X POST -H "Authorization: token $GITHUB_TOKEN" \
      -d "{
              \"tag_name\": \"$releaseTag\",
              \"target_commitish\": \"main\",
              \"name\": \"$releaseTag\",
              \"body\": \"${changelog}\",
              \"prerelease\": ${RELEASE_PRERELEASE}
            }" \
      "https://api.github.com/repos/$GITHUB_REPO/releases")
    RELEASE_ID=$(echo "${response}" | jq -r '.id // empty')
    if [[ -n "${RELEASE_ID}" ]]; then
      printGreen "Release created successfully with ID: ${RELEASE_ID}"
    elif echo "${response}" | jq -e '.status == "422"' > /dev/null; then
      # In case release has been created in the meantime (e.g. matrix job for multiple devices concurrently)
      RELEASE_ID=$(curl -sL \
        -H "Authorization: token $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github.v3+json" \
            "https://api.github.com/repos/${GITHUB_REPO}/releases" | \
            jq -r --arg release_tag "${releaseTag}" '.[] | select(.tag_name == $release_tag) | .id // empty')
      if [[ -n "${RELEASE_ID}" ]]; then
        printGreen "Cannot create release but found existing release for ${releaseTag}. ID=$RELEASE_ID"
      else
        printRed "Cannot create release for ${releaseTag} because it seems to exist but still cannot find ID."
        exit 1
      fi
    else
      errors=$(echo "${response}" | jq -r '.errors')
      printRed "Failed to create release for ${OTA_VERSION}. Errors: ${errors}"
      exit 1
    fi
  fi
}

function uploadFile() {
  local sourceFileName="$1"
  local targetFileName="$2"
  local contentType="$3"

  # Note that --data-binary might lead to out of memory
  curl --fail -X POST -H "Authorization: token $GITHUB_TOKEN" \
    -H "Content-Type: $contentType" \
    --upload-file "$sourceFileName" \
    "https://uploads.github.com/repos/$GITHUB_REPO/releases/$RELEASE_ID/assets?name=$targetFileName"
}

# Like uploadFile, but for an asset shared by every device's build of this
# release (so every device's matrix job calls this for the same file name):
# tolerates the asset already being attached, whether uploaded by an earlier
# device or a concurrent one, instead of failing on GitHub's 422.
function uploadFileIfAbsent() {
  local sourceFileName="$1"
  local targetFileName="$2"
  local contentType="$3"
  local releaseId="${4:-$RELEASE_ID}"
  local status

  status=$(curl -sS -o /dev/null -w '%{http_code}' -X POST -H "Authorization: token $GITHUB_TOKEN" \
    -H "Content-Type: $contentType" \
    --upload-file "$sourceFileName" \
    "https://uploads.github.com/repos/$GITHUB_REPO/releases/$releaseId/assets?name=$targetFileName")

  case "$status" in
    201) printGreen "Uploaded $targetFileName" ;;
    422) printGreen "$targetFileName already attached to this release." ;;
    *)
      printRed "Failed to upload $targetFileName (HTTP $status)"
      exit 1
      ;;
  esac
}

# Publishes the APatch OTA built for this device where the overlaid Updater
# looks for it: the rolling release updaterFeedTag, in the Updater's own flat
# layout (<device>-<channel> metadata line + <device>-ota_update-<incremental>.zip).
# GitHub redirects release downloads to its CDN with Range support and answers
# 404 for the incremental the Updater tries first, so it falls back to the full
# OTA. Both channels are served so the default one and the security-preview opt-in
# find it. The OTA zip goes up before the metadata that names it and stale zips
# go last, so the feed never points at a missing file; an older build never
# replaces a newer one. The metadata is unauthenticated, as upstream's is: the
# Updater only installs zips signed with the otacerts avbroot embedded.
function publishUpdaterFeed() {
  checkMandatoryVariable 'GITHUB_REPO' 'GITHUB_TOKEN' 'DEVICE_ID'
  local tag otaFile metadata incremental timestamp device id
  tag=$(updaterFeedTag)
  otaFile=".tmp/${POTENTIAL_ASSETS['apatch']}"
  metadata=$(unzip -p "$otaFile" META-INF/com/android/metadata)
  incremental=$(sed -n 's/^post-build-incremental=//p' <<<"$metadata")
  timestamp=$(sed -n 's/^post-timestamp=//p' <<<"$metadata")
  device=$(sed -n 's/^pre-device=//p' <<<"$metadata")
  if [[ "$device" != "$DEVICE_ID" || "$incremental" != "$OTA_VERSION" || ! "$timestamp" =~ ^[0-9]+$ ]]; then
    printRed "Unexpected OTA metadata for the Updater feed: device=$device incremental=$incremental timestamp=$timestamp"
    exit 1
  fi

  local api="https://api.github.com/repos/$GITHUB_REPO" release feedId
  release=$(githubApiGet "$api/releases/tags/$tag" 2>/dev/null) || {
    curl -sL -X POST -H "Authorization: token $GITHUB_TOKEN" "$api/releases" -d "{
      \"tag_name\": \"$tag\", \"target_commitish\": \"main\", \"name\": \"$tag\", \"prerelease\": true,
      \"body\": \"Rolling feed read by the GrapheneOS Updater of OTAs built with the Updater overlay. Download OTAs from the versioned releases instead.\"
    }" >/dev/null || true
    # A concurrent device job may have created it first; either way it exists now.
    release=$(githubApiGet "$api/releases/tags/$tag")
  }
  feedId=$(jq -er '.id' <<<"$release")

  local assets name channel existing current=0
  assets=$(githubApiGet "$api/releases/$feedId/assets?per_page=100")
  if (( $(jq 'length' <<<"$assets") >= 100 )); then
    printRed "The $tag release has too many assets to manage."
    exit 1
  fi

  local metaName="$device-stable-security-preview"
  existing=$(jq -r --arg n "$metaName" '[.[] | select(.name == $n) | .url] | first // empty' <<<"$assets")
  if [[ -n "$existing" ]]; then
    current=$(curl --fail -sL -H "Authorization: token $GITHUB_TOKEN" -H 'Accept: application/octet-stream' "$existing" | awk '{print $2; exit}')
    if [[ "$current" =~ ^[0-9]+$ ]] && (( current > timestamp )); then
      printGreen "The $tag feed already serves a newer $device build ($current > $timestamp), not replacing it."
      return
    fi
  fi

  local zipName="$device-ota_update-$incremental.zip"
  replaceReleaseAsset "$api" "$feedId" "$assets" "$zipName" "$otaFile" 'application/zip'
  for channel in stable stable-security-preview; do
    printf '%s %s %s %s\n' "$incremental" "$timestamp" "$device" "$channel" > ".tmp/$device-$channel"
    replaceReleaseAsset "$api" "$feedId" "$assets" "$device-$channel" ".tmp/$device-$channel" 'text/plain'
  done

  while read -r name id; do
    [[ "$name" != "$zipName" ]] && curl --fail -sL -X DELETE -H "Authorization: token $GITHUB_TOKEN" "$api/releases/assets/$id"
  done < <(jq -r --arg p "$device-ota_update-" '.[] | select((.name | startswith($p)) and (.name | endswith(".zip"))) | "\(.name) \(.id)"' <<<"$assets")
  printGreen "Updater feed $tag now serves $device $incremental."
}

# Uploads a file to a release, first deleting an asset of that name if the
# given asset listing has one (GitHub cannot overwrite assets).
function replaceReleaseAsset() {
  local api="$1" releaseId="$2" assets="$3" name="$4" file="$5" contentType="$6" id
  id=$(jq -r --arg n "$name" '[.[] | select(.name == $n) | .id] | first // empty' <<<"$assets")
  if [[ -n "$id" ]]; then
    curl --fail -sL -X DELETE -H "Authorization: token $GITHUB_TOKEN" "$api/releases/assets/$id"
  fi
  uploadFileIfAbsent "$file" "$name" "$contentType" "$releaseId"
}

function createOtaServerData() {
  downloadCusotaTool

  for flavor in "${!POTENTIAL_ASSETS[@]}"; do
    local POTENTIAL_ASSET_NAME="${POTENTIAL_ASSETS[$flavor]}"
    local targetFile=".tmp/${POTENTIAL_ASSET_NAME}"
    
    local args=()
  
    args+=("--input" "${targetFile}")
    args+=("--output" "${targetFile}.csig")
    args+=("--key" "$KEY_OTA")
    args+=("--cert" "$CERT_OTA")
  
    # If env vars not set, passphrases will be queried interactively
    if [ -v PASSPHRASE_OTA ]; then
      args+=("--passphrase-env-var" "PASSPHRASE_OTA")
    fi
  
    .tmp/custota-tool gen-csig "${args[@]}"
  
    mkdir -p ".tmp/${flavor}"
    
    local args=()
    args+=("--file" ".tmp/${flavor}/${DEVICE_ID}.json")
    # e.g. https://github.com/schnatterer/rooted-graphene/releases/download/2023121200-v26.4-e54c67f/oriole-ota_update-2023121200.zip
    # Instead of constructing the location we could also parse it from the upload response
    args+=("--location" "https://github.com/$GITHUB_REPO/releases/download/$OTA_VERSION/$POTENTIAL_ASSET_NAME")
  
    .tmp/custota-tool gen-update-info "${args[@]}"
  done
}

function downloadCusotaTool() {
  downloadAndVerifyFromChenxiaolong 'Custota' "$CUSTOTA_VERSION" 'custota-tool'
}

function uploadOtaServerData() {

  # Update OTA server (github pages)
  local current_branch current_commit base_dir src_repo
  current_commit=$(git rev-parse --short HEAD)
  folderPrefix=''
  
  if [[ "${UPLOAD_TEST_OTA}" == 'true' ]]; then
    folderPrefix='test/'
  fi

  (
    base_dir="$(pwd)"
    src_repo=$(extractGithubRepo "$(git config --get remote.origin.url)")
    if [[ -n "${PAGES_REPO_FOLDER}" ]]; then
      cd "${PAGES_REPO_FOLDER}"
    fi
    
    current_branch=$(git rev-parse --abbrev-ref HEAD)
    git checkout gh-pages
    
    for flavor in "${!POTENTIAL_ASSETS[@]}"; do
      local POTENTIAL_ASSET_NAME="${POTENTIAL_ASSETS[$flavor]}"
      local targetFile="${folderPrefix}${flavor}/${DEVICE_ID}.json"
  
      uploadFile "${base_dir}/.tmp/${POTENTIAL_ASSET_NAME}.csig" "$POTENTIAL_ASSET_NAME.csig" "application/octet-stream"
      
      mkdir -p "${folderPrefix}${flavor}"
      # update only, if current $DEVICE_ID.json does not contain $OTA_VERSION
      # We don't want to trigger users to upgrade on new commits from this repo or new magisk versions
      # They can manually upgrade by downloading the OTAs from the releases and "adb sideload" them
      if ! grep -q "$OTA_VERSION" "${targetFile}" || [[ "$FORCE_OTA_SERVER_UPLOAD" == 'true' ]] && [[ "$SKIP_OTA_SERVER_UPLOAD" != 'true' ]]; then
        cp "${base_dir}/.tmp/${flavor}/$DEVICE_ID.json" "${targetFile}"
        git add "${targetFile}"
      elif grep -q "${OTA_VERSION}" "${targetFile}"; then
        printGreen "Skipping update of OTA server, because ${OTA_VERSION} already in ${folderPrefix}${flavor}/${DEVICE_ID}.json and FORCE_OTA_SERVER_UPLOAD is false."
      else
        printGreen "Skipping update of OTA server, because SKIP_OTA_SERVER_UPLOAD is true."
      fi
    done
    
    if ! git diff-index --quiet HEAD; then
      # Commit and push only when there are changes
      git config user.name "GitHub Actions" && git config user.email "actions@github.com"
      git commit \
          --message "Update device ${DEVICE_ID} basing on ${src_repo}@${current_commit}" \
    
      gitPushWithRetries
    fi
  
    # Switch back to the original branch
    git checkout "$current_branch"
  )
}

extractGithubRepo() {
  # Works for both HTTPS and SSH, e.g.
  # https://github.com/schnatterer/rooted-graphene
  # git@github.com:schnatterer/rooted-graphene.git

  local remote_url="$1"
  local repo

  # Remove the protocol and .git suffix
  remote_url=$(echo "$remote_url" | sed -e 's/.*:\/\/\|.*@//' -e 's/\.git$//')

  # Extract the owner/repo part
  repo=$(echo "$remote_url" | sed -e 's/.*[:\/]\([^\/]*\/[^\/]*\)$/\1/')

  echo "$repo"
}

function gitPushWithRetries() {
  local count=0

  while [ $count -lt $GIT_PUSH_RETRIES ]; do
    git pull --rebase
    if git push origin gh-pages; then
      break
    else
      count=$((count + 1))
      printGreen "Retry $count/$GIT_PUSH_RETRIES failed. Retrying..."
      sleep 2
    fi
  done
  
  if [ $count -eq $GIT_PUSH_RETRIES ]; then
    printRed "Failed to push to gh-pages after $GIT_PUSH_RETRIES attempts."
    exit 1
  fi
}

function print() {
  echo -e "$(date '+%Y-%m-%d %H:%M:%S'): $*"
}

function printGreen() {
  if [[ -z "${NO_COLOR}" ]]; then
    echo -e "\e[32m$(date '+%Y-%m-%d %H:%M:%S'): $*\e[0m"
  else
      print "$@"
  fi
}

function printRed() {
  if [[ -z "${NO_COLOR}" ]]; then
   echo -e "\e[31m$(date '+%Y-%m-%d %H:%M:%S'): $*\e[0m"
  else
      print "$@"
  fi
}
