#!/bin/bash

# Windows 10 Installation - Final Version
# Uses sdb4 (6GB) for temporary ISO storage
# GitHub: https://github.com/rsemihkoca/sh



# BU KOD ÇALIŞTI AMA UEFI BOOT OLUSTURUYOR MUHTEMELEN FREEBSD SECMEZSEN OVH LEGACY BOOT EDIYOR HEP
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

ISO_URL="https://software.download.prss.microsoft.com/dbazure/Win10_22H2_English_x64v1.iso?t=781f2471-b77c-4638-b68b-7f0e243fa0f7&P1=1767636764&P2=601&P3=2&P4=xvhom209oOzLuLZR2xxcAhCA3NtLdn5QySZ0a051geiXPtw01Ld7HqdQgV8KqKCpKSRq5GcRmLWXzZj4S0F5X5aoIr0UVf6WXljjaGjMT09EUcINyjquY6KOmJ3%2bhxWaiROuToGno9YfxJDvLteh4h%2bo0BIrcgjJ8sbCme9B5n3VnWSOT1gHe%2fAFwLCAxp7qbn7%2fyjwFCS85tWEIzKtnUOUH8L13Y8Eq55P5kn3WfGaEGbto0P35%2b54mRGJnFP9GStR5qFKI5wLYFfVKvKoM5gT4%2fsICaBrqn4kLPX0mPfzJG3W0ALMvtFXGpZjqpNkgzZLtTdHwM2jgO9yuXicxTQ%3d%3d"

TARGET_DISK="/dev/sdb"

