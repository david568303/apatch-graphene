#!/usr/bin/env bash
# flash-ota.sh - installs a Graphene-Apatch OTA via fastboot (fresh/full install).
#
# Place this script, the OTA zip for your device (or several, if you want to
# choose), and optionally a pre-downloaded avbroot binary all in the same
# folder, then run it with the device in bootloader mode (fastboot),
# bootloader UNLOCKED.
#
# What it does:
#   1. Checks the fastboot on PATH is recent enough to flash dynamic
#      partitions correctly; tells you where to get a newer one if not.
#   2. Finds the OTA zip in this folder (asks which one, if there's more
#      than one).
#   3. Finds avbroot (on PATH or in this folder), offering to download the
#      pinned version this script was released with if it's missing.
#   4. Extracts the OTA and flashes every partition fastboot/fastbootd need
#      (the core ones via `fastboot flashall`, plus the verity-protected
#      dynamic partitions flashall alone does not cover), then registers
#      this repo's AVB key (avb_pkmd.bin, if present next to this script).
#   5. Leaves the device in the bootloader. Asks you to boot it and confirm
#      GrapheneOS actually starts before offering to lock the bootloader
#      (which wipes data and should never be done on a device that doesn't
#      boot).
#
# Safe by default: every destructive step asks first, and locking the
# bootloader needs a second, explicit, typed confirmation.

set -uo pipefail
# Not -e: most steps are "ask, then maybe act", and a few probes (command -v,
# etc.) are expected to fail harmlessly. Every command whose failure should
# stop the script is run through run() below, which checks its exit status
# explicitly.

# renovate: datasource=github-releases packageName=chenxiaolong/avbroot versioning=semver
AVB_ROOT_VERSION=3.35.0
MIN_FASTBOOT_VERSION='35.0.1'
CHENXIAOLONG_PK='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDOe6/tBnO7xZhAWXRj3ApUYgn+XZ0wnQiXM8B7tPgv4'
AVB_PKMD='avb_pkmd.bin'
RELEASES_URL='https://github.com/david568303/rooted-graphene/releases'

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'
info() { echo "==> $*"; }
ok()   { echo "${GREEN}==> $*${RESET}"; }
warn() { echo "${YELLOW}==> $*${RESET}"; }
err()  { echo "${RED}==> $*${RESET}" >&2; }
die()  { err "$*"; exit 1; }

cleanup() { tput cnorm 2>/dev/null || true; }
trap cleanup EXIT

