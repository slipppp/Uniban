# UniBan v0.35

Debian 13 (Trixie) custom, foco jogo + desempenho + baixo consumo.
Regra do projeto: 90% Debian puro. Só remove bloat, só adiciona o essencial.

**v0.3**: base trocada pra Debian 13 (Trixie). Hostname/terminal agora mostra "uniban" (não mais "debian"). Fastfetch instalado com cores vermelho/vermelho escuro customizadas.

**v0.4**: logo custom (ASCII, vermelho/preto) no fastfetch (antes tava "auto" que nunca ia funcionar - fastfetch não conhece a distro "uniban"). zRAM (zstd) + earlyoom pra 2GB RAM. /tmp (tmpfs em trixie) limitado a 512M pra não estourar RAM. cups em socket-activation (só sobe quando usa). compositor xfwm4 desligado por padrão. locale/man/doc cortado via dpkg path-exclude (roda antes de instalar Xfce/Firefox, então funciona de verdade - localepurge antigo não funcionava, rodava tarde demais).

**v0.5**: logo do fastfetch trocado de ASCII pra imagem real (PNG vermelho puro, via chafa/truecolor - `/usr/share/uniban/logo-red.png`). Wallpaper próprio no desktop Xfce e na tela de login do lightdm (`/usr/share/backgrounds/uniban/wallpaper.png`). Base confirmada: Debian 13 "trixie" continua a stable mais recente (ponto 13.6, jul/2026) - `lb config --distribution trixie` já pega isso automático, sem precisar mudar nada no build.

**v0.6** (bugfix): 3 bugs reais corrigidos, cada um com causa técnica confirmada:
- **Autologin pedia senha que nunca existia** - `50-autologin.conf` já apontava `autologin-user=user`, mas nenhum hook de fato criava essa conta. Novo hook `0006-uniban-user.hook.chroot` cria o usuário, tira a senha (autologin não passa por PAM de senha mesmo) e ainda libera `nullok` no PAM como rede de segurança caso o autologin falhe por algum motivo.
- **Wallpaper só aparecia na tela de senha, sumia no desktop** - o `xfce4-desktop.xml` só cobria os nomes de monitor `monitor0`/`monitorVirtual1`. Em hardware real (e várias VMs) o `xrandr` dá nome tipo `eDP-1`/`HDMI-A-1`, que não batia com o XML estático, então o Xfce caía no fundo cinza padrão. A tela de login funcionava porque o lightdm-gtk-greeter lê o arquivo direto, sem xfconf. Fix: script `/usr/share/uniban/apply-wallpaper.sh` + autostart `/etc/xdg/autostart/uniban-wallpaper.desktop` que detecta o nome real do monitor via xrandr a cada login e aplica o wallpaper certo, não importa o hardware.
- **Fastfetch nunca mostrava a logo do UniBan** - o config ia pra `/etc/fastfetch/config.jsonc`, mas o fastfetch nunca lê esse caminho (só lê `~/.config/fastfetch/config.jsonc` de cada usuário). Fastfetch sempre rodava 100% no default, ignorando a config inteira. Fix: config vai pro `/etc/skel` (novos usuários) e é copiado pro `/home/user` também, com dono ajustado. Logo agora é o ASCII truecolor pré-renderizado (`type: raw`, `/usr/share/uniban/logo-red.ans`) em vez de conversão dinâmica via chafa - menos dependência de build do fastfetch.

## Instalador + Atualizador (v0.7)

**Instalar no disco** (só na sessão live): ícone "Instalar UniBan" no desktop ou `sudo uniban-install`.
Pergunta disco, usuário, senha, teclado, fuso e autologin. Faz GPT + ext4 (ESP FAT32 se UEFI, `bios_grub` se BIOS), copia o `filesystem.squashfs` da própria ISO (sem internet), cria o usuário, trava o root, remove a conta `user` da live e o `live-boot`/`live-config`, regenera initramfs e instala o GRUB (UEFI grava também `/EFI/BOOT`, boota mesmo sem NVRAM). Log: `/var/log/uniban-install.log`. Secure Boot não suportado (sem shim assinado).
Sem perguntas (teste/automação): `sudo uniban-install -c arquivo.conf` com `DISK USERNAME PASSWORD KEYMAP TZ AUTOLOGIN`.

