#!/bin/sh
# UniBan - aplica o wallpaper certo, não importa o nome do monitor
#
# CAUSA DO BUG "wallpaper só aparece na tela de senha, não no desktop":
# o xfce4-desktop.xml estático só cobre "monitor0" e "monitorVirtual1".
# Em hardware real (e em bastante VM) o xrandr dá nome tipo "eDP-1",
# "HDMI-A-1", "DP-1", variando por placa de vídeo/driver. Quando o nome
# não bate, o Xfce simplesmente ignora a propriedade e cai no fundo
# cinza padrão - só que a tela de LOGIN (lightdm-gtk-greeter) não usa
# xfconf, ela lê o arquivo de imagem direto, por isso funcionava só ali.
#
# Esse script roda como autostart de sessão Xfce e detecta o(s) nome(s)
# real(is) do monitor via xrandr, aplicando o wallpaper certo pra cada
# um - funciona em qualquer hardware/VM sem precisar adivinhar nome.
set -e

IMG="/usr/share/backgrounds/uniban/wallpaper.png"

[ -f "$IMG" ] || exit 0

# espera xfconfd subir (evita corrida logo no autologin, antes do
# daemon de config do Xfce estar pronto pra aceitar escrita)
i=0
while [ $i -lt 20 ]; do
  pgrep -x xfconfd >/dev/null 2>&1 && break
  sleep 0.5
  i=$((i + 1))
done

# pega nome de cada saída conectada (ex: eDP-1, HDMI-A-1, Virtual1...)
for m in $(xrandr --query 2>/dev/null | awk '/ connected/{print $1}'); do
  xfconf-query -c xfce4-desktop \
    -p "/backdrop/screen0/monitor$m/workspace0/last-image" \
    -n -t string -s "$IMG" 2>/dev/null || true
  xfconf-query -c xfce4-desktop \
    -p "/backdrop/screen0/monitor$m/workspace0/image-style" \
    -n -t int -s 5 2>/dev/null || true
done
