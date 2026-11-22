#!/usr/bin/env bash
#
# Builds the Android VM that ships inside the APK Runner IPA.
#
# Output directory (default ./AndroidVM) contains:
#   vmlinuz        Android-x86 kernel (booted directly by QEMU)
#   initrd.img     Android-x86 initrd
#   android.qcow2  disk with /android/{ramdisk.img,system.sfs,data/}
#   cmdline.txt    kernel command line
#
# Runs on Ubuntu (GitHub Actions ubuntu-latest). Needs sudo for cpio/mkfs
# ownership handling.
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-$PWD/android-build}"
OUT="${OUT:-$PWD/AndroidVM}"
ISO_URL="${ISO_URL:-https://downloads.sourceforge.net/project/android-x86/Release%209.0/android-x86_64-9.0-r2.iso}"
DISK_SIZE="${DISK_SIZE:-16G}"

mkdir -p "$WORK" "$OUT"
WORK="$(cd "$WORK" && pwd)"
OUT="$(cd "$OUT" && pwd)"

section() {
    echo
    echo "=== $* ==="
}

section "Downloading Android-x86"
if [ ! -f "$WORK/android.iso" ]; then
    curl -fL --retry 5 --retry-delay 10 -o "$WORK/android.iso" "$ISO_URL"
fi
ls -la "$WORK/android.iso"
sha256sum "$WORK/android.iso"

section "Extracting ISO"
rm -rf "$WORK/iso"
mkdir -p "$WORK/iso"
7z x -y -o"$WORK/iso" "$WORK/android.iso" > /dev/null
ls -la "$WORK/iso"
for cfg in isolinux/isolinux.cfg boot/grub/grub.cfg efi/boot/android.cfg; do
    if [ -f "$WORK/iso/$cfg" ]; then
        echo "--- $cfg"
        cat "$WORK/iso/$cfg"
    fi
done
file "$WORK/iso/ramdisk.img" "$WORK/iso/initrd.img" "$WORK/iso/kernel" || true

section "Building apkfetch"
musl-gcc -static -Os -Wall -o "$WORK/apkfetch" "$HERE/android/apkfetch.c"
strip "$WORK/apkfetch"
file "$WORK/apkfetch"

section "Patching ramdisk"
sudo rm -rf "$WORK/ramdisk"
mkdir -p "$WORK/ramdisk"
(cd "$WORK/ramdisk" && zcat "$WORK/iso/ramdisk.img" | sudo cpio -idm --quiet)
ls -la "$WORK/ramdisk"
for prop in default.prop prop.default; do
    if [ -f "$WORK/ramdisk/$prop" ]; then
        echo "--- $prop"
        grep -E "ro\.(debuggable|secure|adb|build\.type)|selinux" "$WORK/ramdisk/$prop" || true
    fi
done
sudo mkdir -p "$WORK/ramdisk/apkrunner"
sudo install -m 0755 "$WORK/apkfetch" "$WORK/ramdisk/apkrunner/apkfetch"
sudo install -m 0755 "$HERE/android/apkrunner.sh" "$WORK/ramdisk/apkrunner/apkrunner.sh"
sudo sh -c "cat '$HERE/android/apkrunner.rc' >> '$WORK/ramdisk/init.rc'"
tail -n 15 "$WORK/ramdisk/init.rc"
(cd "$WORK/ramdisk" && sudo sh -c 'find . | LC_ALL=C sort | cpio -o -H newc -R root:root --quiet | gzip -9') > "$WORK/ramdisk.img"
ls -la "$WORK/iso/ramdisk.img" "$WORK/ramdisk.img"

section "Inspecting system image"
sudo rm -rf "$WORK/sfs"
sudo unsquashfs -s "$WORK/iso/system.sfs" | head -n 12 || true
sudo unsquashfs -d "$WORK/sfs" "$WORK/iso/system.sfs" > /dev/null
ls -la "$WORK/sfs"
sudo mkdir -p /mnt/androidsys
if sudo mount -o loop,ro "$WORK/sfs/system.img" /mnt/androidsys; then
    SYSROOT=/mnt/androidsys
    [ -d /mnt/androidsys/system ] && SYSROOT=/mnt/androidsys/system
    grep -E "ro\.build\.(type|version\.release|display\.id)|ro\.product\.cpu\.abilist|nativebridge" "$SYSROOT/build.prop" || true
    echo "--- enable_nativebridge"
    sudo cat "$SYSROOT/bin/enable_nativebridge" 2>/dev/null | head -n 80 || echo "(missing)"
    echo "--- etc/init"
    ls "$SYSROOT/etc/init" | head -n 80 || true
    echo "--- toybox / tools"
    ls "$SYSROOT/bin" | grep -E "^(nc|netcat|wget|curl|busybox|toybox|monkey|pm|am|cmd|svc|settings|locksettings|input|wm)$" || true
    sudo umount /mnt/androidsys
fi
sudo rm -rf "$WORK/sfs"

section "Building disk image"
sudo rm -rf "$WORK/disk"
mkdir -p "$WORK/disk/android/data"
cp "$WORK/iso/system.sfs" "$WORK/disk/android/system.sfs"
cp "$WORK/ramdisk.img" "$WORK/disk/android/ramdisk.img"
sudo chown -R 0:0 "$WORK/disk"
rm -f "$WORK/disk.raw"
# no orphan_file / metadata_csum_seed: the Android-x86 4.19 kernel cannot mount those read-write
sudo mkfs.ext4 -q -F -L ANDROID -O ^orphan_file,^metadata_csum_seed -d "$WORK/disk" "$WORK/disk.raw" "$DISK_SIZE"
sudo chown "$(id -u):$(id -g)" "$WORK/disk.raw"
qemu-img convert -O qcow2 "$WORK/disk.raw" "$OUT/android.qcow2"
rm -f "$WORK/disk.raw"
qemu-img info "$OUT/android.qcow2"

section "Collecting outputs"
cp "$WORK/iso/kernel" "$OUT/vmlinuz"
cp "$WORK/iso/initrd.img" "$OUT/initrd.img"
cp "$HERE/android/cmdline.txt" "$OUT/cmdline.txt"
ls -la "$OUT"
