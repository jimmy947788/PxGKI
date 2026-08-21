#!/bin/bash
#
# Repack a fastboot-flashable boot image from an already-built kernel Image.
#
# Buildkernel.sh produces dist/Image and an AnyKernel3 zip, but NOT a boot image you can
# "fastboot flash boot". This script fills that gap: it lz4-compresses dist/Image (legacy
# frame -- the format the Pixel bootloader decompresses) and packs it into a header-v4,
# ramdisk-less boot image with the exact layout of the stock raven boot.img (kernel only,
# no ramdisk, empty cmdline). Only the kernel differs from stock, so it boots as reliably
# as the stock image.
#
#   ./Repackboot.sh                 # repack Buildkernel/dist/Image
#   ./Repackboot.sh path/to/Image   # repack a specific Image
#
# Metadata (kernel release, KSU version, whether KPM/kpimg is embedded) is read straight
# out of the Image and encoded in the output name. The result lands in Buildkernel/patched/,
# where Flashkernel.sh picks up the newest boot_sukisu_*.img automatically.
#
# Typical use is the recovery path when a build was interrupted after the dist step but
# before the KPM patch/packaging ran (e.g. Buildkernel.sh was edited while running):
#   cd Buildkernel/dist && cp ../patch_linux-<ver> patch_linux && ./patch_linux \
#     && mv Image Image.orig && mv oImage Image && cp Image kernel
#   cd ../.. && ./Repackboot.sh

set -uo pipefail

export Working_Dir="${Working_Dir:-$HOME/Projects/PxGKI}"
Build_Dir="$Working_Dir/Buildkernel"
Image="${1:-$Build_Dir/dist/Image}"
Patched_Dir="$Build_Dir/patched"
MK="$Build_Dir/tools/mkbootimg/mkbootimg.py"
UNPACK="$Build_Dir/tools/mkbootimg/unpack_bootimg.py"

red()   { echo -e "\e[31m$*\e[0m"; }
green() { echo -e "\e[32m$*\e[0m"; }
warn()  { echo -e "\e[33m$*\e[0m"; }
die()   { red "[Error] $*"; exit 1; }

command -v lz4 >/dev/null 2>&1 || die "lz4 not found (apt install lz4)"
[ -f "$Image" ] || die "Image not found: $Image (run Buildkernel.sh first)"
[ -f "$MK" ]    || die "mkbootimg.py not found at $MK (run Buildkernel.sh first)"
mkdir -p "$Patched_Dir"

green "Repacking boot image from: $Image"

# Read metadata out of the Image itself
Release=$(strings "$Image" | grep -m1 -oE 'Linux version [0-9][^ ]*' | cut -d' ' -f3)
KsuVer=$(strings -n 6 "$Image" | grep -m1 -aoE 'v[0-9]+\.[0-9]+\.[0-9]+-[0-9a-f]+@[A-Za-z]+')
Kpm=$(strings -n 6 "$Image" | grep -c KernelPatch)
[ -n "$Release" ] || die "could not read the kernel release string from $Image"
echo "  kernel release : $Release"
echo "  KSU version    : ${KsuVer:-unknown}"
echo "  KPM (kpimg)    : $([ "$Kpm" -gt 0 ] && echo "yes ($Kpm KernelPatch strings)" || echo no)"

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# Compress with the lz4 legacy frame (magic 02 21 4c 18) -- what the raven bootloader
# expects. -l -12 --favor-decSpeed matches the stock kernel's compression settings.
green "Compressing kernel (lz4 legacy)"
lz4 -l -12 --favor-decSpeed -q -f "$Image" "$tmp/kernel.lz4" || die "lz4 compression failed"
magic=$(od -An -tx1 -N4 "$tmp/kernel.lz4" | tr -d ' \n')
[ "$magic" = "02214c18" ] || die "lz4 output magic is $magic, expected 02214c18 (legacy frame)"

# Output name: boot_sukisu_<short-release>[_<ksu-tag>][_kpm].img
Short_Release="${Release%%-*}"                                  # 5.10.157
Tag=$(printf '%s' "$KsuVer" | grep -oE '^v[0-9]+\.[0-9]+\.[0-9]+')   # v4.1.3
Name="boot_sukisu_${Short_Release}"
[ -n "$Tag" ] && Name="${Name}_${Tag}"
[ "$Kpm" -gt 0 ] && Name="${Name}_kpm"
Out="$Patched_Dir/${Name}.img"

green "Packing header-v4 boot image (kernel only, no ramdisk -- stock raven layout)"
python3 "$MK" --header_version 4 --kernel "$tmp/kernel.lz4" --output "$Out" \
  || die "mkbootimg failed"

# Round-trip verify: the packed image must decompress back to the same kernel
green "Verifying"
python3 "$UNPACK" --boot_img "$Out" --out "$tmp/v" >/dev/null 2>&1 || die "unpack of $Out failed"
lz4 -d -l -q -f "$tmp/v/kernel" "$tmp/v/Image.raw" 2>/dev/null \
  || lz4 -d -q -f "$tmp/v/kernel" "$tmp/v/Image.raw" || die "could not decompress packed kernel"
v_release=$(strings "$tmp/v/Image.raw" | grep -m1 -oE 'Linux version [0-9][^ ]*' | cut -d' ' -f3)
v_kpm=$(strings -n 6 "$tmp/v/Image.raw" | grep -c KernelPatch)
[ "$v_release" = "$Release" ] || die "verify: release mismatch ($v_release vs $Release)"
[ "$v_kpm" -eq "$Kpm" ]       || die "verify: KernelPatch count mismatch ($v_kpm vs $Kpm)"

green "[Done] $Out"
echo "  release        : $v_release"
echo "  KPM embedded   : $([ "$v_kpm" -gt 0 ] && echo yes || echo no)"
echo "  size           : $(stat -c%s "$Out") bytes"
echo
echo "Flash it with:  ./Flashkernel.sh          # picks the newest boot_sukisu_*.img"
