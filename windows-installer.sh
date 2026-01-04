#!/bin/bash

# Windows 10 ISO Installer - v3 (Smart Partitioning Strategy)
# Strategy: Create temporary sdb4, download/extract ISO, then wipe all and rebuild

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
warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
debug() { echo -e "${BLUE}[DEBUG]${NC} $1"; }
step() { echo -e "\n${YELLOW}=== $1 ===${NC}\n"; }

check_root() {
    [ "$EUID" -ne 0 ] && error "Must run as root"
    debug "✓ Running as root"
}

show_current_state() {
    log "Current disk state:"
    lsblk $TARGET_DISK
    echo ""
}

install_tools() {
    step "STEP 1: Installing Required Tools"
    
    local tools_needed=0
    for tool in parted mkfs.ntfs mkfs.fat wget p7zip rsync; do
        if ! command -v $tool &>/dev/null; then
            tools_needed=1
            break
        fi
    done
    
    if [ $tools_needed -eq 1 ]; then
        log "Installing packages..."
        apt-get update -qq
        apt-get install -y wget p7zip-full parted ntfs-3g dosfstools gdisk rsync util-linux -qq || error "Failed to install"
    fi
    debug "✓ All tools available"
}

create_temp_partition() {
    step "STEP 2: Creating Temporary Partition (sdb4 - 10GB)"
    
    # Unmount any mounted sdb partitions
    log "Unmounting existing partitions..."
    umount ${TARGET_DISK}* 2>/dev/null || true
    
    # Check if sdb4 already exists
    if [ -b "${TARGET_DISK}4" ]; then
        log "sdb4 already exists, skipping creation"
    else
        log "Creating sdb4 (10GB for temporary storage)..."
        # Shrink sdb3 and create sdb4
        parted -s $TARGET_DISK resizepart 3 64.5GiB || warning "Resize may have failed"
        parted -s $TARGET_DISK mkpart primary ext4 64.5GiB 74.5GiB || error "Failed to create sdb4"
        
        sleep 2
        partprobe $TARGET_DISK
        sleep 2
    fi
    
    # Format sdb4 if not formatted
    if ! blkid "${TARGET_DISK}4" | grep -q TYPE; then
        log "Formatting sdb4 as ext4..."
        mkfs.ext4 -F "${TARGET_DISK}4" || error "Failed to format sdb4"
    fi
    
    # Mount sdb4
    mkdir -p /mnt/temp
    mount "${TARGET_DISK}4" /mnt/temp || error "Failed to mount sdb4"
    
    debug "✓ Temporary partition ready"
    df -h /mnt/temp
}

download_and_extract_iso() {
    step "STEP 3: Downloading and Extracting Windows ISO"
    
    local iso_file="/mnt/temp/windows10.iso"
    local extract_dir="/mnt/temp/windows_files"
    
    mkdir -p "$extract_dir"
    
    # Download ISO
    if [ -f "$iso_file" ]; then
        local size=$(stat -c%s "$iso_file")
        if [ $size -gt 5000000000 ]; then
            log "ISO already downloaded ($(($size/1024/1024))MB), skipping..."
        else
            warning "Incomplete ISO found, re-downloading..."
            rm -f "$iso_file"
        fi
    fi
    
    if [ ! -f "$iso_file" ]; then
        log "Downloading Windows 10 ISO (~5.7GB)..."
        log "This will take 5-15 minutes depending on connection..."
        wget --progress=bar:force --tries=3 --continue -O "$iso_file" "$ISO_URL" || error "Download failed"
        debug "✓ ISO downloaded successfully"
    fi
    
    # Extract ISO
    if [ -d "$extract_dir/sources" ]; then
        log "ISO already extracted, skipping..."
    else
        log "Extracting ISO (this takes 10-15 minutes)..."
        log "Please be patient..."
        
        7z x "$iso_file" -o"$extract_dir" -y > /tmp/extract.log 2>&1 || {
            tail -20 /tmp/extract.log
            error "Extraction failed - check /tmp/extract.log"
        }
        
        debug "✓ ISO extracted successfully"
    fi
    
    local file_count=$(find "$extract_dir" -type f | wc -l)
    log "Extracted files: $file_count"
    
    # Verify critical files exist
    if [ ! -d "$extract_dir/sources" ]; then
        error "Critical directory 'sources' not found in extracted files"
    fi
    
    debug "✓ Extraction verified"
}