**Atualizar**: "Atualizar UniBan" no menu ou `uniban-update` (`--check` só verifica, `-y` não pergunta).
Lê a versão em `/usr/share/uniban/version`, consulta `https://api.github.com/repos/slipppp/Uniban/releases/latest`, compara (`sort -V`), baixa, valida, faz backup em `/var/lib/uniban/backup-<versão>.tar.gz`, aplica e, se algo falhar, restaura sozinho.
- Atualiza só arquivos gerenciados do UniBan (`usr/share/uniban/`, wallpaper, launchers `uniban-*`, `usr/bin/uniban-*`, fundo do greeter). Não mexe em pacotes Debian, nem no autologin, nem em arquivos do usuário. Mudança de hook/pacote exige ISO nova.
- Formato preferido da release: asset `uniban-update-<versão>.tar.gz` (raiz com `usr/`, `etc/`...) + sha256 (campo `digest` do GitHub ou asset `.sha256`). Sem asset, usa o código-fonte da tag (`config/includes.chroot/`), só com validação estrutural (sem hash publicado).
- Ao publicar release: **bump em `config/includes.chroot/usr/share/uniban/version`** e tag com o número (`UnibanV0.3`, `v0.3`...).

**v0.8**: visual do instalador (fundo preto/vermelho em tela cheia, banner, caixa por etapa) e pergunta final "remover o instalador?" (mostra MB em disco; RAM = 0 fora da execução; só purga `squashfs-tools`/`parted` se o apt confirmar que nada mais sai junto; marca `.no-installer` pro atualizador não trazer de volta). Instalado ganha `splash` no GRUB.
**Bug do logo de boot**: build passava `quiet splash` mas o Plymouth nunca foi instalado. Hook `0030-uniban-theme-boot` instala `plymouth` e ativa o tema `uniban` (`usr/share/plymouth/themes/uniban`, logo 256px derivado do `logo-red.png`). Menu da ISO (syslinux/GRUB) segue padrão.
**Arc-Dark padrão**: `arc-theme` (GTK2/GTK3/xfwm4) via hook 0030; default em `xsettings.xml`, `xfwm4.xml`, `/etc/gtk-{2,3}.0`, greeter do lightdm. Não vem o "Toggle Theme" da release v0.2 (código não estava no zip).