log() { echo -e "${GREEN}[$(date +'%H:%M:%S')]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
info() { echo -e "${BLUE}[INFO]${NC} $1"; }

banner() {
    echo ""
    echo -e "${GREEN}=========================================${NC}"
    echo -e "${GREEN}  $1${NC}"
    echo -e "${GREEN}=========================================${NC}"
    echo ""
}

main() {
    banner "Windows 10 Installer - Final"
    
    # ============================================
    # STEP 1: Validation
    # ============================================
    log "Step 1: Pre-flight checks"
    
    [ "$EUID" -ne 0 ] && error "Must run as root"
    [ ! -b "$TARGET_DISK" ] && error "$TARGET_DISK not found"
    [ ! -b "${TARGET_DISK}4" ] && error "sdb4 not found - run create_sdb4.sh first"
    
    info "Current disk layout:"
    lsblk
    echo ""
    
    # ============================================
    # STEP 2: Install tools
    # ============================================
    log "Step 2: Installing required tools"
    
    apt-get update -qq
    apt-get install -y wget p7zip-full ntfs-3g dosfstools rsync -qq || error "Package install failed"
    info "✓ Tools installed"
    
    # ============================================
    # STEP 3: Mount sdb4 for temporary storage
    # ============================================
    log "Step 3: Preparing temporary workspace on sdb4"
    
    mkdir -p /mnt/temp
    
    # Check if already mounted
    if mountpoint -q /mnt/temp; then
        info "sdb4 already mounted"
    else
        mount "${TARGET_DISK}4" /mnt/temp 2>/dev/null || {
            warning "sdb4 not formatted, formatting now..."
            mkfs.ext4 -L "TEMP" "${TARGET_DISK}4"
            mount "${TARGET_DISK}4" /mnt/temp
        }
    fi
    
    info "Mounted sdb4 at /mnt/temp"
    df -h /mnt/temp
    echo ""
    
    # Check if sdb4 has enough space
    local available_space=$(df -BM /mnt/temp | awk 'NR==2 {print $4}' | sed 's/M//')
    info "Available space on sdb4: ${available_space}MB"
    
    if [ "$available_space" -lt 5500 ]; then
        warning "sdb4 is full or nearly full!"
        warning "Cleaning up old files..."
        
        info "Current contents:"
        du -sh /mnt/temp/* 2>/dev/null || echo "Empty or no permission"
        
        read -p "Delete all files on sdb4? (yes/NO): " confirm
        if [ "$confirm" = "yes" ]; then
            rm -rf /mnt/temp/*
            info "✓ sdb4 cleaned"
            df -h /mnt/temp
        else
            error "Not enough space on sdb4. Clean manually or type 'yes'"
        fi
    else
        info "✓ sdb4 has enough space"
    fi
    echo ""
    
    ISO_FILE="/mnt/temp/windows10.iso"
    EXTRACT_DIR="/mnt/temp/extracted"
    
    mkdir -p "$EXTRACT_DIR"
    
    # ============================================
    # STEP 4: Download Windows 10 ISO
    # ============================================
    log "Step 4: Downloading Windows 10 ISO"
    
    if [ -f "$ISO_FILE" ]; then
        local size=$(stat -c%s "$ISO_FILE")
        local size_mb=$((size/1024/1024))
        warning "ISO already exists: ${size_mb}MB"
        
        if [ "$size_mb" -lt 4000 ]; then
            warning "File seems incomplete, re-downloading..."
            rm -f "$ISO_FILE"
        else
            info "Using existing ISO"
        fi
    fi
    
    if [ ! -f "$ISO_FILE" ]; then
        info "Downloading ~5.7GB to sdb4..."
        info "This will take 5-15 minutes"
        echo ""
        
        wget --progress=bar:force \
             --tries=3 \
             --continue \
             -O "$ISO_FILE" \
             "$ISO_URL" || error "Download failed"
        
        local size=$(stat -c%s "$ISO_FILE")
        info "✓ Downloaded: $((size/1024/1024))MB"
    fi
    
    df -h /mnt/temp
    echo ""
    
    # ============================================
    # STEP 5: Extract ISO
    # ============================================
    log "Step 5: Extracting Windows ISO"
    
    if [ -d "$EXTRACT_DIR/sources" ]; then
        warning "Files already extracted, skipping..."
    else
        info "Extracting ISO (10-15 minutes)..."
        info "Please be patient..."
        echo ""
        
        7z x "$ISO_FILE" -o"$EXTRACT_DIR" -y > /tmp/extract.log 2>&1 || {
            error "Extraction failed - check /tmp/extract.log"
        }
    fi
    
    local file_count=$(find "$EXTRACT_DIR" -type f | wc -l)
    info "✓ Extracted $file_count files"
    
    df -h /mnt/temp
    echo ""
    
    # ============================================
    # STEP 6: Format Windows partition (sdb3)
    # ============================================
    log "Step 6: Formatting Windows partition"
    
    umount "${TARGET_DISK}3" 2>/dev/null || true
    
    info "Formatting sdb3 as NTFS..."
    mkfs.ntfs -f -L "Windows" "${TARGET_DISK}3" || error "Format failed"
    info "✓ sdb3 formatted as NTFS"
    
    # Format EFI partition (sdb1)
    info "Formatting sdb1 as FAT32..."
    mkfs.fat -F32 -n "SYSTEM" "${TARGET_DISK}1" || error "EFI format failed"
    info "✓ sdb1 formatted as FAT32"
    
    info "Partition status:"
    blkid | grep sdb
    echo ""
    
    # ============================================
    # STEP 7: Copy files to Windows partition
    # ============================================
    log "Step 7: Copying files to Windows partition"
    
    mkdir -p /mnt/win
    mount "${TARGET_DISK}3" /mnt/win || error "Failed to mount sdb3"
    
    info "Mounted sdb3 at /mnt/win"
    df -h /mnt/win
    echo ""
    
    info "Copying files from sdb4 to sdb3..."
    info "This will take 10-15 minutes"
    echo ""
    
    rsync -ah --info=progress2 "$EXTRACT_DIR/" /mnt/win/ || error "File copy failed"
    
    sync
    info "✓ Files copied successfully"
    
    local copied_files=$(find /mnt/win -type f | wc -l)
    info "Files on Windows partition: $copied_files"
    echo ""
    
    # ============================================
    # STEP 8: Setup EFI bootloader
    # ============================================
    log "Step 8: Setting up EFI bootloader"
    
    mkdir -p /mnt/efi
    mount "${TARGET_DISK}1" /mnt/efi || error "Failed to mount EFI"
    
    mkdir -p /mnt/efi/EFI/Boot
    mkdir -p /mnt/efi/EFI/Microsoft
    
    info "Searching for bootx64.efi..."
    
    # Try different paths
    local bootloader_found=false
    
    if [ -f "/mnt/win/efi/boot/bootx64.efi" ]; then
        cp /mnt/win/efi/boot/bootx64.efi /mnt/efi/EFI/Boot/
        bootloader_found=true
        info "✓ Copied: efi/boot/bootx64.efi"
    elif [ -f "/mnt/win/EFI/BOOT/BOOTX64.EFI" ]; then
        cp /mnt/win/EFI/BOOT/BOOTX64.EFI /mnt/efi/EFI/Boot/bootx64.efi
        bootloader_found=true
        info "✓ Copied: EFI/BOOT/BOOTX64.EFI"
    else
        warning "Standard paths not found, searching..."
        find /mnt/win -iname "bootx64.efi" -exec cp {} /mnt/efi/EFI/Boot/ \; 2>/dev/null && \
            bootloader_found=true
    fi
    
    [ "$bootloader_found" = false ] && warning "bootx64.efi not found!"
    
    # Copy Microsoft boot files
    if [ -d "/mnt/win/efi/microsoft" ]; then
        cp -r /mnt/win/efi/microsoft/* /mnt/efi/EFI/Microsoft/ 2>/dev/null || true
        info "✓ Copied Microsoft boot files (lowercase)"
    elif [ -d "/mnt/win/EFI/Microsoft" ]; then
        cp -r /mnt/win/EFI/Microsoft/* /mnt/efi/EFI/Microsoft/ 2>/dev/null || true
        info "✓ Copied Microsoft boot files (uppercase)"
    fi
    
    # Also copy entire efi/boot directory
    if [ -d "/mnt/win/efi/boot" ]; then
        cp -r /mnt/win/efi/boot/* /mnt/efi/EFI/Boot/ 2>/dev/null || true
    elif [ -d "/mnt/win/EFI/BOOT" ]; then
        cp -r /mnt/win/EFI/BOOT/* /mnt/efi/EFI/Boot/ 2>/dev/null || true
    fi
    
    info "EFI partition contents:"
    find /mnt/efi -type f
    echo ""
    
    sync
    umount /mnt/win
    umount /mnt/efi
    
    info "✓ Bootloader configured"
    
    # ============================================
    # STEP 9: Cleanup temporary files
    # ============================================
    log "Step 9: Cleaning up temporary files"
    
    info "Removing ISO and extracted files from sdb4..."
    rm -f "$ISO_FILE"
    rm -rf "$EXTRACT_DIR"
    
    df -h /mnt/temp
    umount /mnt/temp
    
    info "✓ Temporary files cleaned"
    
    # # ============================================
    # # STEP 10: Delete sdb4 and expand sdb3
    # # ============================================
    # log "Step 10: Reclaiming space from sdb4"
    
    # info "Deleting sdb4..."
    # parted -s "$TARGET_DISK" rm 4
    
    # info "Expanding sdb3 to use all available space..."
    # parted -s "$TARGET_DISK" resizepart 3 100%
    
    # sleep 2
    # partprobe "$TARGET_DISK"
    # sleep 2
    
    # info "Expanding NTFS filesystem..."
    # ntfsresize -f "${TARGET_DISK}3" || warning "NTFS resize failed (may need Windows to do it)"
    
    # info "✓ sdb4 removed, sdb3 expanded"
    
    # ============================================
    # STEP 11: Final verification
    # ============================================
    log "Step 11: Final verification"
    
    info "Final disk layout:"
    lsblk "$TARGET_DISK"
    echo ""
    
    info "Partition info:"
    blkid | grep sdb
    echo ""
    
    # Quick file check
    mount "${TARGET_DISK}3" /mnt/win
    local final_count=$(find /mnt/win -type f | wc -l)
    info "Total files on Windows partition: $final_count"
    
    if [ "$final_count" -lt 100 ]; then
        warning "File count seems low!"
    else
        info "✓ File count looks good"
    fi
    
    info "Sample files:"
    ls -lh /mnt/win/ | head -15
    echo ""
    
    # Check for critical files
    local critical_files=("setup.exe" "sources/boot.wim" "sources/install.wim")
    for file in "${critical_files[@]}"; do
        if [ -f "/mnt/win/$file" ]; then
            info "✓ Found: $file"
        else
            warning "Missing: $file"
        fi
    done
    echo ""
    
    umount /mnt/win
    
    # ============================================
    # SUCCESS!
    # ============================================
    banner "INSTALLATION COMPLETE!"
    
    info "Windows 10 is ready to boot on $TARGET_DISK"
    echo ""
    log "Partition layout:"
    info "  sdb1 (500M)  - EFI System (FAT32)"
    info "  sdb2 (16M)   - MSR"
    info "  sdb3 (74.5G) - Windows (NTFS)"
    echo ""
    log "Next steps:"
    echo "  1. Go to OVHcloud control panel"
    echo "  2. Click 'Netboot' or 'Boot mode'"
    echo "  3. Select 'Boot from hard disk'"
    echo "  4. Exit rescue mode"
    echo "  5. Reboot the VPS"
    echo "  6. Windows 10 Setup will start"
    echo ""
    warning "Important notes:"
    echo "  - Complete Windows setup within OVH time limits"
    echo "  - You'll need a valid Windows license key"
    echo "  - Configure network settings during setup"
    echo ""
    info "Installation log: /tmp/extract.log"
    echo ""
}

# Error handler
trap 'error "Script failed at line $LINENO"' ERR

# Run
main