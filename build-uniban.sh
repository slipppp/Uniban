#!/bin/bash
# UniBan Builder v0.1
# Roda 1 comando -> sai ISO pronta.
set -e

echo "=== UniBan Builder v0.2 ==="

# 1. Ferramentas de build
sudo apt update
sudo apt install -y live-build live-config live-boot debootstrap \
    xorriso syslinux-common isolinux squashfs-tools curl

# 2. Entra no projeto (assume que este script está na raiz uniban/)
cd "$(dirname "$0")"

# 3a. Desmonta sobra de build anterior que travou.
#     BUG REAL (build.log): "lb bootstrap_cache save" -> cp varrendo
#     chroot/sys/... "Permissão negada" -> "E: An unexpected failure occurred".
#     chroot/sys (ou /proc, /dev) ainda montado = cp copia o /sys DO PC
#     inteiro e morre. Também faz o lb clean tentar apagar o /sys de verdade.
unmount_chroot() {
  for m in $(awk -v d="$PWD/chroot" 'index($2, d) == 1 {print $2}' /proc/mounts | sort -r); do
    sudo umount -l "$m" 2>/dev/null || true
  done
}
trap unmount_chroot EXIT   # também limpa se ESTE build falhar
unmount_chroot
if awk -v d="$PWD/chroot" 'index($2, d) == 1 {f=1} END {exit !f}' /proc/mounts; then
  echo "ERRO: ainda tem mount dentro de chroot/ (veja: grep chroot /proc/mounts)."
  echo "Reinicie o PC e rode de novo."; exit 1
fi

# 3b. Limpa build anterior (precisa vir ANTES do lb config,
#    senão lb clean apaga marcador de stage "config" e lb build quebra)
sudo lb clean
sudo rm -rf chroot cache

# 4. Config live-build
lb config \
  --distribution trixie \
  --architecture amd64 \
  --binary-images iso-hybrid \
  --archive-areas "main contrib non-free non-free-firmware" \
  --iso-application "UniBan" \
  --iso-volume "UNIBAN_035" \
  --bootappend-live "boot=live components quiet splash" \
  --cache false \
  --cache-stages false

# 5. Build
sudo lb build 2>&1 | tee build.log

echo "=== PRONTO. ISO em $(pwd)/live-image-amd64.hybrid.iso ==="
