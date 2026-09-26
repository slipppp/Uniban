#!/bin/bash
# UniBan Builder v0.1
# Builder des do começo do uniban graças a deus
set -e

echo "=== UniBan Builder v0.1 ==="

# 1. Ferramentas de build
sudo apt update
sudo apt install -y live-build live-config live-boot debootstrap \
    xorriso syslinux-common isolinux squashfs-tools curl

# 2. Entra no projeto
cd "$(dirname "$0")"

# 3. Limpa build anterior
sudo lb clean

# 4. Config do live
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
# alivio quando iso aparece
echo "=== PRONTO. ISO em $(pwd)/live-image-amd64.hybrid.iso ==="
