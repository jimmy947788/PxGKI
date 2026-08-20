#!/bin/bash
#
# Flash a kernel boot image built by Buildkernel.sh, with pre-flight checks.
#
#   ./Flashkernel.sh                      # use the defaults below
#   ./Flashkernel.sh path/to/boot.img     # flash a specific image
#
# Nothing is written to the device until every check has passed and you have
# typed the confirmation. Only the ACTIVE slot is touched, so the inactive slot
# keeps its stock kernel as a fallback.

set -uo pipefail

# Settings

# Image to flash. Defaults to the newest boot_sukisu_*.img under patched/.
export Boot_Image="${1:-}"

# Stock images, used for the vbmeta step and quoted in the recovery hints.
export Stock_Dir="$HOME/Documents/pixel6-pro/raven-tq3a.230901.001"
export Stock_Boot="$Stock_Dir/boot.img"
export Vbmeta_Image="$Stock_Dir/vbmeta.img"

export Working_Dir="$HOME/Projects/PxGKI"
export Patched_Dir="$Working_Dir/Buildkernel/patched"

red()   { echo -e "\e[31m$*\e[0m"; }
green() { echo -e "\e[32m$*\e[0m"; }
warn()  { echo -e "\e[33m$*\e[0m"; }
die()   { red "[Error] $*"; exit 1; }

# Pick an image if none was given
if [ -z "$Boot_Image" ]; then
  Boot_Image=$(ls -t "$Patched_Dir"/boot_sukisu_*.img 2>/dev/null | head -1)
  [ -n "$Boot_Image" ] || die "No image given and none found in $Patched_Dir"
fi

green "Pre-flight checks"

# 1. Tools
command -v fastboot >/dev/null 2>&1 || die "fastboot not found (apt install android-sdk-platform-tools)"

# 2. Files
[ -f "$Boot_Image" ]   || die "Boot image not found: $Boot_Image"
[ -f "$Vbmeta_Image" ] || die "vbmeta image not found: $Vbmeta_Image"
if [ ! -f "$Stock_Boot" ]; then
  warn "[Warn] Stock boot.img not found at $Stock_Boot"
  warn "       You will have nothing to flash back if this bootloops."
  read -p "       Continue anyway? (yes/no): " ans
  [ "$ans" = "yes" ] || die "Aborted"
fi

# 3. The image is actually an Android boot image, not a raw kernel
magic=$(head -c 8 "$Boot_Image")
[ "$magic" = "ANDROID!" ] || die "$Boot_Image is not an Android boot image (magic: $magic)"

hdr=$(python3 - "$Boot_Image" <<'PY'
import struct, sys
d = open(sys.argv[1], 'rb').read(4096)
k, r = struct.unpack('<II', d[8:16])
v = struct.unpack('<I', d[40:44])[0]
print(v, k, r)
PY
)
read -r hdr_ver kern_sz ram_sz <<<"$hdr"

# 4. Compare layout against stock: a ramdisk that stock does not have (or a
#    missing one that stock does have) is the classic way to lose init.
if [ -f "$Stock_Boot" ]; then
  s_hdr=$(python3 - "$Stock_Boot" <<'PY'
import struct, sys
d = open(sys.argv[1], 'rb').read(4096)
k, r = struct.unpack('<II', d[8:16])
v = struct.unpack('<I', d[40:44])[0]
print(v, k, r)
PY
)
  read -r s_ver s_kern s_ram <<<"$s_hdr"
  echo "  header version   : $hdr_ver   (stock: $s_ver)"
  echo "  kernel size      : $kern_sz   (stock: $s_kern)"
  echo "  ramdisk size     : $ram_sz   (stock: $s_ram)"
  [ "$hdr_ver" = "$s_ver" ] || die "Header version differs from stock - wrong image for this device"
  if { [ "$ram_sz" = "0" ] && [ "$s_ram" != "0" ]; } || { [ "$ram_sz" != "0" ] && [ "$s_ram" = "0" ]; }; then
    die "Ramdisk layout differs from stock (this:$ram_sz stock:$s_ram) - flashing this would break boot"
  fi
else
  echo "  header version   : $hdr_ver"
  echo "  kernel size      : $kern_sz"
  echo "  ramdisk size     : $ram_sz"
fi

