#!/bin/bash

# Windows 10 Installation - RAM-based approach
# Uses /dev/shm (tmpfs) for temporary storage

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

ISO_URL="https://software.download.prss.microsoft.com/dbazure/Win10_22H2_English_x64v1.iso?t=781f2471-b77c-4638-b68b-7f0e243fa0f7&P1=1767636764&P2=601&P3=2&P4=xvhom209oOzLuLZR2xxcAhCA3NtLdn5QySZ0a051geiXPtw01Ld7HqdQgV8KqKCpKSRq5GcRmLWXzZj4S0F5X5aoIr0UVf6WXljjaGjMT09EUcINyjquY6KOmJ3%2bhxWaiROuToGno9YfxJDvLteh4h%2bo0BIrcgjJ8sbCme9B5n3VnWSOT1gHe%2fAFwLCAxp7qbn7%2fyjwFCS85tWEIzKtnUOUH8L13Y8Eq55P5kn3WfGaEGbto0P35%2b54mRGJnFP9GStR5qFKI5wLYFfVKvKoM5gT4%2fsICaBrqn4kLPX0mPfzJG3W0ALMvtFXGpZjqpNkgzZLtTdHwM2jgO9yuXicxTQ%3d%3d"

TARGET_DISK="/dev/sdb"
RAM_DIR="/dev/shm/win_temp"
ISO_FILE="$RAM_DIR/windows10.iso"
EXTRACT_DIR="$RAM_DIR/extracted"