confirm() {
  # confirm "question" -> 0 (true) for y/Y, 1 (false) for anything else.
  local reply
  read -rp "$1 [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

run() {
  "$@"
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    die "Command failed (exit $rc): $*"
  fi
}

#### 1. fastboot ##############################################################

version_ge() {
  # version_ge A B -> true if dotted version A >= B
  [[ "$1" == "$2" ]] && return 0
  local -a av bv
  IFS=. read -ra av <<<"$1"
  IFS=. read -ra bv <<<"$2"
  local i x y
  for ((i = 0; i < 3; i++)); do
    x=${av[i]:-0}; y=${bv[i]:-0}
    ((10#$x > 10#$y)) && return 0
    ((10#$x < 10#$y)) && return 1
  done
  return 0
}

check_fastboot() {
  if ! command -v fastboot >/dev/null 2>&1; then
    die "fastboot was not found on PATH. Install Android platform-tools (>= $MIN_FASTBOOT_VERSION) from https://developer.android.com/tools/releases/platform-tools and make sure it's on PATH, then re-run this script."
  fi
  local raw ver
  raw=$(fastboot --version 2>&1 | head -n1)
  ver=$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' <<<"$raw" | head -n1)
  if [[ -z "$ver" ]]; then
    warn "Could not determine your fastboot version from: $raw"
    confirm "Continue anyway?" || exit 1
    return
  fi
  if ! version_ge "$ver" "$MIN_FASTBOOT_VERSION"; then
    die "fastboot $ver is too old (need >= $MIN_FASTBOOT_VERSION): earlier versions fail to flash dynamic partitions correctly. Install a recent one from https://developer.android.com/tools/releases/platform-tools, then re-run this script."
  fi
  ok "fastboot $ver"
}

#### 2. OTA selection ##########################################################

# Globals: MENU_OPTIONS (array in), MENU_SELECTED_INDEX (int out).
select_from_menu() {
  local count=${#MENU_OPTIONS[@]}
  local idx=0 key rest i choice

  if [[ ! -t 0 || ! -t 1 ]] || ! command -v tput >/dev/null 2>&1; then
    for ((i = 0; i < count; i++)); do
      printf '%2d) %s\n' "$((i + 1))" "${MENU_OPTIONS[$i]}"
    done
    while true; do
      read -rp "Select a number [1-$count]: " choice
      if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= count)); then
        MENU_SELECTED_INDEX=$((choice - 1))
        return
      fi
      echo "Invalid selection."
    done
  fi

  draw_menu() {
    local j
    for ((j = 0; j < count; j++)); do
      if ((j == idx)); then
        printf '\r\033[K\033[7m> %s\033[0m\n' "${MENU_OPTIONS[$j]}"
      else
        printf '\r\033[K  %s\n' "${MENU_OPTIONS[$j]}"
      fi
    done
  }

  tput civis 2>/dev/null
  draw_menu
  while true; do
    IFS= read -rsn1 key
    if [[ "$key" == $'\x1b' ]]; then
      IFS= read -rsn2 -t 0.05 rest
      key+="$rest"
    fi
    case "$key" in
      $'\x1b[A') idx=$(((idx - 1 + count) % count)) ;;
      $'\x1b[B') idx=$(((idx + 1) % count)) ;;
      '') break ;;
    esac
    printf '\033[%dA' "$count"
    draw_menu
  done
  tput cnorm 2>/dev/null
  MENU_SELECTED_INDEX=$idx
}

find_ota() {
  local -a otas=()
  local f
  for f in *.zip; do
    [[ -e "$f" ]] || continue
    otas+=("$f")
  done
  if [[ ${#otas[@]} -eq 0 ]]; then
    die "No OTA zip found in $HERE. Download one from $RELEASES_URL and place it next to this script."
  elif [[ ${#otas[@]} -eq 1 ]]; then
    OTA_FILE="${otas[0]}"
    info "Found one OTA: $OTA_FILE"
  else
    info "Found multiple OTAs. Use Up/Down and Enter to pick one:"
    MENU_OPTIONS=("${otas[@]}")
    select_from_menu
    OTA_FILE="${otas[$MENU_SELECTED_INDEX]}"
  fi
}

#### 3. avbroot ################################################################

find_or_download_avbroot() {
  if [[ -x ./avbroot ]]; then
    AVBROOT=./avbroot
  elif command -v avbroot >/dev/null 2>&1; then
    AVBROOT=avbroot
  else
    warn "avbroot was not found on PATH or in $HERE."
    if ! confirm "Download avbroot v$AVB_ROOT_VERSION now?"; then
      die "avbroot missing"
    fi
    download_avbroot
    AVBROOT=./avbroot
  fi
  if ! "$AVBROOT" --version >/dev/null 2>&1; then
    die "Found $AVBROOT but it did not run. Is it the right binary for this machine?"
  fi
  ok "Using avbroot: $AVBROOT"
}

download_avbroot() {
  local os arch target
  os=$(uname -s)
  arch=$(uname -m)
  case "$os" in
    Linux)
      case "$arch" in
        x86_64) target=x86_64-unknown-linux-gnu ;;
        aarch64 | arm64) target=aarch64-unknown-linux-gnu ;;
        *) die "No prebuilt avbroot for Linux/$arch. Download it manually from https://github.com/chenxiaolong/avbroot/releases and place the 'avbroot' binary next to this script." ;;
      esac
      ;;
    Darwin)
      case "$arch" in
        x86_64) target=x86_64-apple-darwin ;;
        arm64) target=aarch64-apple-darwin ;;
        *) die "No prebuilt avbroot for macOS/$arch. Download it manually from https://github.com/chenxiaolong/avbroot/releases and place the 'avbroot' binary next to this script." ;;
      esac
      ;;
    *)
      die "Unsupported OS: $os. Download avbroot manually from https://github.com/chenxiaolong/avbroot/releases and place the 'avbroot' binary next to this script."
      ;;
  esac

  command -v curl >/dev/null 2>&1 || die "curl is required to download avbroot but was not found."
  command -v unzip >/dev/null 2>&1 || die "unzip is required to extract avbroot but was not found."

  local base="avbroot-${AVB_ROOT_VERSION}-${target}"
  local url="https://github.com/chenxiaolong/avbroot/releases/download/v${AVB_ROOT_VERSION}/${base}.zip"
  local tmp
  tmp=$(mktemp -d)

  info "Downloading $url"
  if ! curl --fail -sL -o "$tmp/avbroot.zip" "$url" || ! curl --fail -sL -o "$tmp/avbroot.zip.sig" "$url.sig"; then
    rm -rf "$tmp"
    die "Could not download avbroot for $os/$arch (v$AVB_ROOT_VERSION may not publish this platform). Download it manually from https://github.com/chenxiaolong/avbroot/releases and place the 'avbroot' binary next to this script."
  fi

  if command -v ssh-keygen >/dev/null 2>&1; then
    if ! ssh-keygen -Y verify -I chenxiaolong \
        -f <(echo "chenxiaolong $CHENXIAOLONG_PK") -n file \
        -s "$tmp/avbroot.zip.sig" < "$tmp/avbroot.zip"; then
      rm -rf "$tmp"
      die "avbroot download failed signature verification. Not using it. Download it yourself from https://github.com/chenxiaolong/avbroot/releases."
    fi
    ok "avbroot download verified against chenxiaolong's signing key."
  else
    warn "ssh-keygen was not found: could not verify the avbroot download's signature."
    if ! confirm "Continue anyway, using an UNVERIFIED avbroot binary?"; then
      rm -rf "$tmp"
      exit 1
    fi
  fi

  unzip -oq "$tmp/avbroot.zip" -d "$tmp"
  cp "$tmp/avbroot" ./avbroot
  chmod +x ./avbroot
  rm -rf "$tmp"
  ok "Downloaded avbroot v$AVB_ROOT_VERSION"
}