wipe_and_partition() {
    step "STEP 4: Wiping Disk and Creating New Partitions"
    
    warning "This will PERMANENTLY ERASE all data on $TARGET_DISK"
    warning "Current partitions: sdb1(500M), sdb2(16M), sdb3(74.5G), sdb4(10G)"
    warning "New layout: sdb1(EFI 500M), sdb2(MSR 16M), sdb3(Windows 74.5G)"
    echo ""
    
    read -p "Type 'YES' to continue with disk wipe: " confirm
    if [ "$confirm" != "YES" ]; then
        error "Operation cancelled by user"
    fi
    
    log "Unmounting all partitions..."
    umount ${TARGET_DISK}* 2>/dev/null || true
    sync
    sleep 2
    
    log "Wiping partition table..."
    wipefs -a $TARGET_DISK || error "Failed to wipe disk"
    
    log "Creating fresh GPT partition table..."
    parted -s $TARGET_DISK mklabel gpt || error "Failed to create GPT"
    
    log "Creating EFI System Partition (500MB)..."
    parted -s $TARGET_DISK mkpart primary fat32 1MiB 501MiB || error "Failed to create EFI"
    parted -s $TARGET_DISK set 1 esp on || error "Failed to set ESP flag"
    
    log "Creating MSR partition (16MB)..."
    parted -s $TARGET_DISK mkpart primary 501MiB 517MiB || error "Failed to create MSR"
    parted -s $TARGET_DISK set 2 msftres on || error "Failed to set MSR flag"
    
    log "Creating Windows partition (remaining ~74GB)..."
    parted -s $TARGET_DISK mkpart primary ntfs 517MiB 100% || error "Failed to create Windows partition"
    
    sleep 3
    partprobe $TARGET_DISK
    sleep 3
    
    debug "✓ Partitions created"
    lsblk $TARGET_DISK
}

format_partitions() {
    step "STEP 5: Formatting Partitions"
    
    log "Formatting EFI partition (FAT32)..."
    mkfs.fat -F32 -n "SYSTEM" "${TARGET_DISK}1" || error "Failed to format EFI"
    debug "✓ EFI partition formatted"
    
    log "Formatting Windows partition (NTFS)..."
    mkfs.ntfs -f -L "Windows" "${TARGET_DISK}3" || error "Failed to format Windows"
    debug "✓ Windows partition formatted"
    
    # MSR partition should not be formatted
    debug "✓ MSR partition (unformatted, as intended)"
    
    log "Partition details:"
    blkid | grep sdb || true
}

copy_windows_files() {
    step "STEP 6: Copying Windows Installation Files"
    
    local extract_dir="/mnt/temp/windows_files"
    local win_mount="/mnt/windows"
    local efi_mount="/mnt/efi"
    
    mkdir -p "$win_mount" "$efi_mount"
    
    # Mount Windows partition
    log "Mounting Windows partition..."
    mount "${TARGET_DISK}3" "$win_mount" || error "Failed to mount Windows partition"
    debug "✓ Mounted ${TARGET_DISK}3 to $win_mount"
    
    # Copy files
    log "Copying Windows files (this takes 5-10 minutes)..."
    log "Progress will be shown below:"
    rsync -ah --info=progress2 "$extract_dir/" "$win_mount/" || error "Failed to copy files"
    
    sync
    debug "✓ Files copied to Windows partition"
    
    local copied_files=$(find "$win_mount" -type f | wc -l)
    log "Total files on Windows partition: $copied_files"
}

