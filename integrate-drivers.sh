#!/bin/bash
# OVHcloud VPS Windows 10 - VirtIO Driver Entegrasyonu (Extract/Rebuild Method)
# Kullanım: bash integrate-drivers.sh

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
echo "  VirtIO Driver Entegrasyonu - boot.wim"
echo "  (Extract/Rebuild Method)"
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

# 3. Gerekli dosyaları kontrol et
log_info "Gerekli dosyalar kontrol ediliyor..."
cd /mnt || exit 1

if [ ! -f sources/boot.wim ]; then
    log_error "sources/boot.wim bulunamadı!"
    exit 1
fi

if [ ! -d Drivers/viostor/w10/amd64 ]; then
    log_error "Drivers/viostor/w10/amd64 bulunamadı!"
    exit 1
fi

log_success "Tüm gerekli dosyalar mevcut"

# 4. wimlib-imagex kontrolü
log_info "wimlib-imagex kontrolü..."
if ! command -v wimlib-imagex &>/dev/null; then
    log_error "wimlib-imagex yüklü değil!"
    exit 1
fi
log_success "wimlib-imagex mevcut"

# 5. boot.wim yedekle
log_info "boot.wim yedekleniyor..."
if [ ! -f sources/boot.wim.backup ]; then
    cp sources/boot.wim sources/boot.wim.backup
    log_success "Yedek oluşturuldu: sources/boot.wim.backup"
else
    log_warning "Yedek zaten mevcut, atlanıyor"
fi

# 6. Çalışma dizini temizle ve oluştur
log_info "Çalışma dizini hazırlanıyor..."
WORK_DIR="/tmp/wim_work"
if [ -d "$WORK_DIR" ]; then
    log_warning "$WORK_DIR zaten mevcut, temizleniyor..."
    rm -rf "$WORK_DIR"
fi
mkdir -p "$WORK_DIR"
log_success "Çalışma dizini hazır: $WORK_DIR"

# 7. boot.wim'i extract et (Index 2 = Windows Setup)
log_info "boot.wim extract ediliyor (bu 1-2 dakika sürebilir)..."
wimlib-imagex apply sources/boot.wim 2 "$WORK_DIR" || {
    log_error "boot.wim extract edilemedi!"
    exit 1
}
log_success "boot.wim extract edildi"

# 8. Driver dizini oluştur
log_info "Driver dizini oluşturuluyor..."
mkdir -p "$WORK_DIR/drivers"
log_success "Driver dizini hazır"

# 9. viostor driver kopyala
log_info "viostor (disk) driver'ı kopyalanıyor..."
cp -v Drivers/viostor/w10/amd64/* "$WORK_DIR/drivers/" || {
    log_error "viostor dosyaları kopyalanamadı!"
    exit 1
}
viostor_count=$(ls "$WORK_DIR/drivers/viostor"* 2>/dev/null | wc -l)
log_success "viostor driver kopyalandı (${viostor_count} dosya)"

# 10. NetKVM driver kopyala (opsiyonel)
if [ -d Drivers/NetKVM/w10/amd64 ]; then
    log_info "NetKVM (network) driver'ı kopyalanıyor..."
    cp -v Drivers/NetKVM/w10/amd64/* "$WORK_DIR/drivers/" 2>/dev/null || true
    netkvm_count=$(ls "$WORK_DIR/drivers/"*netkvm* "$WORK_DIR/drivers/"*NetKVM* 2>/dev/null | wc -l)
    if [ $netkvm_count -gt 0 ]; then
        log_success "NetKVM driver kopyalandı (${netkvm_count} dosya)"
    else
        log_warning "NetKVM dosyaları kopyalanamadı (opsiyonel)"
    fi
fi

# 11. Kopyalanan dosyaları listele
log_info "Kopyalanan driver dosyaları:"
ls -lh "$WORK_DIR/drivers/"

# 12. Yeni boot.wim oluştur
log_info "Yeni boot.wim oluşturuluyor (bu 2-3 dakika sürebilir)..."

# Önce eski Index 1'i kopyala (değişmeden)
wimlib-imagex export sources/boot.wim.backup 1 sources/boot.wim.new "Microsoft Windows PE (x64)" || {
    log_error "Index 1 export edilemedi!"
    exit 1
}

# Sonra yeni Index 2'yi ekle (driver'lı)
wimlib-imagex capture "$WORK_DIR" sources/boot.wim.new "Microsoft Windows Setup (x64)" \
    --compress=LZX --chunk-size=32768 --boot || {
    log_error "Index 2 capture edilemedi!"
    exit 1
}

log_success "Yeni boot.wim oluşturuldu"

# 13. Eski boot.wim'i değiştir
log_info "boot.wim değiştiriliyor..."
mv sources/boot.wim sources/boot.wim.old
mv sources/boot.wim.new sources/boot.wim
log_success "boot.wim başarıyla değiştirildi"

# 14. Temizlik
log_info "Geçici dizin temizleniyor..."
rm -rf "$WORK_DIR"
rm -f sources/boot.wim.old
log_success "Temizlik tamamlandı"

# 15. boot.wim boyutu kontrol
new_size=$(stat -c%s sources/boot.wim 2>/dev/null)
new_mb=$((new_size / 1024 / 1024))
log_success "boot.wim boyutu: ${new_mb}MB"

# 16. Özet
echo ""
echo "================================================"
log_success "DRIVER ENTEGRASYONU TAMAMLANDI!"
echo "================================================"
echo ""
echo "Entegre edilen driver'lar:"
echo "  ✓ VirtIO viostor (disk controller)"
[ "${netkvm_count:-0}" -gt 0 ] && echo "  ✓ VirtIO NetKVM (network)"
echo ""
echo "boot.wim güncellendi: ${new_mb}MB"
echo "Yedek mevcut: sources/boot.wim.backup"
echo ""
echo "Sonraki adım: GRUB kurulumu"
echo "  bash install-grub.sh"
echo ""