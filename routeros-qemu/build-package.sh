#!/usr/bin/env bash
# Assemble the resource package on the device and pull it back.
#
#   ./build-package.sh [chr-image] [output.tar.gz]
#
# Assembling on-device is deliberate: it avoids shuttling the ~60 MB QEMU
# runtime over adb twice, and guarantees the binaries match the device's ABI.
#
# What you must supply yourself (neither is redistributable here):
#   * the CHR image  — download chr-<ver>-arm64.img.zip from mikrotik.com,
#                      unzip it, and pass the .img as the first argument
#                      (or drop it next to this script as routeros.img).
#   * the helpers    — garp / ra6 / kvm-probe / ttyd. They are taken from a
#                      local vendor/ directory if present, otherwise from an
#                      existing plug-in install on the device.
#
# Resulting layout:
#   routeros.img            CHR ARM64 raw disk
#   edk2-aarch64-code.fd    UEFI firmware
#   edk2-arm-vars.fd        UEFI variable-store template
#   qemu/usr/{bin,lib,share}
#   garp ra6 kvm-probe ttyd
set -euo pipefail
cd "$(dirname "$0")"

IMG="${1:-routeros.img}"
OUT="${2:-routeros-qemu-vm-arm64.tar.gz}"
STAGE=/data/local/tmp/rosq-pkg
VENDOR=vendor

command -v adb >/dev/null || { echo "adb not on PATH" >&2; exit 1; }

if [ ! -f "$IMG" ]; then
  cat >&2 <<EOF
missing CHR image: $IMG

Download chr-<version>-arm64.img.zip from
  https://mikrotik.com/download?architecture=arm64
(ARM64 CHR exists from RouterOS 7.15 onward), unzip it, then either:
  ./build-package.sh /path/to/chr-7.24.2-arm64.img
or drop it here as ./routeros.img and re-run.
EOF
  exit 1
fi

# A CHR image is GPT: protective MBR signature + "EFI PART" at LBA 1.
head -c 512 "$IMG" | tail -c 2 | od -An -tx1 | tr -d ' \n' | grep -q '55aa' \
  || { echo "$IMG is not a disk image (no MBR signature)" >&2; exit 1; }
dd if="$IMG" bs=1 skip=512 count=8 2>/dev/null | grep -aq 'EFI PART' \
  || { echo "$IMG is not GPT — CHR images are GPT" >&2; exit 1; }

echo "==> pushing CHR image ($(du -h "$IMG" | cut -f1))"
adb push "$IMG" /data/local/tmp/rosq-routeros.img >/dev/null

# Helpers: prefer a local vendor/ dir so a build is reproducible offline.
for f in garp ra6 kvm-probe dhcp-relay sparse-writer ttyd; do
  [ -f "$VENDOR/$f" ] || continue
  adb push "$VENDOR/$f" "/data/local/tmp/rosq-$f" >/dev/null
  echo "    vendor/$f"
done

echo "==> assembling on device"
adb shell "su -c '
set -eu
STAGE=$STAGE
rm -rf \$STAGE; mkdir -p \$STAGE/qemu/usr/bin \$STAGE/qemu/usr/lib \$STAGE/qemu/usr/share/qemu

cp /data/local/tmp/rosq-routeros.img \$STAGE/routeros.img

# QEMU runtime + edk2: from an existing DroidVM/plug-in install.
QROOT=""
for c in /data/local/mikrotik/qemu/usr /data/local/droidvm/usr; do
  [ -x \$c/bin/qemu-system-aarch64 ] && { QROOT=\$c; break; }
done
[ -n \"\$QROOT\" ] || { echo \"NO_QEMU\"; exit 3; }
cp \$QROOT/bin/qemu-system-aarch64 \$STAGE/qemu/usr/bin/
[ -f \$QROOT/bin/qemu-img ] && cp \$QROOT/bin/qemu-img \$STAGE/qemu/usr/bin/ || true
cp \$QROOT/lib/*.so \$STAGE/qemu/usr/lib/ 2>/dev/null || true
cp \$QROOT/share/qemu/efi-virtio.rom \$STAGE/qemu/usr/share/qemu/ 2>/dev/null || true
cp -r \$QROOT/share/qemu/keymaps \$STAGE/qemu/usr/share/qemu/ 2>/dev/null || true

for fw in edk2-aarch64-code.fd edk2-arm-vars.fd; do
  for c in /data/local/mikrotik/\$fw \$QROOT/share/qemu/\$fw; do
    [ -f \$c ] && { cp \$c \$STAGE/\$fw; break; }
  done
  [ -f \$STAGE/\$fw ] || { echo \"NO_FIRMWARE:\$fw\"; exit 4; }
done

# Helpers: pushed vendor copies win, else reuse whatever is installed.
for f in garp ra6 kvm-probe dhcp-relay sparse-writer ttyd; do
  if [ -f /data/local/tmp/rosq-\$f ]; then
    cp /data/local/tmp/rosq-\$f \$STAGE/\$f
  else
    for c in /data/local/mikrotik/\$f /data/local/openwrt/\$f /data/local/uefi-vm/\$f \
             /data/data/com.minikano.f50_sms/files/\$f; do
      [ -f \$c ] && { cp \$c \$STAGE/\$f; break; }
    done
  fi
done

chmod 755 \$STAGE/qemu/usr/bin/* 2>/dev/null || true
for f in garp ra6 kvm-probe dhcp-relay sparse-writer ttyd; do
  [ -f \$STAGE/\$f ] && chmod 755 \$STAGE/\$f || true
done
chmod 600 \$STAGE/routeros.img

cd \$STAGE && tar -czf /data/local/tmp/rosq-pkg.tar.gz .
echo \"--- included ---\"
ls \$STAGE
'" | sed 's/^/    /'

echo "==> pulling $OUT"
adb pull /data/local/tmp/rosq-pkg.tar.gz "$OUT" >/dev/null
adb shell "su -c 'rm -rf $STAGE /data/local/tmp/rosq-pkg.tar.gz /data/local/tmp/rosq-*'" >/dev/null 2>&1 || true
ls -lh "$OUT" | awk '{print "    " $9 "  " $5}'