**v0.9**:
- **Logo de boot**: 3 camadas. (1) Plymouth `uniban` (hook 0030) agora com `FRAMEBUFFER=y`, `plymouthd.conf` e checagem DENTRO do initramfs - se o tema não entrou, o build falha em vez de gerar ISO sem logo. (2) Menu da ISO (BIOS isolinux + UEFI grub) com `logo-red.png` via `config/includes.binary/{isolinux,boot/grub}/splash.png`. (3) GRUB do sistema instalado com fundo `/usr/share/uniban/grub-bg.png` (24 KB).
- **Arc-Dark de volta (GTK2 + GTK3 + xfwm4)**: `arc-theme` + engines GTK2, gravado em `/etc`, `/etc/skel` e `/home/user` (nenhum first-run volta pro claro). Pasta do tema faltando = build falha.
- **Instalador**: visual estilo debian-installer (fundo vermelho UniBan em tela cheia, janela cinza centralizada, backtitle com teclas). Locale `C.UTF-8` forçado (acento não quebra mais a caixa). Tela final: "deseja desinstalar o instalador?" com espaço em disco (KB/MB/GB) e RAM (0 fechado + valor medido aberto).
- **Build quebrava no `bootstrap_cache save`** (`cp: ... chroot/sys/... Permissão negada` → `E: An unexpected failure occurred`): sobra de mount (`chroot/sys`) de build anterior que travou. `build-uniban.sh` agora desmonta tudo em `chroot/` antes (e ao sair), apaga `chroot`/`cache` e liga `--cache false --cache-stages false` (não copia mais o chroot inteiro pro cache).
- **Dock sempre visível + painéis transparentes**: hook `0031-uniban-panel` edita o `default.xml` real do `xfce4-panel` (panel-1 = barra de cima, panel-2 = dock de baixo): `autohide-behavior=0` (o dock vinha com 1 = esconde sozinho) e fundo sólido com alpha 0.0 (`PANEL_ALPHA` no topo do hook). Compositor do xfwm4 ligado (`use_compositing`) - sem ele transparência não aparece. Config depois: clique direito no painel > Painel > Preferências do painel (aba Exibição = esconder; aba Aparência = fundo/transparência). Vale pra conta nova; conta que já tem painel salvo mantém o dela.
- **Instalador**: caixas Sim/Não (confirmar disco, autologin, desinstalar instalador) agora próprias: botão selecionado PISCA preto↔vermelho a cada 0,5 s, redesenhado pelo próprio script (não usa atributo blink do terminal - VTE/VMs ignoram). Tab/setas/h/l alternam, Enter confirma, s/y = Sim, n = Não, Esc = Não. Instalador passou pra `bash`.
- **Apps escuros**: hook `0032-uniban-dark-apps`. Firefox ESR: UI escura + sites em modo escuro (`/usr/lib/firefox-esr/defaults/pref/uniban-dark.js`; muda em Configurações > Aparência do site). GTK4/libadwaita: `gtk-4.0/settings.ini` em `/etc`, `/etc/skel` e `/home/user`. Qt: sem app Qt, ignorado.
- **Instalador gráfico** (estilo debian-installer gráfico): `uniban-install-gui.py` (GTK3 + python3-gi, já vêm com o blueman). Abre sozinho logo depois do boot (autostart só se `boot=live` em `/proc/cmdline`; instalado não abre). Banner vermelho com logo, miolo bege, botões Sair | Voltar Continuar. Telas: boas-vindas, disco, usuário/senha, teclado/fuso, resumo, progresso, "desinstalar instalador?" (espaço + RAM), concluído. É só a cara: chama o instalador de terminal com `--gui` (protocolo `@STEP/@PCT/@ASK_REMOVE`), que continua sendo o plano B (`uniban-install`, e é o fallback automático se GTK falhar). Custo: ~100 MB de RAM enquanto aberto, 0 depois.
- **Banner do instalador**: `usr/share/uniban/banner.png` (1920x86, arte fornecida). Fica centralizado e cortado pra caber em qualquer largura de tela; altura 86 px. A arte tem "0.35" escrito dentro (bate com a versão). Sem o arquivo, volta o gradiente + logo.
- **Instalador: nome completo + senha de root**. Campo "Seu nome" aceita espaço, acento e maiúscula (vai pro GECOS, aparece no login); o login Linux continua só `[a-z_][a-z0-9_-]*` (sugerido automático a partir do nome). Root: checkbox "usar a senha do usuário como senha do root", ou senha própria, ou vazio = root travado (padrão, usa sudo). Backend: `FULLNAME` e `ROOT_PASSWORD` no `-c`. Terminal ganhou as mesmas perguntas.
- **Banner do instalador trocado** (foto cinza, 1920x86) e **barra de progresso 1% -> 100%**: backend manda % geral (particionar 1-4, copiar 5-85, configurar 86-94, GRUB 95-99, fim 100); GUI mostra "NN%" e anda 1% por vez, sem pular nem voltar; em etapa longa sem marca (initramfs) rasteja devagar e para antes da próxima marca.
- **Config do terminal**: `uniban-terminal-config` (janela "Configurar Terminal UniBan" ou CLI `status|fastfetch on|off|transparency on|off|opacity 30..100`). fastfetch = guarda no `.bashrc` + flag `~/.config/uniban/no-fastfetch`; transparência = `BackgroundMode`/`BackgroundDarkness` do `terminalrc`. Hook `0033` põe terminal transparente (0.85) por padrão; antes não existia terminalrc no projeto.
- Volume da ISO agora `UNIBAN_035` (o antigo com espaço/ponto gerava WARNING do xorriso).
- Versão do projeto: `0.35` (`usr/share/uniban/version`) = mini atualização da 0.3. Tag: `v0.35`.
- **Cuidado com a numeração**: o atualizador compara com `sort -V`, que lê `0.35` como 0.**35** (maior que 0.4!). Próximas versões têm que ser maiores nesse formato: `0.36`, `0.40`, `0.50`, `1.0`. NÃO lançar `0.4` (usuário de 0.35 nunca receberia). Alternativa: usar `0.3.5` / `0.4.0` (semver).

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
│   │   (+ usr/share/uniban/uniban-install.sh, uniban-update.sh, version; usr/bin/uniban-{install,update}; usr/share/applications/uniban-*.desktop)
│   └── hooks/live/
│       ├── 0001-uniban-locale-trim.hook.chroot  # corta locale/man/doc ANTES de instalar o resto
│       ├── 0005-install-desktop.hook.chroot     # instalação forçada Xfce+Firefox+drivers
│       ├── 0006-uniban-user.hook.chroot         # cria usuário "user" do autologin (bugfix v0.6)
│       ├── 0007-uniban-branding.hook.chroot     # hostname uniban, os-release, fastfetch + logo custom
│       ├── 0008-uniban-installer.hook.chroot    # deps do instalador/atualizador, +x, sudo live, atalho
│       ├── 0012-uniban-perf.hook.chroot         # zram, earlyoom, limite /tmp
│       └── 0020-gaming-cleanup.hook.chroot      # multiarch + gamemode + remove bloat
└── README.md
```

## Próximas etapas (não feitas ainda, de propósito)

Otimização CPU/GPU (governor, TLP/auto-cpufreq), ferramenta própria UniBan, instalador, tema visual completo, wallpaper, perfis de desempenho (silencioso/balanceado/jogo).
Cada uma vem com: o que muda -> por que -> benefício -> problema possível -> como desfazer.
