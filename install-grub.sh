#!/bin/bash
# OVHcloud VPS Windows 10 - GRUB Kurulumu
# Kullanım: bash install-grub.sh

set -e

# Renkler
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

echo "================================================"
echo "  GRUB Kurulumu - Windows Boot Manager"
echo "================================================"
echo ""

# 1. Root kontrolü
log_info "Root yetkisi kontrolü..."
if [ "$EUID" -ne 0 ]; then 
    log_error "Bu script root olarak çalıştırılmalı!"
    exit 1
fi
log_success "Root yetkisi OK"

# 2. /mnt mount kontrolü
log_info "Mount durumu kontrol ediliyor..."
if ! mountpoint -q /mnt; then
    log_error "/mnt mount edilmemiş!"
    exit 1
fi
log_success "/mnt mount edilmiş"

# 3. bootmgr kontrolü
log_info "Windows Boot Manager kontrolü..."
cd /mnt || exit 1

if [ ! -f bootmgr ]; then
    log_error "bootmgr bulunamadı!"
    exit 1
fi
log_success "bootmgr mevcut"

# 4. grub-install kontrolü
log_info "grub-install kontrolü..."
if ! command -v grub-install &>/dev/null; then
    log_error "grub-install yüklü değil!"
    echo "  apt install -y grub-pc-bin"
    exit 1
fi
log_success "grub-install mevcut"

# 5. GRUB klasörünü temizle
log_info "GRUB klasörü hazırlanıyor..."
if [ -d /mnt/grub ]; then
    log_warning "GRUB klasörü zaten mevcut, temizleniyor..."
    rm -rf /mnt/grub
fi
log_success "GRUB klasörü hazır"

# 6. GRUB'ı kur
log_info "GRUB /dev/sdb'ye kuruluyor..."
grub-install --target=i386-pc --boot-directory=/mnt --force /dev/sdb || {
    log_error "GRUB kurulumu başarısız!"
    exit 1
}
log_success "GRUB kuruldu"

# 7. GRUB config oluştur
log_info "GRUB yapılandırma dosyası oluşturuluyor..."
cat > /mnt/grub/grub.cfg << 'EOF'
ntldr /bootmgr
boot
EOF

log_success "grub.cfg oluşturuldu"

# 8. Config'i göster
log_info "GRUB yapılandırması:"
cat /mnt/grub/grub.cfg

# 9. GRUB dosyalarını kontrol et
log_info "GRUB dosyaları kontrol ediliyor..."
if [ ! -d /mnt/grub ]; then
    log_error "GRUB klasörü oluşturulamadı!"
    exit 1
fi

if [ ! -f /mnt/grub/grub.cfg ]; then
    log_error "grub.cfg oluşturulamadı!"
    exit 1
fi

log_success "Tüm GRUB dosyaları mevcut"

# 10. Özet
echo ""
echo "================================================"
log_success "GRUB KURULUMU TAMAMLANDI!"
echo "================================================"
echo ""
echo "Kurulum özeti:"
echo "  ✓ GRUB /dev/sdb'ye kuruldu"
echo "  ✓ Windows Boot Manager yapılandırıldı"
echo "  ✓ grub.cfg oluşturuldu"
echo ""
echo "SON ADIMLAR:"
echo "  1. cd / && umount /mnt"
echo "  2. OVH panelinden VPS'i reboot edin"
echo "  3. KVM konsolunu açın"
echo "  4. Windows Setup göründüğünde SHIFT+F10"
echo "  5. Şu komutları çalıştırın:"
echo ""
echo "     diskpart"
echo "     select disk 0"
echo "     select partition 1"
echo "     active"
echo "     exit"
echo "     exit"
echo ""
echo "  6. Windows kurulumuna devam edin"
echo ""
log_warning "Reboot öncesi mutlaka /mnt'i unmount edin!"
echo ""