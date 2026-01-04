#!/bin/bash

# Windows 10 ISO Installer for OVHcloud VPS - v2
# Uses sdb2 as temporary storage, then wipes entire sdb for Windows

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ISO_URL="https://software.download.prss.microsoft.com/dbazure/Win10_22H2_English_x64v1.iso?t=781f2471-b77c-4638-b68b-7f0e243fa0f7&P1=1767636764&P2=601&P3=2&P4=xvhom209oOzLuLZR2xxcAhCA3NtLdn5QySZ0a051geiXPtw01Ld7HqdQgV8KqKCpKSRq5GcRmLWXzZj4S0F5X5aoIr0UVf6WXljjaGjMT09EUcINyjquY6KOmJ3%2bhxWaiROuToGno9YfxJDvLteh4h%2bo0BIrcgjJ8sbCme9B5n3VnWSOT1gHe%2fAFwLCAxp7qbn7%2fyjwFCS85tWEIzKtnUOUH8L13Y8Eq55P5kn3WfGaEGbto0P35%2b54mRGJnFP9GStR5qFKI5wLYFfVKvKoM5gT4%2fsICaBrqn4kLPX0mPfzJG3W0ALMvtFXGpZjqpNkgzZLtTdHwM2jgO9yuXicxTQ%3d%3d"
TARGET_DISK="/dev/sdb"

log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
debug() { echo -e "${YELLOW}[DEBUG]${NC} $1"; }