#### 4. Flashing ################################################################

flash_ota() {
  info "Extracting $OTA_FILE for fastboot"
  rm -rf extracted extra
  run "$AVBROOT" ota extract --input "$OTA_FILE" --directory extracted --fastboot
  run "$AVBROOT" ota extract --input "$OTA_FILE" --directory extra \
    -p product -p vendor -p system_ext -p system_dlkm -p vendor_dlkm

  export ANDROID_PRODUCT_OUT="$PWD/extracted"

  info "Flashing core partitions (this enters fastbootd automatically)"
  run fastboot flashall --skip-reboot

  info "Flashing the remaining dynamic partitions in fastbootd"
  local p
  for p in product vendor system_ext system_dlkm vendor_dlkm; do
    if [[ -f "extra/$p.img" ]]; then
      run fastboot flash "$p" "extra/$p.img"
    fi
  done

  if [[ -f "$AVB_PKMD" ]]; then
    info "Registering this repo's AVB key"
    run fastboot reboot-bootloader
    run fastboot erase avb_custom_key
    run fastboot flash avb_custom_key "$AVB_PKMD"
  else
    warn "$AVB_PKMD not found next to this script; the custom AVB key was NOT (re)registered."
    warn "If this is a first install, the device will fail to boot once locked without it."
  fi

  ok "Flashing complete. The device is in the bootloader."
}

#### 5. Boot confirmation + lock flow ##########################################

boot_and_lock_flow() {
  echo
  info "The device is sitting in the bootloader now."
  info "Boot it into GrapheneOS: either run 'fastboot reboot' or use the volume/power buttons to select Start."
  read -rp "Press Enter once you have booted the device and GrapheneOS has had a chance to start... "

  if ! confirm "Does GrapheneOS boot?"; then
    warn "Do NOT lock the bootloader on a device that does not boot."
    warn "Capture the kernel log of the failed boot with: adb shell su -c 'cat /sys/fs/pstore/console-ramoops-0' (after booting any working image), and open an issue."
    return
  fi
  ok "Good, GrapheneOS boots."

  if ! confirm "Do you want to lock the bootloader now? This wipes all data on the device and cannot be undone without unlocking (another wipe)."; then
    info "Leaving the bootloader unlocked."
    return
  fi

  warn "Last check: locking is destructive and should only be done once you are sure the device is working well."
  local confirmation
  read -rp "Type 'lock' to confirm, or anything else to cancel: " confirmation
  if [[ "$confirmation" != "lock" ]]; then
    info "Not locking the bootloader."
    return
  fi

  info "Rebooting to the bootloader to lock it"
  run fastboot reboot bootloader
  run fastboot flashing lock
  ok "Bootloader lock command sent. Confirm on the device screen if prompted (volume down, then power)."
}

#### main #######################################################################

main() {
  check_fastboot
  find_ota
  find_or_download_avbroot
  flash_ota
  boot_and_lock_flow
}
main "$@"
