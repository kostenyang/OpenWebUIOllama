#!/usr/bin/env bash
# Grow the LVM root filesystem to fill the (already-larger) VMDK.
#
# ubuntu2004temp ships with /dev/sda 100 GB, sda3 holding LVM PV but the
# ubuntu-lv only takes half of it (49 GB).  deploy-vm.py resizes the VMDK
# to 200 GB; this script extends partition → PV → LV → ext4 in one shot.
#
# Run as root on the target VM after first boot:
#   bash scripts/resize-disk.sh
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "must be root"; exit 1; }

DISK=/dev/sda
PART_NUM=3
LV=/dev/mapper/ubuntu--vg-ubuntu--lv

echo "== before =="
lsblk "$DISK"
df -hT /

echo "== growpart $DISK $PART_NUM =="
growpart "$DISK" "$PART_NUM" || true  # exit 1 if already at max — fine

echo "== pvresize ${DISK}${PART_NUM} =="
pvresize "${DISK}${PART_NUM}"

echo "== lvextend -l +100%FREE $LV =="
lvextend -l +100%FREE "$LV" || true   # exit 5 if already full — fine

echo "== resize2fs $LV =="
resize2fs "$LV"

echo "== after =="
lsblk "$DISK"
df -hT /
