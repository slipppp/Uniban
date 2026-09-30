# UniBan v0.2

Debian 13 (Trixie) custom, foco jogo + desempenho + baixo consumo.
Regra do projeto: 90% Debian puro. Só remove bloat, só adiciona o essencial.

**v0.3**: base trocada pra Debian 13 (Trixie). Hostname/terminal agora mostra "uniban" (não mais "debian"). Fastfetch instalado com cores vermelho/vermelho escuro customizadas.

**v0.4**: logo custom (ASCII, vermelho/preto) no fastfetch (antes tava "auto" que nunca ia funcionar - fastfetch não conhece a distro "uniban"). zRAM (zstd) + earlyoom pra 2GB RAM. /tmp (tmpfs em trixie) limitado a 512M pra não estourar RAM. cups em socket-activation (só sobe quando usa). compositor xfwm4 desligado por padrão. locale/man/doc cortado via dpkg path-exclude (roda antes de instalar Xfce/Firefox, então funciona de verdade - localepurge antigo não funcionava, rodava tarde demais).

**v0.5**: logo do fastfetch trocado de ASCII pra imagem real (PNG vermelho puro, via chafa/truecolor - `/usr/share/uniban/logo-red.png`). Wallpaper próprio no desktop Xfce e na tela de login do lightdm (`/usr/share/backgrounds/uniban/wallpaper.png`). Base confirmada: Debian 13 "trixie" continua a stable mais recente (ponto 13.6, jul/2026) - `lb config --distribution trixie` já pega isso automático, sem precisar mudar nada no build.

**v0.6** (bugfix): 3 bugs reais corrigidos, cada um com causa técnica confirmada:
- **Autologin pedia senha que nunca existia** - `50-autologin.conf` já apontava `autologin-user=user`, mas nenhum hook de fato criava essa conta. Novo hook `0006-uniban-user.hook.chroot` cria o usuário, tira a senha (autologin não passa por PAM de senha mesmo) e ainda libera `nullok` no PAM como rede de segurança caso o autologin falhe por algum motivo.
- **Wallpaper só aparecia na tela de senha, sumia no desktop** - o `xfce4-desktop.xml` só cobria os nomes de monitor `monitor0`/`monitorVirtual1`. Em hardware real (e várias VMs) o `xrandr` dá nome tipo `eDP-1`/`HDMI-A-1`, que não batia com o XML estático, então o Xfce caía no fundo cinza padrão. A tela de login funcionava porque o lightdm-gtk-greeter lê o arquivo direto, sem xfconf. Fix: script `/usr/share/uniban/apply-wallpaper.sh` + autostart `/etc/xdg/autostart/uniban-wallpaper.desktop` que detecta o nome real do monitor via xrandr a cada login e aplica o wallpaper certo, não importa o hardware.
- **Fastfetch nunca mostrava a logo do UniBan** - o config ia pra `/etc/fastfetch/config.jsonc`, mas o fastfetch nunca lê esse caminho (só lê `~/.config/fastfetch/config.jsonc` de cada usuário). Fastfetch sempre rodava 100% no default, ignorando a config inteira. Fix: config vai pro `/etc/skel` (novos usuários) e é copiado pro `/home/user` também, com dono ajustado. Logo agora é o ASCII truecolor pré-renderizado (`type: raw`, `/usr/share/uniban/logo-red.ans`) em vez de conversão dinâmica via chafa - menos dependência de build do fastfetch.

## Requisito

Máquina Linux (Debian/Ubuntu) real ou VM, com internet, ~10GB livre.

## Como buildar (1 comando)

```bash
chmod +x build-uniban.sh
./build-uniban.sh
```

Espera 15-40min. Sai `live-image-amd64.hybrid.iso` na raiz do projeto.

## O que tem dentro

- Xfce4 (leve, não GNOME/KDE) + autologin gráfico (sem tela senha)
- NetworkManager (Wi-Fi/rede)
- PulseAudio (áudio)
- Bluetooth + CUPS (impressora)
- Firmware completo (Wi-Fi, GPU, chipset)
- Mesa + Vulkan drivers (jogos)
- Firefox ESR pré-instalado (repo oficial Debian)
- Fastfetch com tema vermelho (roda automático ao abrir terminal)
- Identidade "UniBan" no hostname, prompt e /etc/os-release
- Gamemode (otimização CPU durante jogo)
- Multiarch i386 pronto (Steam/Proton futuro)
- SEM: LibreOffice, GIMP, xterm, leitor de tela, screensaver, outros bloats padrão

## Testar em VM

```bash
qemu-system-x86_64 -m 2048 -smp 2 -enable-kvm \
  -cdrom live-image-amd64.hybrid.iso -boot d -vga virtio
```

Ou GNOME Boxes (mais fácil, GUI):

```bash
sudo apt install gnome-boxes
```

Abre programa -> New -> seleciona ISO -> play.

## Testar em pendrive

```bash
lsblk                      # confirma qual é o pendrive (ex: /dev/sdb)
sudo dd if=live-image-amd64.hybrid.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

⚠️ dd apaga tudo no device escolhido. Confirma device certo antes.

## Checklist pós-boot

```bash
journalctl -b -p err       # erro crítico?
cat /var/log/Xorg.0.log | grep EE   # erro gráfico?
nmcli device status        # rede subiu?
pactl list sinks short     # áudio detectou?
free -h                    # RAM idle (referência Xfce: ~300-500MB)
zramctl                    # zram ativo?
systemctl status earlyoom  # earlyoom rodando?
fastfetch                  # logo uniban aparece certo?
```

## Estrutura

```
uniban/
├── build-uniban.sh              # roda isso, builda tudo
├── config/
│   ├── package-lists/uniban.list.chroot   # pacotes instalados (backup)
│   ├── includes.chroot/
│   │   ├── etc/lightdm/lightdm.conf.d/50-autologin.conf            # autologin gráfico
│   │   ├── etc/lightdm/lightdm-gtk-greeter.conf.d/60-uniban-background.conf  # wallpaper tela login
│   │   ├── etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml  # wallpaper desktop (fallback)
│   │   ├── etc/xdg/autostart/uniban-wallpaper.desktop  # dispara fix do wallpaper todo login
│   │   └── usr/share/uniban/apply-wallpaper.sh         # detecta monitor real via xrandr, aplica wallpaper
│   └── hooks/live/
│       ├── 0001-uniban-locale-trim.hook.chroot  # corta locale/man/doc ANTES de instalar o resto
│       ├── 0005-install-desktop.hook.chroot     # instalação forçada Xfce+Firefox+drivers
│       ├── 0006-uniban-user.hook.chroot         # cria usuário "user" do autologin (bugfix v0.6)
│       ├── 0007-uniban-branding.hook.chroot     # hostname uniban, os-release, fastfetch + logo custom
│       ├── 0012-uniban-perf.hook.chroot         # zram, earlyoom, limite /tmp
│       └── 0020-gaming-cleanup.hook.chroot      # multiarch + gamemode + remove bloat
└── README.md
```

## Próximas etapas (não feitas ainda, de propósito)

Otimização CPU/GPU (governor, TLP/auto-cpufreq), ferramenta própria UniBan, instalador, tema visual completo, wallpaper, perfis de desempenho (silencioso/balanceado/jogo).
Cada uma vem com: o que muda -> por que -> benefício -> problema possível -> como desfazer.
