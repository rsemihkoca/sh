#!/bin/bash

# Windows 10 Installation - LEGACY BIOS VERSION
# Uses sda4 (6GB) for temporary ISO storage
# For OVH VPS - Legacy BIOS mode
# GitHub: https://github.com/rsemihkoca/sh

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

ISO_URL="https://software.download.prss.microsoft.com/dbazure/Win10_22H2_English_x64v1.iso?t=781f2471-b77c-4638-b68b-7f0e243fa0f7&P1=1767636764&P2=601&P3=2&P4=xvhom209oOzLuLZR2xxcAhCA3NtLdn5QySZ0a051geiXPtw01Ld7HqdQgV8KqKCpKSRq5GcRmLWXzZj4S0F5X5aoIr0UVf6WXljjaGjMT09EUcINyjquY6KOmJ3%2bhxWaiROuToGno9YfxJDvLteh4h%2bo0BIrcgjJ8sbCme9B5n3VnWSOT1gHe%2fAFwLCAxp7qbn7%2fyjwFCS85tWEIzKtnUOUH8L13Y8Eq55P5kn3WfGaEGbto0P35%2b54mRGJnFP9GStR5qFKI5wLYFfVKvKoM5gT4%2fsICaBrqn4kLPX0mPfzJG3W0ALMvtFXGpZjqpNkgzZLtTdHwM2jgO9yuXicxTQ%3d%3d"