log() { echo -e "${GREEN}[$(date +'%H:%M:%S')]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
info() { echo -e "${BLUE}[INFO]${NC} $1"; }

banner() {
    echo -e "${GREEN}=========================================${NC}"
    echo -e "${GREEN}$1${NC}"
    echo -e "${GREEN}=========================================${NC}"
}

main() {
    banner "Windows 10 Installation - RAM Method"
    
    # ============================================
    # STEP 0: Pre-flight checks
    # ============================================
    log "Step 0: Pre-flight checks"
    
    [ "$EUID" -ne 0 ] && error "Must run as root"
    [ ! -b "$TARGET_DISK" ] && error "$TARGET_DISK not found"
    
    info "Current disk layout:"
    lsblk
    echo ""
    
    info "Memory status:"
    free -h
    echo ""
    
    info "tmpfs status:"
    df -h /dev/shm
    echo ""
    
    # Check RAM availability
    local available_ram=$(free -m | awk 'NR==2 {print $7}')
    if [ "$available_ram" -lt 6000 ]; then
        error "Not enough RAM. Need 6GB+, have ${available_ram}MB"
    fi
    info "✓ RAM check passed: ${available_ram}MB available"
    
    # ============================================
    # STEP 1: Install required tools
    # ============================================
    log "Step 1: Installing required tools"
    
    apt-get update -qq
    apt-get install -y wget p7zip-full ntfs-3g dosfstools rsync -qq || error "Package installation failed"
    info "✓ Tools installed"
    
    # ============================================
    # STEP 2: Prepare RAM workspace
    # ============================================
    log "Step 2: Preparing RAM workspace"
    
    mkdir -p "$RAM_DIR"
    mkdir -p "$EXTRACT_DIR"
    
    info "Workspace: $RAM_DIR"
    info "✓ RAM workspace ready"
    
    # ============================================
    # STEP 3: Download ISO to RAM
    # ============================================
    log "Step 3: Downloading Windows 10 ISO to RAM"
    
    if [ -f "$ISO_FILE" ]; then
        warning "ISO already exists in RAM"
        local size=$(stat -c%s "$ISO_FILE")
        info "Size: $((size/1024/1024))MB"
    else
        info "Downloading ~5.7GB to RAM..."
        info "This will take 5-15 minutes depending on connection"
        
        wget --progress=bar:force \
             --tries=3 \
             --continue \
             -O "$ISO_FILE" \
             "$ISO_URL" || error "Download failed"
        
        local size=$(stat -c%s "$ISO_FILE")
        info "✓ Downloaded: $((size/1024/1024))MB"
    fi
    
    info "RAM usage after download:"
    df -h /dev/shm
    echo ""
    
    # ============================================
    # STEP 4: Extract ISO in RAM
    # ============================================
    log "Step 4: Extracting ISO in RAM"
    
    if [ -d "$EXTRACT_DIR/sources" ]; then
        warning "Files already extracted"
    else
        info "Extracting to RAM (10-15 minutes)..."
        
        7z x "$ISO_FILE" -o"$EXTRACT_DIR" -y > /tmp/extract.log 2>&1 || {
            cat /tmp/extract.log
            error "Extraction failed"
        }
    fi
    
    local file_count=$(find "$EXTRACT_DIR" -type f | wc -l)
    info "✓ Extracted $file_count files"
    
    info "RAM usage after extraction:"
    df -h /dev/shm
    echo ""
    
    # Free up ISO file from RAM
    log "Removing ISO from RAM to free space..."
    rm -f "$ISO_FILE"
    info "✓ ISO removed, RAM freed"
    df -h /dev/shm
    echo ""
    
    # ============================================
    # STEP 5: Verify partitions exist
    # ============================================
    log "Step 5: Verifying disk partitions"
    
    info "Current partition layout:"
    lsblk "$TARGET_DISK"
    fdisk -l "$TARGET_DISK"
    echo ""
    
    # Check if partitions already exist correctly
    if [ ! -b "${TARGET_DISK}1" ] || [ ! -b "${TARGET_DISK}3" ]; then
        error "Partitions not found. Expected sdb1 (EFI) and sdb3 (Windows)"
    fi
    
    info "✓ Partitions exist: sdb1 (EFI), sdb2 (MSR), sdb3 (Windows)"
    
    # ============================================
    # STEP 6: Format partitions (if needed)
    # ============================================
    log "Step 6: Formatting partitions"
    
    # Unmount if mounted
    umount "${TARGET_DISK}"* 2>/dev/null || true
    
    # Format EFI partition (FAT32)
    info "Formatting sdb1 as FAT32 (EFI)..."
    mkfs.fat -F32 -n "SYSTEM" "${TARGET_DISK}1" || error "Failed to format EFI"
    info "✓ EFI partition formatted"
    
    # Format Windows partition (NTFS)
    info "Formatting sdb3 as NTFS (Windows)..."
    mkfs.ntfs -f -L "Windows" "${TARGET_DISK}3" || error "Failed to format Windows"
    info "✓ Windows partition formatted"
    
    info "Partition info:"
    blkid | grep sdb
    echo ""
    
    # ============================================
    # STEP 7: Copy files from RAM to disk
    # ============================================
    log "Step 7: Copying Windows files from RAM to disk"
    
    mkdir -p /mnt/win
    mount "${TARGET_DISK}3" /mnt/win || error "Failed to mount Windows partition"
    
    info "Mounted sdb3 at /mnt/win"
    df -h /mnt/win
    
    info "Copying files (this takes 10-15 minutes)..."
    info "Source: $EXTRACT_DIR"
    info "Target: /mnt/win"
    echo ""
    
    rsync -ah --info=progress2 "$EXTRACT_DIR/" /mnt/win/ || error "File copy failed"
    
    sync
    info "✓ Files copied successfully"
    
    local copied_files=$(find /mnt/win -type f | wc -l)
    info "Files on Windows partition: $copied_files"
    
    # ============================================
    # STEP 8: Setup EFI bootloader
    # ============================================
    log "Step 8: Setting up EFI bootloader"
    
    mkdir -p /mnt/efi
    mount "${TARGET_DISK}1" /mnt/efi || error "Failed to mount EFI partition"
    
    mkdir -p /mnt/efi/EFI/Boot
    
    info "Searching for bootx64.efi..."
    
    # Try different paths (case-insensitive)
    local bootloader_found=false
    
    if [ -f "/mnt/win/efi/boot/bootx64.efi" ]; then
        cp /mnt/win/efi/boot/bootx64.efi /mnt/efi/EFI/Boot/
        bootloader_found=true
        info "✓ Found: /mnt/win/efi/boot/bootx64.efi"
    elif [ -f "/mnt/win/EFI/BOOT/BOOTX64.EFI" ]; then
        cp /mnt/win/EFI/BOOT/BOOTX64.EFI /mnt/efi/EFI/Boot/bootx64.efi
        bootloader_found=true
        info "✓ Found: /mnt/win/EFI/BOOT/BOOTX64.EFI"
    else
        warning "Standard paths not found, searching entire disk..."
        find /mnt/win -iname "bootx64.efi" -exec cp {} /mnt/efi/EFI/Boot/ \; 2>/dev/null && \
        bootloader_found=true
    fi
    
    if [ "$bootloader_found" = false ]; then
        error "Could not find bootx64.efi - installation may not boot"
    fi
    
    # Copy Microsoft boot directory
    if [ -d "/mnt/win/efi/microsoft" ]; then
        cp -r /mnt/win/efi/microsoft /mnt/efi/EFI/ 2>/dev/null || true
        info "✓ Copied Microsoft boot directory (lowercase)"
    elif [ -d "/mnt/win/EFI/Microsoft" ]; then
        cp -r /mnt/win/EFI/Microsoft /mnt/efi/EFI/ 2>/dev/null || true
        info "✓ Copied Microsoft boot directory (uppercase)"
    fi
    
    info "EFI partition contents:"
    ls -lhR /mnt/efi/EFI/
    echo ""
    
    # ============================================
    # STEP 9: Cleanup
    # ============================================
    log "Step 9: Cleanup and unmount"
    
    sync
    umount /mnt/win
    umount /mnt/efi
    
    info "✓ Partitions unmounted"
    
    # Clean RAM
    rm -rf "$RAM_DIR"
    info "✓ RAM workspace cleaned"
    
    info "Final RAM status:"
    df -h /dev/shm
    free -h
    echo ""
    
    # ============================================
    # STEP 10: Final verification
    # ============================================
    log "Step 10: Final verification"
    
    info "Final disk layout:"
    lsblk "$TARGET_DISK"
    echo ""
    
    info "Partition labels:"
    blkid | grep sdb
    echo ""
    
    # Mount and verify file count
    mount "${TARGET_DISK}3" /mnt/win
    local final_count=$(find /mnt/win -type f | wc -l)
    info "Total files on Windows partition: $final_count"
    
    if [ "$final_count" -lt 100 ]; then
        warning "File count seems low ($final_count files)"
    else
        info "✓ File count looks good"
    fi
    
    info "Sample files:"
    ls -lh /mnt/win/ | head -15
    echo ""
    
    umount /mnt/win
    
    # ============================================
    # SUCCESS!
    # ============================================
    banner "INSTALLATION COMPLETE!"
    
    echo ""
    log "Windows 10 installation media is ready on $TARGET_DISK"
    echo ""
    info "Partition layout:"
    info "  sdb1 (500M)  - EFI System Partition (FAT32)"
    info "  sdb2 (16M)   - Microsoft Reserved (MSR)"
    info "  sdb3 (74.5G) - Windows Installation (NTFS)"
    echo ""
    log "Next steps:"
    echo "  1. Go to OVHcloud control panel"
    echo "  2. Exit rescue mode (netboot)"
    echo "  3. Reboot the VPS"
    echo "  4. Windows 10 Setup should start automatically"
    echo ""
    warning "Important: Complete Windows setup quickly"
    warning "OVH may have time limits for Windows installation"
    echo ""
}

# Trap errors
trap 'error "Script failed at line $LINENO"' ERR

# Run
main