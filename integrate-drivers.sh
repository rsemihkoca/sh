#!/bin/bash
# OVHcloud VPS Windows 10 - VirtIO Driver Entegrasyonu
# Kullanım: bash integrate-drivers.sh

set -e

# Renkler
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

echo "================================================"
echo "  VirtIO Driver Entegrasyonu - boot.wim"
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
    log_error "/mnt mount edilmemiş! Önce mount edin:"
    echo "  mount /dev/sdb3 /mnt"
    exit 1
fi
log_success "/mnt mount edilmiş"

# 3. Gerekli dosyaları kontrol et
log_info "Gerekli dosyalar kontrol ediliyor..."
cd /mnt

if [ ! -f sources/boot.wim ]; then
    log_error "boot.wim bulunamadı!"
    exit 1
fi

if [ ! -d Drivers/viostor/w10/amd64 ]; then
    log_error "VirtIO viostor driver'ı bulunamadı!"
    exit 1
fi

if [ ! -d Drivers/NetKVM/w10/amd64 ]; then
    log_error "VirtIO NetKVM driver'ı bulunamadı!"
    exit 1
fi
log_success "Tüm gerekli dosyalar mevcut"

# 4. wimlib-imagex kontrolü
log_info "wimlib-imagex kontrolü..."
if ! which wimlib-imagex > /dev/null 2>&1; then
    log_error "wimlib-imagex bulunamadı!"
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

# 6. boot.wim bilgilerini al
log_info "boot.wim içeriği kontrol ediliyor..."
wimlib-imagex info sources/boot.wim

# 7. Mount dizini oluştur
log_info "Mount dizini hazırlanıyor..."
if [ -d /tmp/boot ]; then
    log_warning "/tmp/boot zaten mevcut, temizleniyor..."
    wimlib-imagex unmount /tmp/boot 2>/dev/null || true
    rm -rf /tmp/boot
fi
mkdir -p /tmp/boot
log_success "Mount dizini hazır: /tmp/boot"

# 8. boot.wim'i mount et (index 2 = Windows Setup)
log_info "boot.wim mount ediliyor (bu 1-2 dakika sürebilir)..."
wimlib-imagex mount sources/boot.wim 2 /tmp/boot || {
    log_error "boot.wim mount edilemedi!"
    exit 1
}
log_success "boot.wim mount edildi"

# 9. Driver dizini oluştur
log_info "Driver dizini oluşturuluyor..."
mkdir -p /tmp/boot/drivers
log_success "Driver dizini hazır"

# 10. viostor (disk) driver'ını kopyala
log_info "viostor (disk) driver'ı kopyalanıyor..."
cp -v Drivers/viostor/w10/amd64/*.sys /tmp/boot/drivers/ 2>/dev/null || true
cp -v Drivers/viostor/w10/amd64/*.inf /tmp/boot/drivers/ 2>/dev/null || true
cp -v Drivers/viostor/w10/amd64/*.cat /tmp/boot/drivers/ 2>/dev/null || true
viostor_count=$(ls /tmp/boot/drivers/viostor* 2>/dev/null | wc -l)
if [ $viostor_count -eq 0 ]; then
    log_error "viostor dosyaları kopyalanamadı!"
    wimlib-imagex unmount /tmp/boot
    exit 1
fi
log_success "viostor driver kopyalandı (${viostor_count} dosya)"

# 11. NetKVM (network) driver'ını kopyala
log_info "NetKVM (network) driver'ı kopyalanıyor..."
cp -v Drivers/NetKVM/w10/amd64/*.sys /tmp/boot/drivers/ 2>/dev/null || true
cp -v Drivers/NetKVM/w10/amd64/*.inf /tmp/boot/drivers/ 2>/dev/null || true
cp -v Drivers/NetKVM/w10/amd64/*.cat /tmp/boot/drivers/ 2>/dev/null || true
netkvm_count=$(ls /tmp/boot/drivers/*netkvm* 2>/dev/null | wc -l)
if [ $netkvm_count -eq 0 ]; then
    log_warning "NetKVM dosyaları kopyalanamadı (opsiyonel)"
else
    log_success "NetKVM driver kopyalandı (${netkvm_count} dosya)"
fi

# 12. Kopyalanan dosyaları listele
log_info "Kopyalanan driver dosyaları:"
ls -lh /tmp/boot/drivers/

# 13. boot.wim'i unmount ve değişiklikleri kaydet
log_info "boot.wim kaydediliyor (bu 2-3 dakika sürebilir)..."
wimlib-imagex unmount /tmp/boot --commit || {
    log_error "boot.wim unmount/commit başarısız!"
    log_warning "Değişiklikler kaydedilmedi!"
    exit 1
}
log_success "boot.wim başarıyla kaydedildi"

# 14. Mount dizinini temizle
log_info "Geçici dizin temizleniyor..."
rm -rf /tmp/boot
log_success "Temizlik tamamlandı"

# 15. boot.wim boyutunu kontrol et
log_info "Yeni boot.wim boyutu kontrol ediliyor..."
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
echo "  ✓ VirtIO NetKVM (network)"
echo ""
echo "boot.wim güncellendi: ${new_mb}MB"
echo "Yedek mevcut: sources/boot.wim.backup"
echo ""
echo "Sonraki adım: GRUB kurulumu"
echo "  bash install-grub.sh"
echo ""