TARGET_DISK="/dev/sda"

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
    banner "Windows 10 Installer - LEGACY BIOS"
    
    warning "This version uses Legacy BIOS (MBR) boot for OVH VPS compatibility"
    echo ""
    
    # ============================================
    # STEP 1: Validation
    # ============================================
    log "Step 1: Pre-flight checks"
    
    [ "$EUID" -ne 0 ] && error "Must run as root"
    [ ! -b "$TARGET_DISK" ] && error "$TARGET_DISK not found"
    [ ! -b "${TARGET_DISK}4" ] && error "sda4 not found - run create_sda4.sh first"
    
    info "Current disk layout:"
    lsblk
    echo ""
    
    # ============================================
    # STEP 2: Install tools
    # ============================================
    log "Step 2: Installing required tools"
    
    apt-get update -qq
    apt-get install -y wget p7zip-full ntfs-3g dosfstools parted rsync grub-pc-bin -qq || error "Package install failed"
    info "✓ Tools installed (including GRUB)"
    
    # ============================================
    # STEP 3: Mount sda4 for temporary storage
    # ============================================
    log "Step 3: Preparing temporary workspace on sda4"
    
    mkdir -p /mnt/temp
    
    # Check if already mounted
    if mountpoint -q /mnt/temp; then
        info "sda4 already mounted"
    else
        mount "${TARGET_DISK}4" /mnt/temp 2>/dev/null || {
            warning "sda4 not formatted, formatting now..."
            mkfs.ext4 -L "TEMP" "${TARGET_DISK}4"
            mount "${TARGET_DISK}4" /mnt/temp
        }
    fi
    
    info "Mounted sda4 at /mnt/temp"
    df -h /mnt/temp
    echo ""
    
    # Check if sda4 has enough space
    local available_space=$(df -BM /mnt/temp | awk 'NR==2 {print $4}' | sed 's/M//')
    info "Available space on sda4: ${available_space}MB"
    
    if [ "$available_space" -lt 5500 ]; then
        warning "sda4 is full or nearly full!"
        warning "Cleaning up old files..."
        
        info "Current contents:"
        du -sh /mnt/temp/* 2>/dev/null || echo "Empty or no permission"
        
        read -p "Delete all files on sda4? (yes/NO): " confirm
        if [ "$confirm" = "yes" ]; then
            rm -rf /mnt/temp/*
            info "✓ sda4 cleaned"
            df -h /mnt/temp
        else
            error "Not enough space on sda4. Clean manually or type 'yes'"
        fi
    else
        info "✓ sda4 has enough space"
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
        info "Downloading ~5.7GB to sda4..."
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
    # STEP 6: Format Windows partition (sda3)
    # ============================================
    log "Step 6: Formatting Windows partition"
    
    umount "${TARGET_DISK}3" 2>/dev/null || true
    
    info "Formatting sda3 as NTFS..."
    mkfs.ntfs -f -L "Windows" "${TARGET_DISK}3" || error "Format failed"
    info "✓ sda3 formatted as NTFS"
    
    # Convert sda2 to BIOS Boot partition
    info "Converting sda2 to BIOS Boot partition..."
    parted -s "${TARGET_DISK}" set 2 bios_grub on
    info "✓ sda2 is now BIOS Boot partition"
    
    info "Partition status:"
    blkid | grep sda || true
    parted "${TARGET_DISK}" print
    echo ""
    
    # ============================================
    # STEP 7: Copy files to Windows partition
    # ============================================
    log "Step 7: Copying files to Windows partition"
    
    mkdir -p /mnt/win
    mount "${TARGET_DISK}3" /mnt/win || error "Failed to mount sda3"
    
    info "Mounted sda3 at /mnt/win"
    df -h /mnt/win
    echo ""
    
    info "Copying files from sda4 to sda3..."
    info "This will take 10-15 minutes"
    echo ""
    
    rsync -ah --info=progress2 "$EXTRACT_DIR/" /mnt/win/ || error "File copy failed"
    
    sync
    info "✓ Files copied successfully"
    
    local copied_files=$(find /mnt/win -type f | wc -l)
    info "Files on Windows partition: $copied_files"
    echo ""
    
    # ============================================
    # STEP 8: Setup GRUB Legacy BIOS bootloader
    # ============================================
    log "Step 8: Setting up GRUB Legacy BIOS bootloader"
    
    info "Installing GRUB to MBR..."
    grub-install --target=i386-pc --boot-directory=/mnt/win/boot "${TARGET_DISK}" || error "GRUB install failed"
    info "✓ GRUB installed to MBR"
    
    info "Creating GRUB configuration..."
    mkdir -p /mnt/win/boot/grub
    
    cat > /mnt/win/boot/grub/grub.cfg << 'GRUBEOF'
set timeout=3
set default=0

insmod part_gpt
insmod ntfs
insmod chain

menuentry "Windows 10 Setup" {
    search --set=root --file /bootmgr
    ntldr /bootmgr
    boot
}
GRUBEOF
    
    info "✓ GRUB configuration created"
    
    # Set partition flags for legacy boot
    parted "${TARGET_DISK}" set 3 legacy_boot on
    info "✓ Legacy boot flag set on sda3"
    
    sync
    umount /mnt/win
    
    info "✓ Bootloader configured"
    echo ""
    
    # ============================================
    # STEP 9: Cleanup temporary files
    # ============================================
    log "Step 9: Cleaning up temporary files"
    
    info "Removing ISO and extracted files from sda4..."
    rm -f "$ISO_FILE"
    rm -rf "$EXTRACT_DIR"
    
    df -h /mnt/temp
    umount /mnt/temp
    
    info "✓ Temporary files cleaned"
    
    # ============================================
    # STEP 10: Final verification
    # ============================================
    log "Step 10: Final verification"
    
    info "Final disk layout:"
    lsblk "$TARGET_DISK"
    echo ""
    
    info "Partition info:"
    parted "${TARGET_DISK}" print
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
    local critical_files=("setup.exe" "sources/boot.wim" "sources/install.wim" "bootmgr")
    for file in "${critical_files[@]}"; do
        if [ -f "/mnt/win/$file" ]; then
            info "✓ Found: $file"
        else
            warning "Missing: $file"
        fi
    done
    echo ""
    
    # Check GRUB
    if [ -f "/mnt/win/boot/grub/grub.cfg" ]; then
        info "✓ GRUB config exists"
    else
        warning "GRUB config missing!"
    fi
    
    umount /mnt/win
    
    # ============================================
    # SUCCESS!
    # ============================================
    banner "INSTALLATION COMPLETE - LEGACY BIOS!"
    
    info "Windows 10 is ready to boot on $TARGET_DISK"
    echo ""
    log "Partition layout:"
    info "  sda1 (500M)  - Unused (was EFI)"
    info "  sda2 (16M)   - BIOS Boot (for GRUB)"
    info "  sda3 (62G)   - Windows (NTFS)"
    info "  sda4 (12G)   - Temporary (can be deleted later)"
    echo ""
    log "Boot configuration:"
    info "  - Bootloader: GRUB (Legacy BIOS/MBR)"
    info "  - Boot mode: Legacy BIOS"
    info "  - Boot device: ${TARGET_DISK}"
    echo ""
    log "Next steps:"
    echo "  1. Go to OVHcloud control panel"
    echo "  2. Click 'Netboot' or 'Boot mode'"
    echo "  3. Select 'Boot from hard disk'"
    echo "  4. Exit rescue mode"
    echo "  5. Reboot the VPS"
    echo "  6. GRUB menu will appear"
    echo "  7. Select 'Windows 10 Setup'"
    echo ""
    warning "Important notes:"
    echo "  - OVH VPS uses Legacy BIOS by default (not UEFI)"
    echo "  - GRUB will chainload Windows bootmgr"
    echo "  - Complete Windows setup within OVH time limits"
    echo "  - You'll need a valid Windows license key"
    echo ""
    info "Installation log: /tmp/extract.log"
    echo ""
}

# Error handler
trap 'error "Script failed at line $LINENO"' ERR

# Run
main