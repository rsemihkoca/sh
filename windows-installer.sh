#!/bin/bash

# Windows 10 ISO Installer for OVHcloud VPS
# This script downloads Windows 10 ISO and creates a bootable installation

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
ISO_URL="https://software.download.prss.microsoft.com/dbazure/Win10_22H2_English_x64v1.iso?t=781f2471-b77c-4638-b68b-7f0e243fa0f7&P1=1767636764&P2=601&P3=2&P4=xvhom209oOzLuLZR2xxcAhCA3NtLdn5QySZ0a051geiXPtw01Ld7HqdQgV8KqKCpKSRq5GcRmLWXzZj4S0F5X5aoIr0UVf6WXljjaGjMT09EUcINyjquY6KOmJ3%2bhxWaiROuToGno9YfxJDvLteh4h%2bo0BIrcgjJ8sbCme9B5n3VnWSOT1gHe%2fAFwLCAxp7qbn7%2fyjwFCS85tWEIzKtnUOUH8L13Y8Eq55P5kn3WfGaEGbto0P35%2b54mRGJnFP9GStR5qFKI5wLYFfVKvKoM5gT4%2fsICaBrqn4kLPX0mPfzJG3W0ALMvtFXGpZjqpNkgzZLtTdHwM2jgO9yuXicxTQ%3d%3d"
WORK_DIR="/mnt/workspace"
TARGET_DISK="/dev/sdb"
ISO_FILE="$WORK_DIR/windows10.iso"
MOUNT_ISO="$WORK_DIR/iso_mount"
MOUNT_BOOT="$WORK_DIR/boot_mount"

# Logging function
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

debug() {
    echo -e "${YELLOW}[DEBUG]${NC} $1"
}

