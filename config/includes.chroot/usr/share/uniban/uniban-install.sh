#!/bin/bash
# UniBan - instalador em disco (roda só na sessão live)
#
# Pergunta: disco, usuário, senha, teclado, fuso, autologin.
# Faz:      GPT (+ESP se UEFI / bios_boot se BIOS) + ext4 -> copia o
#           filesystem.squashfs da própria ISO -> configura -> GRUB.
# Não precisa de internet: tudo vem da ISO (grub-*-bin entram via hook 0008).
#
# Uso: uniban-install [-c arquivo.conf]
#   -c  modo sem perguntas (teste/automação). Arquivo shell com:
#       DISK USERNAME PASSWORD KEYMAP TZ AUTOLOGIN(0|1) [REMOVE_INSTALLER(0|1)]
#       (pergunta de "apagar disco" também é pulada - cuidado)
#
# Variável só pra teste: UNIBAN_SQUASHFS (caminho do .squashfs)

# whiptail só alinha acento (ç, ã) certo em locale UTF-8. Na live o locale
# pode ser "C" (sem pacote locales) -> caixa torta e título cortado.
# C.UTF-8 já vem embutido no glibc, não precisa gerar nada.
export LC_ALL=C.UTF-8 LANG=C.UTF-8

TARGET=/mnt/uniban-target
LOG=/var/log/uniban-install.log
VERSION="$(cat /usr/share/uniban/version 2>/dev/null)"

# Visual estilo debian-installer (só cor do whiptail - zero espaço extra):
# tela cheia de fundo vermelho UniBan, backtitle em cima, janela cinza com
# sombra no meio, botão ativo escuro. Muda só a paleta, nada de pacote novo.
export NEWT_COLORS='
root=white,red
roottext=white,red
border=black,lightgray
window=black,lightgray
shadow=black,black
title=red,lightgray
button=black,lightgray
actbutton=white,black
compactbutton=black,lightgray
checkbox=black,lightgray
actcheckbox=white,red
entry=black,white
disentry=gray,lightgray
label=black,lightgray
listbox=black,lightgray
actlistbox=white,red
sellistbox=black,lightgray
actsellistbox=white,red
textbox=black,lightgray
acttextbox=white,red
helpline=white,black
emptyscale=,lightgray
fullscale=,red
'
BACKTITLE="UniBan ${VERSION} - Instalador   [Tab/setas = mover   Enter = confirmar]"
wt() { whiptail --backtitle "$BACKTITLE" "$@"; }

