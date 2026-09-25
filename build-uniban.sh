#!/bin/bash
# UniBan Builder v0.1
# Roda 1 comando -> sai ISO pronta.
set -e

echo "=== UniBan Builder v0.1 ==="

# 1. Ferramentas de build
sudo apt update
sudo apt install -y live-build live-config live-boot debootstrap \
    xorriso syslinux-common isolinux squashfs-tools curl

# 2. Entra no projeto (assume que este script está na raiz uniban/)
cd "$(dirname "$0")"

# 3. Limpa build anterior (precisa vir ANTES do lb config,
#    senão lb clean apaga marcador de stage "config" e lb build quebra)
sudo lb clean

# 4. Config live-build
lb config \
  --distribution trixie \
  --architecture amd64 \
  --binary-images iso-hybrid \
  --archive-areas "main contrib non-free non-free-firmware" \
  --iso-application "UniBan" \
  --iso-volume "UniBan v0.3" \
  --bootappend-live "boot=live components quiet splash"

# 5. Build
sudo lb build 2>&1 | tee build.log

echo "=== PRONTO. ISO em $(pwd)/live-image-amd64.hybrid.iso ==="