# Step 1: Validation
validate_environment() {
    log "=== Step 1: Environment Validation ==="
    
    # Check if running as root
    if [ "$EUID" -ne 0 ]; then 
        error "This script must be run as root"
    fi
    debug "✓ Running as root"
    
    # Check if target disk exists
    if [ ! -b "$TARGET_DISK" ]; then
        error "Target disk $TARGET_DISK not found"
    fi
    debug "✓ Target disk $TARGET_DISK exists"
    
    # Display disk information
    log "Current disk layout:"
    lsblk
    
    # Check available space on sdb
    local available_space=$(df -BG /dev/sdb2 2>/dev/null | awk 'NR==2 {print $4}' | sed 's/G//' || echo "0")
    debug "Available space on sdb2: ${available_space}G"
    
    # Create workspace on sdb3 (has write permissions)
    log "Preparing workspace on /dev/sdb3..."
    
    # Create mount point
    mkdir -p /mnt/sdb3
    
    # Check if sdb3 is already mounted
    if mountpoint -q /mnt/sdb3; then
        log "/dev/sdb3 already mounted"
    else
        log "Mounting /dev/sdb3..."
        mount /dev/sdb3 /mnt/sdb3 || error "Failed to mount /dev/sdb3"
    fi
    
    # Set workspace to sdb3
    WORK_DIR="/mnt/sdb3/workspace"
    ISO_FILE="$WORK_DIR/windows10.iso"
    MOUNT_ISO="$WORK_DIR/iso_mount"
    MOUNT_BOOT="$WORK_DIR/boot_mount"
    
    mkdir -p "$WORK_DIR"
    debug "✓ Workspace created: $WORK_DIR"
    
    # Update required tools check
    log "Checking required tools..."
    local missing_tools=()
    
    for tool in wget parted mkfs.ntfs mkfs.fat wipefs sgdisk; do
        if ! command -v $tool &> /dev/null; then
            missing_tools+=($tool)
        fi
    done
    
    if [ ${#missing_tools[@]} -gt 0 ]; then
        warning "Missing tools: ${missing_tools[*]}"
        log "Installing required packages..."
        apt-get update -qq
        apt-get install -y wget parted ntfs-3g dosfstools gdisk util-linux || error "Failed to install packages"
    fi
    debug "✓ All required tools available"
    
    # Check if we have enough space for ISO download
    local free_space=$(df -BM "$WORK_DIR" | awk 'NR==2 {print $4}' | sed 's/M//')
    debug "Available space in workspace: ${free_space}MB"
    
    if [ "$free_space" -lt 6000 ]; then
        error "Not enough space in $WORK_DIR. Need at least 6GB, have ${free_space}MB"
    fi
    debug "✓ Sufficient disk space: ${free_space}MB available"
    
    log "Environment validation completed successfully"
    echo ""
}

# Step 2: Download Windows 10 ISO
download_iso() {
    log "=== Step 2: Downloading Windows 10 ISO ==="
    
    if [ -f "$ISO_FILE" ]; then
        warning "ISO file already exists at $ISO_FILE"
        local file_size=$(stat -f%z "$ISO_FILE" 2>/dev/null || stat -c%s "$ISO_FILE" 2>/dev/null)
        debug "Existing file size: $((file_size / 1024 / 1024))MB"
        
        read -p "Do you want to re-download? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log "Using existing ISO file"
            return 0
        fi
        rm -f "$ISO_FILE"
    fi
    
    log "Starting download... This may take a while."
    log "Download location: $ISO_FILE"
    
    wget --progress=bar:force \
         --tries=3 \
         --continue \
         -O "$ISO_FILE" \
         "$ISO_URL" || error "Failed to download ISO"
    
    # Verify download
    local file_size=$(stat -c%s "$ISO_FILE")
    local file_size_mb=$((file_size / 1024 / 1024))
    debug "Downloaded file size: ${file_size_mb}MB"
    
    if [ "$file_size" -lt 4000000000 ]; then
        error "Downloaded file seems too small (${file_size_mb}MB). Expected ~5GB"
    fi
    
    log "ISO downloaded successfully: ${file_size_mb}MB"
    
    # Calculate MD5 for verification
    log "Calculating MD5 checksum (this may take a minute)..."
    local md5sum=$(md5sum "$ISO_FILE" | awk '{print $1}')
    debug "MD5: $md5sum"
    
    echo ""
}

# Step 3: Partition the disk
partition_disk() {
    log "=== Step 3: Partitioning Disk ==="
    
    warning "This will ERASE all data on $TARGET_DISK"
    debug "Current partition layout:"
    fdisk -l "$TARGET_DISK"
    
    read -p "Continue? (yes/NO): " confirm
    if [ "$confirm" != "yes" ]; then
        error "Aborted by user"
    fi
    
    log "Unmounting any mounted partitions..."
    umount ${TARGET_DISK}* 2>/dev/null || true
    
    log "Wiping existing partition table..."
    wipefs -a "$TARGET_DISK" || error "Failed to wipe disk"
    
    log "Creating GPT partition table..."
    parted -s "$TARGET_DISK" mklabel gpt || error "Failed to create GPT table"
    
    log "Creating EFI partition (500MB)..."
    parted -s "$TARGET_DISK" mkpart primary fat32 1MiB 501MiB || error "Failed to create EFI partition"
    parted -s "$TARGET_DISK" set 1 esp on || error "Failed to set ESP flag"
    
    log "Creating MSR partition (16MB)..."
    parted -s "$TARGET_DISK" mkpart primary 501MiB 517MiB || error "Failed to create MSR partition"
    parted -s "$TARGET_DISK" set 2 msftres on || error "Failed to set MSR flag"
    
    log "Creating Windows partition (remaining space)..."
    parted -s "$TARGET_DISK" mkpart primary ntfs 517MiB 100% || error "Failed to create Windows partition"
    
    # Wait for kernel to recognize partitions
    sleep 3
    partprobe "$TARGET_DISK"
    sleep 2
    
    log "New partition layout:"
    fdisk -l "$TARGET_DISK"
    lsblk "$TARGET_DISK"
    
    echo ""
}

# Step 4: Format partitions
format_partitions() {
    log "=== Step 4: Formatting Partitions ==="
    
    local efi_part="${TARGET_DISK}1"
    local windows_part="${TARGET_DISK}3"
    
    log "Formatting EFI partition as FAT32..."
    mkfs.fat -F32 -n "SYSTEM" "$efi_part" || error "Failed to format EFI partition"
    debug "✓ EFI partition formatted"
    
    log "Formatting Windows partition as NTFS..."
    mkfs.ntfs -f -L "Windows" "$windows_part" || error "Failed to format Windows partition"
    debug "✓ Windows partition formatted"
    
    log "Partition formatting completed"
    blkid | grep sdb
    
    echo ""
}

# Step 5: Mount ISO and copy files
install_windows() {
    log "=== Step 5: Installing Windows Files ==="
    
    local efi_part="${TARGET_DISK}1"
    local windows_part="${TARGET_DISK}3"
    
    # Create mount points
    mkdir -p "$MOUNT_ISO"
    mkdir -p "$MOUNT_BOOT"
    
    log "Mounting Windows ISO..."
    mount -o loop "$ISO_FILE" "$MOUNT_ISO" || error "Failed to mount ISO"
    debug "✓ ISO mounted at $MOUNT_ISO"
    
    log "Mounting Windows partition..."
    mount "$windows_part" "$MOUNT_BOOT" || error "Failed to mount Windows partition"
    debug "✓ Windows partition mounted at $MOUNT_BOOT"
    
    log "Copying Windows installation files..."
    log "This will take several minutes..."
    
    # Copy all files from ISO to Windows partition
    rsync -avh --progress "$MOUNT_ISO/" "$MOUNT_BOOT/" || error "Failed to copy files"
    
    debug "✓ Files copied successfully"
    
    log "Setting up EFI bootloader..."
    mkdir -p /mnt/efi
    mount "$efi_part" /mnt/efi || error "Failed to mount EFI partition"
    
    # Copy EFI bootloader
    mkdir -p /mnt/efi/EFI/Boot
    cp "$MOUNT_ISO/efi/boot/bootx64.efi" /mnt/efi/EFI/Boot/ 2>/dev/null || \
    cp "$MOUNT_BOOT/efi/boot/bootx64.efi" /mnt/efi/EFI/Boot/ || \
    warning "Could not copy bootx64.efi - Windows installer may handle this"
    
    debug "Boot files:"
    ls -lh /mnt/efi/EFI/Boot/ 2>/dev/null || echo "No boot files yet"
    
    log "Cleaning up..."
    umount "$MOUNT_ISO"
    umount "$MOUNT_BOOT"
    umount /mnt/efi
    
    log "Windows installation files ready"
    echo ""
}

# Step 6: Final verification
verify_installation() {
    log "=== Step 6: Verification ==="
    
    log "Partition layout:"
    lsblk "$TARGET_DISK"
    echo ""
    
    log "Partition details:"
    fdisk -l "$TARGET_DISK"
    echo ""
    
    log "Filesystem labels:"
    blkid | grep sdb
    echo ""
    
    # Mount and check file count
    mkdir -p /tmp/verify_mount
    mount "${TARGET_DISK}3" /tmp/verify_mount
    local file_count=$(find /tmp/verify_mount -type f | wc -l)
    debug "Total files on Windows partition: $file_count"
    
    if [ "$file_count" -lt 100 ]; then
        warning "File count seems low. Installation may be incomplete."
    fi
    
    debug "Sample files:"
    ls -lh /tmp/verify_mount/ | head -20
    
    umount /tmp/verify_mount
    
    log "✓ Installation verification completed"
    echo ""
}

# Main execution
main() {
    log "========================================="
    log "Windows 10 Installation Media Creator"
    log "========================================="
    echo ""
    
    validate_environment
    download_iso
    partition_disk
    format_partitions
    install_windows
    verify_installation
    
    log "========================================="
    log "SUCCESS! Installation media is ready"
    log "========================================="
    echo ""
    log "Next steps:"
    log "1. Exit rescue mode in OVHcloud panel"
    log "2. Reboot the server"
    log "3. Server should boot into Windows 10 installer"
    log "4. Follow Windows installation wizard"
    echo ""
    log "Disk: $TARGET_DISK is now bootable with Windows 10"
}

# Run main function
main