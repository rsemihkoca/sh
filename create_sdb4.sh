#!/bin/bash

# Create sdb4 (12GB) by shrinking sdb3

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

[ "$EUID" -ne 0 ] && error "Must run as root"

log "Current disk layout:"
lsblk /dev/sdb
echo ""

log "Unmounting sdb3 if mounted..."
umount /dev/sdb3 2>/dev/null || true

log "Deleting sdb3..."
parted -s /dev/sdb rm 3

log "Creating new sdb3 (62.5GB)..."
parted -s /dev/sdb mkpart primary ntfs 517MiB 63989MiB

log "Creating sdb4 (12GB)..."
parted -s /dev/sdb mkpart primary ext4 63989MiB 76277MiB

log "Waiting for kernel to recognize partitions..."
sleep 2
partprobe /dev/sdb
sleep 2

log "New partition layout:"
lsblk /dev/sdb
fdisk -l /dev/sdb

log "Formatting sdb4 as ext4..."
mkfs.ext4 -L "TEMP" /dev/sdb4

log "✓ Done! sdb4 (12GB) created and formatted"
echo ""
log "sdb3: 62.5GB (for Windows)"
log "sdb4: 12GB (for temporary ISO download)"