# 5. What is actually inside
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
Unpack="$Working_Dir/Buildkernel/tools/mkbootimg/unpack_bootimg.py"
if [ -f "$Unpack" ] && command -v lz4 >/dev/null 2>&1; then
  python3 "$Unpack" --boot_img "$Boot_Image" --out "$tmp" >/dev/null 2>&1
  if [ -s "$tmp/kernel" ]; then
    lz4 -d -q -f "$tmp/kernel" "$tmp/k.raw" 2>/dev/null || cp "$tmp/kernel" "$tmp/k.raw"
    ver=$(strings "$tmp/k.raw" | grep -m1 -oE 'Linux version [0-9][^ ]*' | cut -d' ' -f3)
    kpm=$(strings -n 6 "$tmp/k.raw" | grep -c KernelPatch)
    echo "  kernel release   : ${ver:-unknown}"
    echo "  KPM (KernelPatch): $([ "$kpm" -gt 0 ] && echo yes || echo no)"
    if [ -f "$Stock_Boot" ]; then
      python3 "$Unpack" --boot_img "$Stock_Boot" --out "$tmp/s" >/dev/null 2>&1
      lz4 -d -q -f "$tmp/s/kernel" "$tmp/s/k.raw" 2>/dev/null || cp "$tmp/s/kernel" "$tmp/s/k.raw"
      sver=$(strings "$tmp/s/k.raw" | grep -m1 -oE 'Linux version [0-9][^ ]*' | cut -d' ' -f3)
      echo "  stock release    : ${sver:-unknown}"
      if [ -z "$ver" ] || [ -z "$sver" ]; then
        warn "  -> could not read one of the release strings, compare them yourself"
      elif [ "$ver" = "$sver" ]; then
        green "  -> matches stock exactly"
      else
        warn "  -> differs from stock (fine if >= stock and same KMI generation)"
      fi
    fi
  fi
fi

# 6. Device
green "Device"
# "fastboot wait-for-device" does not exist -- wait-for-device is an adb subcommand.
# fastboot blocks on any command until a device shows up, so poll "fastboot devices"
# instead. That also lets us tell "not plugged in" apart from "enumerated but not
# claimable", which a bare error code cannot.
echo -n "  waiting for a device in fastboot mode (Ctrl+C to abort) ... "
Wait_Secs="${Wait_Secs:-60}"
for ((i = 0; i < Wait_Secs; i++)); do
  serial=$(fastboot devices 2>/dev/null | awk 'NF {print $1; exit}')
  [ -n "$serial" ] && break
  sleep 1
done
if [ -z "${serial:-}" ]; then
  echo
  if lsusb -d 18d1: >/dev/null 2>&1; then
    die "A Google device is on USB but fastboot cannot claim it - check udev (18d1 / plugdev) or unplug any USB hub in the path"
  fi
  die "No device in fastboot mode after ${Wait_Secs}s - check the cable, avoid USB hubs, and confirm the phone shows Fastboot Mode"
fi
echo "ok"
echo "  serial           : $serial"

product=$(fastboot getvar product 2>&1 | grep -m1 '^product:' | awk '{print $2}')
unlocked=$(fastboot getvar unlocked 2>&1 | grep -m1 '^unlocked:' | awk '{print $2}')
slot=$(fastboot getvar current-slot 2>&1 | grep -m1 '^current-slot:' | awk '{print $2}')
echo "  product          : ${product:-unknown}"
echo "  bootloader       : ${unlocked:-unknown}"
echo "  active slot      : ${slot:-n/a}"
[ "$unlocked" = "yes" ] || die "Bootloader is not unlocked - fastboot flash will be rejected"

# 7. Confirm
echo
warn "About to write to the ACTIVE slot (${slot:-single}) of ${product:-this device}:"
echo "  vbmeta <- $Vbmeta_Image  (with verity and verification DISABLED)"
echo "  boot   <- $Boot_Image"
echo
read -p "Type FLASH to proceed: " ans
[ "$ans" = "FLASH" ] || die "Aborted"

# 8. Flash
green "Flashing vbmeta (verification off)"
fastboot --disable-verity --disable-verification flash vbmeta "$Vbmeta_Image" \
  || die "vbmeta flash failed - device untouched apart from vbmeta, reflash the stock vbmeta"

green "Flashing boot"
fastboot flash boot "$Boot_Image" || {
  red "[Error] boot flash failed"
  [ -f "$Stock_Boot" ] && red "Recover with: fastboot flash boot $Stock_Boot"
  exit 1
}

green "[Done] Flashed. Reboot with: fastboot reboot"
echo
warn "If it bootloops:"
[ -f "$Stock_Boot" ] && echo "  fastboot flash boot $Stock_Boot"
echo "  fastboot flash vbmeta $Vbmeta_Image     # restores verification"
[ -n "${slot:-}" ] && echo "  or boot the other slot: fastboot set_active other"