main() {
    log "=== Windows 10 Installation Media Creator v2 ==="
    
    # Step 1: Validate
    [ "$EUID" -ne 0 ] && error "Must run as root"
    [ ! -b "$TARGET_DISK" ] && error "$TARGET_DISK not found"
    
    log "Disk layout:"
    lsblk
    echo ""
    
    # Step 2: Mount sdb2 for temporary storage
    log "=== Preparing Temporary Storage ==="
    mkdir -p /mnt/temp
    mount /dev/sdb2 /mnt/temp 2>/dev/null || warning "sdb2 already mounted or doesn't exist"
    
    WORK_DIR="/mnt/temp/win_install"
    ISO_FILE="$WORK_DIR/windows10.iso"
    EXTRACT_DIR="$WORK_DIR/extracted"
    
    mkdir -p "$WORK_DIR"
    mkdir -p "$EXTRACT_DIR"
    
    # Step 3: Install required tools
    log "=== Installing Required Tools ==="
    apt-get update -qq
    apt-get install -y wget p7zip-full parted ntfs-3g dosfstools gdisk rsync -qq || error "Failed to install packages"
    debug "✓ Tools installed"
    
    # Step 4: Download ISO (skip if exists)
    if [ -f "$ISO_FILE" ]; then
        log "ISO already exists, skipping download"
        local size=$(stat -c%s "$ISO_FILE")
        debug "ISO size: $((size/1024/1024))MB"
    else
        log "=== Downloading Windows 10 ISO ==="
        log "This will take time - be patient..."
        wget --progress=bar:force --tries=3 --continue -O "$ISO_FILE" "$ISO_URL" || error "Download failed"
        debug "✓ ISO downloaded"
    fi
    
    # Step 5: Extract ISO
    log "=== Extracting ISO ==="
    log "This will take 10-15 minutes..."
    
    if [ -d "$EXTRACT_DIR/sources" ]; then
        log "Files already extracted, skipping..."
    else
        7z x "$ISO_FILE" -o"$EXTRACT_DIR" -y > /tmp/extract.log 2>&1 || {
            cat /tmp/extract.log
            error "Extraction failed - check /tmp/extract.log"
        }
    fi
    
    local file_count=$(find "$EXTRACT_DIR" -type f | wc -l)
    log "Extracted files: $file_count"
    debug "✓ ISO extracted successfully"
    
    # Step 6: Wipe and partition sdb
    log "=== Partitioning Disk ==="
    warning "This will ERASE all data on $TARGET_DISK"
    read -p "Type 'YES' to continue: " confirm
    [ "$confirm" != "YES" ] && error "Aborted"
    
    # Unmount everything from sdb first
    umount ${TARGET_DISK}* 2>/dev/null || true
    
    log "Wiping disk..."
    wipefs -a "$TARGET_DISK"
    
    log "Creating GPT partition table..."
    parted -s "$TARGET_DISK" mklabel gpt
    parted -s "$TARGET_DISK" mkpart primary fat32 1MiB 501MiB
    parted -s "$TARGET_DISK" set 1 esp on
    parted -s "$TARGET_DISK" mkpart primary 501MiB 517MiB
    parted -s "$TARGET_DISK" set 2 msftres on
    parted -s "$TARGET_DISK" mkpart primary ntfs 517MiB 100%
    
    sleep 3
    partprobe "$TARGET_DISK"
    sleep 2
    
    debug "✓ Partitions created"
    lsblk "$TARGET_DISK"
    
    # Step 7: Format partitions
    log "=== Formatting Partitions ==="
    mkfs.fat -F32 -n "SYSTEM" "${TARGET_DISK}1"
    mkfs.ntfs -f -L "Windows" "${TARGET_DISK}3"
    debug "✓ Partitions formatted"
    
    # Step 8: Copy files to new partitions
    log "=== Copying Windows Files ==="
    
    mkdir -p /mnt/win
    mkdir -p /mnt/efi
    
    mount "${TARGET_DISK}3" /mnt/win || error "Failed to mount Windows partition"
    log "Copying files to Windows partition (this takes time)..."
    rsync -ah --info=progress2 "$EXTRACT_DIR/" /mnt/win/ || error "Copy failed"
    debug "✓ Files copied to Windows partition"
    
    # Step 9: Setup EFI boot
    log "=== Setting up EFI Boot ==="
    mount "${TARGET_DISK}1" /mnt/efi || error "Failed to mount EFI partition"
    
    mkdir -p /mnt/efi/EFI/Boot
    
    # Find and copy bootloader
    if [ -f "/mnt/win/efi/boot/bootx64.efi" ]; then
        cp /mnt/win/efi/boot/bootx64.efi /mnt/efi/EFI/Boot/
        debug "✓ Copied bootx64.efi (lowercase path)"
    elif [ -f "/mnt/win/EFI/BOOT/BOOTX64.EFI" ]; then
        cp /mnt/win/EFI/BOOT/BOOTX64.EFI /mnt/efi/EFI/Boot/bootx64.efi
        debug "✓ Copied BOOTX64.EFI (uppercase path)"
    else
        warning "Searching for bootx64.efi..."
        find /mnt/win -iname "bootx64.efi" -exec cp {} /mnt/efi/EFI/Boot/ \; 2>/dev/null || \
        error "Could not find bootx64.efi"
    fi
    
    # Copy Microsoft directory
    [ -d "/mnt/win/efi/microsoft" ] && cp -r /mnt/win/efi/microsoft /mnt/efi/EFI/ 2>/dev/null || true
    [ -d "/mnt/win/EFI/Microsoft" ] && cp -r /mnt/win/EFI/Microsoft /mnt/efi/EFI/ 2>/dev/null || true
    
    log "EFI contents:"
    ls -lhR /mnt/efi/EFI/
    
    # Step 10: Cleanup
    log "=== Cleaning Up ==="
    sync
    umount /mnt/win
    umount /mnt/efi
    
    # Step 11: Final verification
    log "=== Final Verification ==="
    lsblk "$TARGET_DISK"
    blkid | grep sdb
    
    log "==========================================="
    log "SUCCESS! Installation complete"
    log "==========================================="
    echo ""
    log "Next steps:"
    log "1. Go to OVHcloud panel"
    log "2. Exit rescue mode"
    log "3. Reboot server"
    log "4. Windows 10 installer should start"
    echo ""
    log "Note: You can now delete /mnt/temp/win_install to free space"
}

main