setup_efi_boot() {
    step "STEP 7: Setting Up EFI Bootloader"
    
    local win_mount="/mnt/windows"
    local efi_mount="/mnt/efi"
    
    log "Mounting EFI partition..."
    mount "${TARGET_DISK}1" "$efi_mount" || error "Failed to mount EFI partition"
    debug "✓ Mounted ${TARGET_DISK}1 to $efi_mount"
    
    mkdir -p "$efi_mount/EFI/Boot"
    mkdir -p "$efi_mount/EFI/Microsoft"
    
    log "Searching for Windows bootloader..."
    
    # Try multiple possible locations
    local bootloader_found=0
    
    if [ -f "$win_mount/efi/boot/bootx64.efi" ]; then
        cp "$win_mount/efi/boot/bootx64.efi" "$efi_mount/EFI/Boot/"
        bootloader_found=1
        debug "✓ Found bootx64.efi (lowercase path)"
    elif [ -f "$win_mount/EFI/BOOT/BOOTX64.EFI" ]; then
        cp "$win_mount/EFI/BOOT/BOOTX64.EFI" "$efi_mount/EFI/Boot/bootx64.efi"
        bootloader_found=1
        debug "✓ Found BOOTX64.EFI (uppercase path)"
    else
        log "Searching entire partition for bootloader..."
        find "$win_mount" -iname "bootx64.efi" | while read bootfile; do
            cp "$bootfile" "$efi_mount/EFI/Boot/bootx64.efi"
            bootloader_found=1
            debug "✓ Found at: $bootfile"
            break
        done
    fi
    
    if [ $bootloader_found -eq 0 ]; then
        warning "bootx64.efi not found - Windows may create it during installation"
    fi
    
    # Copy Microsoft boot directory if exists
    if [ -d "$win_mount/efi/microsoft" ]; then
        cp -r "$win_mount/efi/microsoft" "$efi_mount/EFI/" 2>/dev/null || true
        debug "✓ Copied Microsoft boot directory (lowercase)"
    elif [ -d "$win_mount/EFI/Microsoft" ]; then
        cp -r "$win_mount/EFI/Microsoft" "$efi_mount/EFI/" 2>/dev/null || true
        debug "✓ Copied Microsoft boot directory (uppercase)"
    fi
    
    log "EFI partition contents:"
    ls -lhR "$efi_mount/EFI/" || true
}

cleanup_and_verify() {
    step "STEP 8: Cleanup and Verification"
    
    log "Syncing filesystems..."
    sync
    
    log "Unmounting partitions..."
    umount /mnt/windows 2>/dev/null || true
    umount /mnt/efi 2>/dev/null || true
    umount /mnt/temp 2>/dev/null || true
    
    debug "✓ All partitions unmounted"
    
    log "Final disk layout:"
    lsblk $TARGET_DISK
    echo ""
    
    log "Partition labels and UUIDs:"
    blkid | grep sdb
    echo ""
    
    # Verify partitions exist
    if [ ! -b "${TARGET_DISK}1" ] || [ ! -b "${TARGET_DISK}3" ]; then
        error "Partitions missing after creation!"
    fi
    
    debug "✓ Verification complete"
}

main() {
    clear
    echo -e "${GREEN}"
    echo "╔═══════════════════════════════════════════════╗"
    echo "║  Windows 10 Installation Media Creator v3    ║"
    echo "║  Smart Partitioning Strategy                  ║"
    echo "╚═══════════════════════════════════════════════╝"
    echo -e "${NC}\n"
    
    check_root
    show_current_state
    
    log "This script will:"
    echo "  1. Create temporary partition (sdb4) for ISO"
    echo "  2. Download Windows 10 ISO (~5.7GB)"
    echo "  3. Extract ISO files"
    echo "  4. Wipe entire disk and create new layout"
    echo "  5. Copy files to new Windows partition"
    echo "  6. Setup EFI bootloader"
    echo ""
    
    read -p "Press ENTER to start or CTRL+C to cancel..."
    
    install_tools
    create_temp_partition
    download_and_extract_iso
    wipe_and_partition
    format_partitions
    copy_windows_files
    setup_efi_boot
    cleanup_and_verify
    
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════╗"
    echo "║            INSTALLATION COMPLETE!             ║"
    echo "╚═══════════════════════════════════════════════╝${NC}"
    echo ""
    log "Next steps:"
    echo "  1. Go to OVHcloud control panel"
    echo "  2. Exit rescue mode (netboot mode)"
    echo "  3. Reboot the server"
    echo "  4. Windows 10 installer should start automatically"
    echo ""
    log "Disk $TARGET_DISK is now bootable with Windows 10 installer"
    echo ""
}

main "$@"