BANNER=' _   _       _ ____
| | | |_ __ (_) __ )  __ _ _ __
| | | | '"'"'_ \| |  _ \ / _` | '"'"'_ \
| |_| | | | | | |_) | (_| | | | |
 \___/|_| |_|_|____/ \__,_|_| |_|'

# ------------------------------------------------------------- util
have() { command -v "$1" >/dev/null 2>&1; }
# etapa atual: caixa na tela (interativo) ou linha no terminal (-c)
say()  {
  if [ -z "$BATCH" ] && have whiptail; then wt --title "UniBan" --infobox "\n  $*\n\n  Aguarde, não desligue o computador." 9 64
  else printf '\n==> %s\n' "$*"; fi
}
die()  {
  [ -z "$BATCH" ] && have whiptail && wt --title "ERRO" --msgbox "$*\n\nLog completo: $LOG" 12 64
  printf '\nERRO: %s\n(log completo: %s)\n' "$*" "$LOG" >&2; cleanup; exit 1
}
msg() { wt --title "UniBan" --msgbox "$1" 12 64; }

# ---------------------------------------------------------- sim/não piscando
# Caixa Sim/Não própria (mesmas cores do whiptail). O botão onde o cursor
# está PISCA: o PRÓPRIO script redesenha o botão a cada 0,5 s alternando
# preto <-> vermelho (não depende do terminal suportar atributo "blink":
# xfce4-terminal/VTE e várias VMs ignoram SGR 5). whiptail não pisca.
# Uso: yesno "Título" "texto" [defaultno]   -> 0 = Sim, 1 = Não/Esc
# Teclas: Tab / setas / h l alternam - Enter confirma - s/y = Sim, n = Não.
yesno() {
  local title="$1" text="$2" sel=0 ph=1 rc rows cols w h top left i k k2 line maxl=0
  [ "$3" = defaultno ] && sel=1
  local -a L
  mapfile -t L <<<"$text"          # mantém linhas em branco
  read -r rows cols < <(stty size 2>/dev/null); : "${rows:=24}" "${cols:=80}"
  for line in "${L[@]}"; do [ "${#line}" -gt "$maxl" ] && maxl=${#line}; done
  w=$((maxl + 6)); [ "$w" -lt 44 ] && w=44; [ "$w" -gt $((cols - 4)) ] && w=$((cols - 4))
  h=$(( ${#L[@]} + 6 ))
  top=$(( (rows - h) / 2 )); [ "$top" -lt 2 ] && top=2
  left=$(( (cols - w) / 2 )); [ "$left" -lt 1 ] && left=1

  local ESC=$'\e' hbar=""
  for ((i = 0; i < w - 2; i++)); do hbar+="─"; done
  local sp; sp="$(printf '%*s' "$w" '')"

  printf '%s[?25l%s[0;41m%s[2J' "$ESC" "$ESC" "$ESC"                  # cursor off, tela vermelha
  printf '%s[1;1H%s[97;41m %s%s[K' "$ESC" "$ESC" "$BACKTITLE" "$ESC"  # backtitle
  for ((i = 1; i <= h; i++)); do                                      # sombra
    printf '%s[%d;%dH%s[40m%s' "$ESC" $((top + i)) $((left + 2)) "$ESC" "${sp:0:$w}"
  done
  # janela cinza
  printf '%s[%d;%dH%s[0;30;47m┌%s┐' "$ESC" "$top" "$left" "$ESC" "$hbar"
  local tt=" $title "
  printf '%s[%d;%dH%s[31;47m┤%s├' "$ESC" "$top" $((left + (w - ${#tt} - 2) / 2)) "$ESC" "$tt"
  for ((i = 1; i < h - 1; i++)); do
    printf '%s[%d;%dH%s[0;30;47m│%s│' "$ESC" $((top + i)) "$left" "$ESC" "${sp:0:$((w - 2))}"
  done
  printf '%s[%d;%dH%s[0;30;47m└%s┘' "$ESC" $((top + h - 1)) "$left" "$ESC" "$hbar"
  for ((i = 0; i < ${#L[@]}; i++)); do
    printf '%s[%d;%dH%s[0;30;47m%s' "$ESC" $((top + 2 + i)) $((left + 3)) "$ESC" "${L[$i]:0:$((w - 6))}"
  done

  local brow=$((top + h - 3)) bsim bnao
  bsim=$((left + w / 2 - 12)); bnao=$((left + w / 2 + 4))
  draw_buttons() {
    local on="1;97;40"; [ "$ph" -eq 0 ] && on="1;97;41"   # fase A preto / fase B vermelho
    local off="0;30;47"
    local cs="$off" cn="$off"
    [ "$sel" -eq 0 ] && cs="$on" || cn="$on"
    printf '%s[%d;%dH%s[%sm<  Sim  >%s[%d;%dH%s[%sm<  Não  >%s[0m' \
      "$ESC" "$brow" "$bsim" "$ESC" "$cs" "$ESC" "$brow" "$bnao" "$ESC" "$cn" "$ESC"
  }
  while :; do
    draw_buttons
    IFS= read -rsn1 -t 0.5 k </dev/tty; rc=$?
    if [ "$rc" -gt 128 ]; then ph=$((1 - ph)); continue; fi   # timeout = só pisca
    [ "$rc" -ne 0 ] && k=$'\e'                                # EOF = Esc
    ph=1
    case "$k" in
      "")        break ;;                                   # Enter
      " ")       break ;;
      $'\t'|h|l) sel=$((1 - sel)) ;;
      s|S|y|Y)   sel=0; break ;;
      n|N)       sel=1; break ;;
      $'\e')     IFS= read -rsn2 -t 0.1 k2 </dev/tty
                 case "$k2" in
                   '[C'|'[D'|'OC'|'OD'|'[Z') sel=$((1 - sel)) ;;
                   "") sel=1; break ;;                      # Esc sozinho = Não
                 esac ;;
    esac
  done
  printf '%s[0m%s[2J%s[H%s[?25h' "$ESC" "$ESC" "$ESC" "$ESC"
  return "$sel"
}

cleanup() {
  # desmonta tudo que montamos, em ordem inversa
  for m in dev/pts dev proc sys/firmware/efi/efivars sys run boot/efi ""; do
    umount -l "$TARGET/$m" 2>/dev/null
  done
  umount -l "$TARGET" 2>/dev/null
  return 0
}

# executa e registra no log; falhou -> aborta com mensagem
run() { "$@" >>"$LOG" 2>&1 || die "falhou: $*"; }

# ----------------------------------------------------------- pré-checks
check_env() {
  [ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"
  grep -qs 'boot=live' /proc/cmdline || die "só roda na sessão live da ISO (nada foi alterado)"
  for t in whiptail parted mkfs.ext4 mount unsquashfs blkid chroot lsblk wipefs; do
    have "$t" || die "falta '$t' na ISO"
  done
  [ -d /sys/firmware/efi ] && UEFI=1 || UEFI=0
  [ "$UEFI" -eq 1 ] && { have mkfs.vfat || die "falta mkfs.vfat (dosfstools)"; }
  : > "$LOG" 2>/dev/null || LOG=/tmp/uniban-install.log

  # acha a imagem do sistema na mídia live
  SQ="${UNIBAN_SQUASHFS:-}"
  if [ -z "$SQ" ]; then
    for c in /run/live/medium/live/filesystem.squashfs \
             /lib/live/mount/medium/live/filesystem.squashfs \
             /run/live/medium/live/*.squashfs; do
      [ -f "$c" ] && { SQ="$c"; break; }
    done
  fi
  [ -f "$SQ" ] || die "não achei filesystem.squashfs da ISO"
}

# ------------------------------------------------------------ perguntas
pick_disk() {
  # disco que contém a mídia live (não oferecer)
  LIVEDEV="$(findmnt -n -o SOURCE /run/live/medium 2>/dev/null)"
  LIVEDISK=""
  [ -n "$LIVEDEV" ] && LIVEDISK="$(lsblk -no PKNAME "$LIVEDEV" 2>/dev/null | head -n 1)"

  set --
  while read -r name size type ro model; do
    [ "$type" = disk ] && [ "$ro" = 0 ] || continue
    [ "$name" = "$LIVEDISK" ] && continue
    case "$name" in zram*|ram*|loop*|sr*|fd*) continue ;; esac  # zram = swap na RAM, não é disco
    set -- "$@" "/dev/$name" "$size ${model:-disco}"
  done <<EOF
$(lsblk -dn -e 7,11 -o NAME,SIZE,TYPE,RO,MODEL 2>/dev/null)
EOF
  [ "$#" -gt 0 ] || die "nenhum disco disponível"
  DISK="$(wt --title "UniBan - disco" --menu \
    "Escolha o disco onde instalar.\nTUDO nesse disco será APAGADO." 18 70 8 "$@" 3>&1 1>&2 2>&3)" || exit 1
  [ -b "$DISK" ] || die "disco inválido: $DISK"

  yesno "UniBan - confirmar" "APAGAR TUDO em $DISK e instalar o UniBan?

$(lsblk -no NAME,SIZE,FSTYPE,MOUNTPOINT "$DISK" 2>/dev/null)" defaultno || exit 1
}

pick_user() {
  while :; do
    USERNAME="$(wt --title "UniBan - usuário" --inputbox \
      "Nome de usuário (minúsculas, sem espaço):" 10 60 "" 3>&1 1>&2 2>&3)" || exit 1
    case "$USERNAME" in
      ""|root|[!a-z_]*|*[!a-z0-9_-]*) msg "Nome inválido. Use letras minúsculas, números, - e _ (começando por letra)." ;;
      *) [ "${#USERNAME}" -le 32 ] && break; msg "Nome grande demais (máx 32)." ;;
    esac
  done
}

pick_password() {
  while :; do
    P1="$(wt --title "UniBan - senha" --passwordbox "Senha de $USERNAME:" 10 60 3>&1 1>&2 2>&3)" || exit 1
    P2="$(wt --title "UniBan - senha" --passwordbox "Repita a senha:" 10 60 3>&1 1>&2 2>&3)" || exit 1
    [ -n "$P1" ] || { msg "Senha vazia não pode."; continue; }
    [ "$P1" = "$P2" ] && { PASSWORD="$P1"; break; }
    msg "As senhas não batem. Tente de novo."
  done
}

pick_keymap() {
  KEYMAP="$(wt --title "UniBan - teclado" --menu "Layout do teclado:" 18 60 8 \
    br   "Português Brasil (ABNT2)" \
    us   "Inglês EUA" \
    pt   "Português Portugal" \
    es   "Espanhol" \
    de   "Alemão" \
    fr   "Francês" \
    it   "Italiano" \
    outro "Digitar o código" 3>&1 1>&2 2>&3)" || exit 1
  if [ "$KEYMAP" = outro ]; then
    KEYMAP="$(wt --title "UniBan - teclado" --inputbox \
      "Código XKB do layout (ex: gb, ru, latam):" 10 60 "br" 3>&1 1>&2 2>&3)" || exit 1
  fi
  [ -d /usr/share/X11/xkb/symbols ] && [ ! -f "/usr/share/X11/xkb/symbols/$KEYMAP" ] &&
    die "layout '$KEYMAP' não existe em /usr/share/X11/xkb/symbols"
  return 0
}

pick_tz() {
  TZ="$(wt --title "UniBan - fuso horário" --menu "Fuso horário:" 18 60 8 \
    America/Sao_Paulo "Brasília" \
    America/Manaus    "Amazonas" \
    America/Recife    "Nordeste" \
    America/Fortaleza "Fortaleza" \
    America/Noronha   "Fernando de Noronha" \
    Europe/Lisbon     "Portugal" \
    UTC               "UTC" \
    outro             "Digitar (ex: America/New_York)" 3>&1 1>&2 2>&3)" || exit 1
  if [ "$TZ" = outro ]; then
    TZ="$(wt --title "UniBan - fuso" --inputbox "Região/Cidade:" 10 60 "America/Sao_Paulo" 3>&1 1>&2 2>&3)" || exit 1
  fi
}

pick_autologin() {
  if yesno "UniBan - login" "Entrar direto no desktop, sem pedir senha? (como na ISO live)

Não = pede a senha no login."; then
    AUTOLOGIN=1; else AUTOLOGIN=0; fi
}

validate_answers() {
  [ -b "$DISK" ] || die "disco inválido: $DISK"
  case "$USERNAME" in ""|root|[!a-z_]*|*[!a-z0-9_-]*) die "usuário inválido: $USERNAME" ;; esac
  [ -n "$PASSWORD" ] || die "senha vazia"
  [ -f "/usr/share/zoneinfo/$TZ" ] || die "fuso inválido: $TZ"
}

# --------------------------------------------------------- particionar
part() {  # nome da partição N do disco (nvme0n1 -> nvme0n1p1)
  case "$DISK" in *[0-9]) printf '%sp%s' "$DISK" "$1" ;; *) printf '%s%s' "$DISK" "$1" ;; esac
}

partition_disk() {
  say "Particionando $DISK ($([ "$UEFI" -eq 1 ] && echo UEFI || echo BIOS))"
  # desmonta o que estiver montado nesse disco
  for p in $(lsblk -lnpo NAME "$DISK" | tail -n +2); do umount -l "$p" 2>/dev/null; done
  run wipefs -a "$DISK"
  run parted -s "$DISK" mklabel gpt
  if [ "$UEFI" -eq 1 ]; then
    run parted -s "$DISK" mkpart ESP fat32 1MiB 513MiB
    run parted -s "$DISK" set 1 esp on
    run parted -s "$DISK" mkpart UniBan ext4 513MiB 100%
    PESP="$(part 1)"; PROOT="$(part 2)"
  else
    run parted -s "$DISK" mkpart bios_grub 1MiB 3MiB
    run parted -s "$DISK" set 1 bios_grub on
    run parted -s "$DISK" mkpart UniBan ext4 3MiB 100%
    PROOT="$(part 2)"
  fi
  have udevadm && udevadm settle 2>/dev/null
  sleep 1
  [ -b "$PROOT" ] || die "partição $PROOT não apareceu"

  say "Formatando"
  [ "$UEFI" -eq 1 ] && run mkfs.vfat -F32 -n UNIBAN-EFI "$PESP"
  run mkfs.ext4 -F -L UniBan "$PROOT"
}

# -------------------------------------------------------------- copiar
copy_system() {
  say "Copiando sistema (alguns minutos)"
  mkdir -p "$TARGET"
  run mount "$PROOT" "$TARGET"
  if [ "$UEFI" -eq 1 ]; then
    mkdir -p "$TARGET/boot/efi"
    run mount "$PESP" "$TARGET/boot/efi"
  fi
  # -percentage imprime só números -> alimenta a barra do whiptail
  if have whiptail && [ -z "$BATCH" ]; then
    unsquashfs -f -percentage -d "$TARGET" "$SQ" 2>>"$LOG" \
      | wt --title "UniBan" --gauge "Copiando sistema para $PROOT ..." 7 64 0
  else
    unsquashfs -f -d "$TARGET" "$SQ" >>"$LOG" 2>&1
  fi
  # o pipe esconde o código de saída: confere o resultado de verdade
  [ -x "$TARGET/bin/sh" ] || [ -e "$TARGET/usr/bin/env" ] || die "cópia incompleta (sem /usr/bin/env no destino)"
  ls "$TARGET"/boot/vmlinuz-* >/dev/null 2>&1 || die "imagem sem kernel em /boot (ISO incompleta)"
  mkdir -p "$TARGET/proc" "$TARGET/sys" "$TARGET/dev" "$TARGET/run" "$TARGET/tmp"
  chmod 1777 "$TARGET/tmp"
}

# ----------------------------------------------------------- configurar
in_chroot() { chroot "$TARGET" "$@"; }

configure_system() {
  say "Configurando sistema"
  for m in dev dev/pts proc sys run; do
    mkdir -p "$TARGET/$m"; run mount --bind "/$m" "$TARGET/$m"
  done
  [ "$UEFI" -eq 1 ] && mount --bind /sys/firmware/efi/efivars "$TARGET/sys/firmware/efi/efivars" 2>/dev/null

  # fstab por UUID
  RU="$(blkid -s UUID -o value "$PROOT")"
  [ -n "$RU" ] || die "sem UUID em $PROOT"
  {
    echo "# UniBan - gerado pelo instalador"
    echo "UUID=$RU / ext4 defaults,noatime,errors=remount-ro 0 1"
    if [ "$UEFI" -eq 1 ]; then
      EU="$(blkid -s UUID -o value "$PESP")"
      echo "UUID=$EU /boot/efi vfat umask=0077 0 2"
    fi
  } > "$TARGET/etc/fstab"

  # hostname: fica "uniban" (já vem da ISO, hook 0007)

  # fuso
  echo "$TZ" > "$TARGET/etc/timezone"
  ln -sf "/usr/share/zoneinfo/$TZ" "$TARGET/etc/localtime"

  # teclado (mesmo formato do hook 0002)
  cat > "$TARGET/etc/default/keyboard" <<EOF
XKBMODEL="pc105"
XKBLAYOUT="$KEYMAP"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
EOF

  # usuário: senha entra por stdin (não aparece em ps / log)
  if in_chroot id "$USERNAME" >/dev/null 2>&1; then
    : # (nome igual ao usuário live "user": reaproveita)
  else
    run chroot "$TARGET" useradd -m -s /bin/bash "$USERNAME"
  fi
  run chroot "$TARGET" usermod -aG sudo,netdev,audio,video,plugdev,bluetooth,cdrom,lpadmin "$USERNAME"
  printf '%s:%s\n' "$USERNAME" "$PASSWORD" | chroot "$TARGET" chpasswd || die "chpasswd falhou"
  # root travado (usa sudo)
  in_chroot passwd -l root >>"$LOG" 2>&1
  # usuário live "user" some (senão ficaria uma conta sem senha no sistema)
  if [ "$USERNAME" != "user" ] && in_chroot id user >/dev/null 2>&1; then
    in_chroot userdel -r user >>"$LOG" 2>&1
  fi
  # fastfetch do usuário novo: o skel já traz config + .bashrc (hook 0007)

  # autologin do lightdm (50-autologin.conf aponta pro usuário "user" da live)
  AL="$TARGET/etc/lightdm/lightdm.conf.d/50-autologin.conf"
  if [ "$AUTOLOGIN" -eq 1 ]; then
    mkdir -p "$(dirname "$AL")"
    printf '[Seat:*]\nautologin-user=%s\nautologin-user-timeout=0\nautologin-session=xfce\n' "$USERNAME" > "$AL"
  else
    rm -f "$AL"
  fi

  # tira o que só faz sentido na live
  rm -f "$TARGET/etc/sudoers.d/uniban-live" \
        "$TARGET/usr/share/applications/uniban-install.desktop"
  rm -rf "$TARGET/home/$USERNAME/Desktop/uniban-install.desktop"
  in_chroot apt-get purge -y live-boot live-boot-initramfs-tools live-config live-config-systemd \
      live-config-sysvinit >>"$LOG" 2>&1 || true
  rm -rf "$TARGET/etc/live"

  # initramfs sem live-boot
  say "Gerando initramfs"
  run chroot "$TARGET" update-initramfs -u -k all
}

# ----------------------------------------------------------------- GRUB
install_grub() {
  say "Instalando GRUB"
  if [ -f "$TARGET/etc/default/grub" ]; then
    grep -q '^GRUB_DISTRIBUTOR=' "$TARGET/etc/default/grub" \
      && sed -i 's/^GRUB_DISTRIBUTOR=.*/GRUB_DISTRIBUTOR="UniBan"/' "$TARGET/etc/default/grub" \
      || echo 'GRUB_DISTRIBUTOR="UniBan"' >> "$TARGET/etc/default/grub"
  fi
  # logo de boot (Plymouth) também no sistema instalado
  if [ -f "$TARGET/etc/default/grub" ] && ! grep -q 'splash' "$TARGET/etc/default/grub"; then
    sed -i 's/^\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)"/\1 splash"/' "$TARGET/etc/default/grub"
  fi
  # menu do GRUB com a logo do UniBan (PNG ~24 KB, já vem da ISO)
  if [ -f "$TARGET/etc/default/grub" ] && [ -f "$TARGET/usr/share/uniban/grub-bg.png" ]; then
    sed -i '/^GRUB_BACKGROUND=/d;/^GRUB_GFXMODE=/d' "$TARGET/etc/default/grub"
    printf 'GRUB_BACKGROUND="/usr/share/uniban/grub-bg.png"\nGRUB_GFXMODE=1024x768,auto\n' >> "$TARGET/etc/default/grub"
  fi
  if [ "$UEFI" -eq 1 ]; then
    # 1) /EFI/BOOT/BOOTX64.EFI: boota mesmo se a NVRAM da placa/VM não guardar entrada
    run chroot "$TARGET" grub-install --target=x86_64-efi --efi-directory=/boot/efi --removable
    # 2) entrada "UniBan" na NVRAM (opcional - falha aqui não aborta)
    chroot "$TARGET" grub-install --target=x86_64-efi --efi-directory=/boot/efi \
        --bootloader-id=UniBan >>"$LOG" 2>&1 || echo "aviso: sem entrada NVRAM (ok, usa /EFI/BOOT)"
  else
    run chroot "$TARGET" grub-install --target=i386-pc "$DISK"
  fi
  run chroot "$TARGET" update-grub
  grep -q 'menuentry' "$TARGET/boot/grub/grub.cfg" || die "grub.cfg sem nenhuma entrada de boot"
}

# --------------------------------------------- remover o instalador (opcional)
INST_FILES="usr/share/uniban/uniban-install.sh usr/bin/uniban-install usr/share/applications/uniban-install.desktop"
INST_PKGS="squashfs-tools parted"

installer_size_kb() {
  kb=0
  for f in $INST_FILES; do
    [ -f "$TARGET/$f" ] && kb=$((kb + $(du -k "$TARGET/$f" | cut -f1)))
  done
  for p in $INST_PKGS; do
    n="$(chroot "$TARGET" dpkg-query -W -f='${Installed-Size}' "$p" 2>/dev/null)"
    [ -n "$n" ] && kb=$((kb + n))
  done
  echo "$kb"
}

# KB -> texto legível: "3,4 MB" ou "1,25 GB" (vírgula, pt-BR)
fmt_size() {
  awk -v kb="$1" 'BEGIN{
    if (kb >= 1048576)   s=sprintf("%.2f GB", kb/1048576)
    else if (kb >= 1024) s=sprintf("%.1f MB", kb/1024)
    else                 s=sprintf("%d KB", kb)
    gsub(/\./, ",", s); print s }'
}

# RAM que o instalador usa AGORA (este script + whiptail filhos), em KB
installer_ram_kb() {
  ps -o rss= -p "$$" --ppid "$$" 2>/dev/null | awk '{s+=$1} END{print s+0}'
}

# só tira pacote se o apt garantir que NADA além deles sai junto
safe_to_purge() {
  extra="$(chroot "$TARGET" apt-get -s purge $INST_PKGS 2>/dev/null | sed -n 's/^Remv \([^ ]*\).*/\1/p' \
           | grep -vxE "$(echo $INST_PKGS | tr ' ' '|')")"
  [ -z "$extra" ]
}

remove_installer() {
  say "Removendo instalador"
  for f in $INST_FILES; do rm -f "$TARGET/$f"; done
  rm -f "$TARGET"/home/*/Desktop/uniban-install.desktop
  if safe_to_purge; then
    chroot "$TARGET" apt-get purge -y $INST_PKGS >>"$LOG" 2>&1 || echo "aviso: purge falhou (ok)" >>"$LOG"
  else
    echo "aviso: purge pularia outros pacotes - só scripts removidos" >>"$LOG"
  fi
  # marca: o atualizador não traz o instalador de volta
  : > "$TARGET/usr/share/uniban/.no-installer"
}

ask_remove_installer() {
  if [ -n "$BATCH" ]; then [ "$REMOVE_INSTALLER" = 1 ] && remove_installer; return 0; fi
  SZ="$(fmt_size "$(installer_size_kb)")"
  RAMK="$(installer_ram_kb)"; [ "$RAMK" -gt 0 ] 2>/dev/null || RAMK=0
  RAM="$(fmt_size "$RAMK")"
  if yesno "Instalação finalizada" \
"UniBan foi instalado em $DISK com sucesso.

Deseja desinstalar o instalador agora?

  Espaço em disco : $SZ
  RAM em uso      : 0 MB fechado ($RAM com ele aberto)

O instalador só gasta RAM enquanto está aberto.
Se remover, para reinstalar vai precisar da ISO." defaultno; then
    remove_installer
  fi
}

# ----------------------------------------------------------------- main
main() {
  BATCH=""
  if [ "$1" = "-c" ]; then
    [ -f "$2" ] || { echo "arquivo de config não existe: $2" >&2; exit 2; }
    BATCH=1; . "$2"
  fi
  check_env "$@"

  if [ -z "$BATCH" ]; then
    wt --title "Bem-vindo" --msgbox \
"$BANNER

Instalador do UniBan $VERSION

Você vai escolher: disco, usuário, senha, teclado e fuso horário.
O disco escolhido será totalmente apagado." 18 64 || exit 1
    pick_disk; pick_user; pick_password; pick_keymap; pick_tz; pick_autologin
  fi
  validate_answers

  trap 'cleanup' EXIT
  partition_disk
  copy_system
  configure_system
  install_grub
  ask_remove_installer
  sync
  cleanup
  trap - EXIT

  if [ -z "$BATCH" ]; then msg "Tudo pronto!\n\nRemova o pendrive/DVD e reinicie o computador."
  else echo "Instalação concluída. Remova a mídia e reinicie."; fi
  return 0
}

main "$@"
exit $?
