#!/usr/bin/python3
# UniBan - instalador gráfico (estilo debian-installer gráfico)
#
# Só a CARA: junta as respostas e chama o instalador de verdade
#   sudo uniban-install --gui -c <conf>
# que particiona/copia/configura/GRUB (mesmo código do instalador de terminal,
# que continua existindo como plano B). Protocolo (linhas na saída do backend):
#   @STEP texto        etapa atual
#   @PCT n             % da cópia do sistema
#   @ASK_REMOVE kb     pergunta se remove o instalador (GUI responde yes/no)
# Sem custo depois de fechado: não é serviço, só abre no boot da ISO live.
import os, sys, re, shlex, tempfile, threading, subprocess, unicodedata

try:
    import gi
    gi.require_version("Gtk", "3.0")
    from gi.repository import Gtk, Gdk, GLib, GdkPixbuf
except Exception:
    sys.exit(3)          # sem GTK/gi -> wrapper cai pro instalador de terminal

SHARE = os.environ.get("UNIBAN_SHARE", "/usr/share/uniban")
LOGO = os.path.join(SHARE, "logo-red.png")
BANNER = os.path.join(SHARE, "banner.png")
try:
    VERSION = open(os.path.join(SHARE, "version")).read().strip()
except OSError:
    VERSION = "?"

KEYMAPS = [("br", "Português Brasil (ABNT2)"), ("us", "Inglês EUA"),
           ("pt", "Português Portugal"), ("es", "Espanhol"), ("de", "Alemão"),
           ("fr", "Francês"), ("it", "Italiano")]
TZS = [("America/Sao_Paulo", "Brasília"), ("America/Manaus", "Amazonas"),
       ("America/Recife", "Nordeste (Recife)"), ("America/Fortaleza", "Fortaleza"),
       ("America/Noronha", "Fernando de Noronha"), ("Europe/Lisbon", "Portugal"),
       ("UTC", "UTC")]

CSS = b"""
window.uniban { background-color: #efebe7; }
.banner { background-image: linear-gradient(to right, #170909, #3d0c10 55%, #8a1119); }
.banner-img { background-repeat: no-repeat; background-position: center; background-size: cover; }
.banner-title { color: #ffffff; font-size: 34px; font-weight: 300; }
.banner-ver   { color: #f3b5b9; font-size: 34px; font-weight: 300; }
.page-title { font-weight: bold; font-size: 12pt; color: #222222; }
.box { background-color: #ffffff; border: 1px solid #b9b3ab; padding: 14px; }
.hint { color: #555555; }
.err  { color: #b00020; font-weight: bold; }
button.go { font-weight: bold; }
button.danger { background-image: none; background-color: #c8102e; color: #ffffff; font-weight: bold; }
treeview:selected, treeview:selected:focus { background-color: #c8102e; color: #ffffff; }
check:checked, radio:checked { background-color: #c8102e; border-color: #c8102e; background-image: none; }
progressbar trough, progressbar progress { min-height: 18px; }
progressbar progress { background-color: #c8102e; background-image: none; }
"""


def fmt_size(kb):
    kb = int(kb)
    if kb >= 1048576: s = "%.2f GB" % (kb / 1048576)
    elif kb >= 1024:  s = "%.1f MB" % (kb / 1024)
    else:             s = "%d KB" % kb
    return s.replace(".", ",")


def suggest_login(full):
    """'João da Silva' -> 'joaodasilva' (login Linux: minúsculas, sem espaço/acento)."""
    t = unicodedata.normalize("NFKD", full).encode("ascii", "ignore").decode().lower()
    t = re.sub(r"[^a-z0-9_-]", "", t)
    t = re.sub(r"^[^a-z_]+", "", t)
    return t[:32]


def my_rss_kb():
    try:
        for l in open("/proc/self/status"):
            if l.startswith("VmRSS:"):
                return int(l.split()[1])
    except OSError:
        pass
    return 0


def list_disks():
    """Mesma regra do instalador de terminal: sem mídia live, zram, loop, sr."""
    live = ""
    try:
        src = subprocess.run(["findmnt", "-n", "-o", "SOURCE", "/run/live/medium"],
                             capture_output=True, text=True).stdout.strip()
        if src:
            live = subprocess.run(["lsblk", "-no", "PKNAME", src], capture_output=True,
                                  text=True).stdout.split("\n")[0].strip()
    except OSError:
        pass
    out = subprocess.run(["lsblk", "-dn", "-e", "7,11", "-o", "NAME,SIZE,TYPE,RO,MODEL"],
                         capture_output=True, text=True).stdout
    disks = []
    for line in out.splitlines():
        p = line.split(None, 4)
        if len(p) < 4:
            continue
        name, size, typ, ro = p[:4]
        model = p[4].strip() if len(p) > 4 else "disco"
        if typ != "disk" or ro != "0" or name == live:
            continue
        if re.match(r"(zram|ram|loop|sr|fd)", name):
            continue
        disks.append(("/dev/" + name, size, model))
    return disks


class Installer(Gtk.Window):
    def __init__(self):
        super().__init__(title="Instalar UniBan")
        self.get_style_context().add_class("uniban")
        self.set_default_size(1000, 700)
        self.fullscreen()
        self.st = dict(disk="", name="", user="", pw="", rootmode="lock", rootpw="", keymap="br", tz="America/Sao_Paulo", autologin=True)
        self.proc = None
        self.busy = False
        self.connect("delete-event", lambda *a: self.busy)   # não fecha instalando

        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        self.add(root)

        # ---- banner (topo, como o do debian-installer)
        ban = Gtk.Box(); ban.get_style_context().add_class("banner")
        ban.set_size_request(-1, 86)
        inner = Gtk.Box(spacing=16); inner.set_halign(Gtk.Align.CENTER); inner.set_valign(Gtk.Align.CENTER)
        try:
            if not os.path.isfile(BANNER):
                pb = GdkPixbuf.Pixbuf.new_from_file_at_size(LOGO, 64, 64)
                inner.pack_start(Gtk.Image.new_from_pixbuf(pb), False, False, 0)
        except Exception:
            pass
        t = Gtk.Label(label="UniBan"); t.get_style_context().add_class("banner-title")
        v = Gtk.Label(label=VERSION); v.get_style_context().add_class("banner-ver")
        inner.pack_start(t, False, False, 0); inner.pack_start(v, False, False, 0)
        if os.path.isfile(BANNER):
            # banner.png (1920x86): arte pronta, centralizada e cortada pra caber em qualquer tela
            ban.get_style_context().add_class("banner-img")
            for c in ban.get_children(): ban.remove(c)
        else:
            ban.set_center_widget(inner)       # sem imagem: gradiente + logo + texto
        root.pack_start(ban, False, False, 0)

        # ---- miolo: título + caixa branca
        body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        body.set_halign(Gtk.Align.CENTER); body.set_size_request(860, -1)
        body.set_margin_top(22); body.set_margin_bottom(10)
        self.title = Gtk.Label(xalign=0); self.title.get_style_context().add_class("page-title")
        body.pack_start(self.title, False, False, 0)
        self.frame = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        self.frame.get_style_context().add_class("box")
        body.pack_start(self.frame, True, True, 0)
        self.err = Gtk.Label(xalign=0, wrap=True); self.err.get_style_context().add_class("err")
        body.pack_start(self.err, False, False, 0)
        root.pack_start(body, True, True, 0)

        # ---- rodapé: Sair | Voltar Continuar
        bar = Gtk.Box(spacing=8); bar.set_halign(Gtk.Align.CENTER); bar.set_size_request(860, -1)
        bar.set_margin_bottom(22)
        self.b_quit = Gtk.Button(label="Sair")
        self.b_back = Gtk.Button(label="Voltar")
        self.b_next = Gtk.Button(label="Continuar"); self.b_next.get_style_context().add_class("go")
        self.b_quit.connect("clicked", lambda *_: self.quit())
        self.b_back.connect("clicked", lambda *_: self.go(-1))
        self.b_next.connect("clicked", lambda *_: self.go(+1))
        bar.pack_start(self.b_quit, False, False, 0)
        bar.pack_end(self.b_next, False, False, 0)
        bar.pack_end(self.b_back, False, False, 0)
        root.pack_end(bar, False, False, 0)

        self.pages = [self.p_welcome, self.p_disk, self.p_user, self.p_locale, self.p_confirm]
        self.idx = 0
        self.show_page()

    # ------------------------------------------------------------- util
    def set_content(self, title, widget):
        for c in self.frame.get_children():
            self.frame.remove(c)
        self.title.set_text(title)
        self.frame.pack_start(widget, True, True, 0)
        self.frame.show_all()
        self.err.set_text("")

    def label(self, text, markup=False, hint=False):
        l = Gtk.Label(xalign=0, yalign=0, wrap=True)
        l.set_markup(text) if markup else l.set_text(text)
        if hint: l.get_style_context().add_class("hint")
        l.set_max_width_chars(70)           # quebra linha em vez de alargar a janela
        return l

    def vbox(self, spacing=10):
        return Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=spacing)

    def quit(self):
        if not self.busy:
            Gtk.main_quit()

    # ------------------------------------------------------ navegação
    def show_page(self):
        self.pages[self.idx]()
        last = self.idx == len(self.pages) - 1
        self.b_back.set_sensitive(self.idx > 0)
        self.b_next.set_label("Instalar" if last else "Continuar")
        ctx = self.b_next.get_style_context()
        ctx.remove_class("danger"); ctx.remove_class("go")
        ctx.add_class("danger" if last else "go")

    def go(self, d):
        if d > 0:
            e = self.validate()
            if e:
                self.err.set_text(e); return
            self.collect()
            if self.idx == len(self.pages) - 1:
                self.start_install(); return
        self.idx = max(0, min(len(self.pages) - 1, self.idx + d))
        self.show_page()

    def collect(self):
        i = self.idx
        if i == 1:
            m, it = self.tree.get_selection().get_selected()
            if it: self.st["disk"] = m[it][0]
        elif i == 2:
            self.st["name"] = self.e_name.get_text().strip()
            self.st["user"] = self.e_user.get_text().strip()
            self.st["pw"] = self.e_pw.get_text()
            if self.chk_same.get_active(): self.st["rootmode"] = "same"; self.st["rootpw"] = ""
            elif self.e_rpw.get_text(): self.st["rootmode"] = "own"; self.st["rootpw"] = self.e_rpw.get_text()
            else: self.st["rootmode"] = "lock"; self.st["rootpw"] = ""
        elif i == 3:
            self.st["keymap"] = KEYMAPS[self.c_key.get_active()][0]
            self.st["tz"] = TZS[self.c_tz.get_active()][0]
        elif i == 4:
            self.st["autologin"] = self.chk.get_active()

    def validate(self):
        i = self.idx
        if i == 1:
            m, it = self.tree.get_selection().get_selected()
            if not it: return "Escolha um disco."
        if i == 2:
            u = self.e_user.get_text().strip()
            if not re.fullmatch(r"[a-z_][a-z0-9_-]{0,31}", u) or u == "root":
                return "Usuário inválido: use minúsculas, números, - e _ (começando por letra)."
            if not self.e_pw.get_text(): return "A senha não pode ser vazia."
            if self.e_pw.get_text() != self.e_pw2.get_text(): return "As senhas não batem."
            nm = self.e_name.get_text().strip()
            if len(nm) > 60: return "Nome completo grande demais (máx 60)."
            if re.search(r"[:,=\x00-\x1f]", nm): return "Nome completo: não pode ter  :  ,  =  nem caracteres de controle."
            if not self.chk_same.get_active() and self.e_rpw.get_text() != self.e_rpw2.get_text():
                return "As senhas do root não batem."
        return None

    # ----------------------------------------------------------- páginas
    def p_welcome(self):
        h = Gtk.Box(spacing=24)
        try:
            pb = GdkPixbuf.Pixbuf.new_from_file_at_size(LOGO, 150, 150)
            img = Gtk.Image.new_from_pixbuf(pb); img.set_valign(Gtk.Align.START)
            h.pack_start(img, False, False, 0)
        except Exception:
            pass
        v = self.vbox(12)
        v.pack_start(self.label("<big><b>Bem-vindo ao UniBan %s</b></big>" % VERSION, markup=True), False, False, 0)
        v.pack_start(self.label(
            "Este assistente instala o UniBan no seu computador. Não precisa de internet.\n\n"
            "Você vai escolher: disco, usuário e senha, teclado e fuso horário.\n\n"
            "O disco escolhido será totalmente apagado. Se quiser só testar o sistema "
            "sem instalar, clique em Sair."), False, False, 0)
        h.pack_start(v, True, True, 0)
        self.set_content("Instalar o UniBan", h)

    def p_disk(self):
        v = self.vbox()
        v.pack_start(self.label("Escolha o disco onde instalar. TUDO nele será apagado."), False, False, 0)
        store = Gtk.ListStore(str, str, str)
        for d in list_disks(): store.append(d)
        self.tree = Gtk.TreeView(model=store)
        for n, title in enumerate(("Disco", "Tamanho", "Modelo")):
            self.tree.append_column(Gtk.TreeViewColumn(title, Gtk.CellRendererText(), text=n))
        sel = self.tree.get_selection()
        # mantém a escolha se voltou nessa página
        for row in store:
            if row[0] == self.st["disk"]: sel.select_iter(row.iter)
        if not sel.get_selected()[1] and len(store): sel.select_path(0)
        sw = Gtk.ScrolledWindow(); sw.set_min_content_height(240); sw.add(self.tree)
        v.pack_start(sw, True, True, 0)
        if not len(store):
            v.pack_start(self.label("Nenhum disco disponível.", hint=True), False, False, 0)
        self.set_content("Escolha o disco", v)

    def p_user(self):
        g = Gtk.Grid(row_spacing=9, column_spacing=14)
        st = self.st
        self.e_name = Gtk.Entry(text=st["name"], hexpand=True)
        self.e_user = Gtk.Entry(text=st["user"], hexpand=True)
        self.e_pw = Gtk.Entry(visibility=False, text=st["pw"], hexpand=True)
        self.e_pw2 = Gtk.Entry(visibility=False, text=st["pw"], hexpand=True)
        self.e_rpw = Gtk.Entry(visibility=False, text=st["rootpw"], hexpand=True)
        self.e_rpw2 = Gtk.Entry(visibility=False, text=st["rootpw"], hexpand=True)
        self.chk_same = Gtk.CheckButton(label="Usar a senha do usuário como senha do root")
        self.chk_same.set_active(st["rootmode"] == "same")
        self.login_touched = bool(st["user"]) and st["user"] != suggest_login(st["name"])

        def on_name(_e):               # sugere o login a partir do nome (até você mexer no login)
            if not self.login_touched: self.e_user.set_text(suggest_login(self.e_name.get_text()))
        def on_login(_e):
            if self.e_user.get_text() != suggest_login(self.e_name.get_text()): self.login_touched = True
        def on_same(_c):
            on = not self.chk_same.get_active()
            self.e_rpw.set_sensitive(on); self.e_rpw2.set_sensitive(on)
        self.e_name.connect("changed", on_name); self.e_user.connect("changed", on_login)
        self.chk_same.connect("toggled", on_same); on_same(None)

        rows = (("Seu nome:", self.e_name), ("Nome de usuário (login):", self.e_user),
                ("Senha:", self.e_pw), ("Repita a senha:", self.e_pw2))
        for r, (t, w) in enumerate(rows):
            g.attach(self.label(t), 0, r, 1, 1); g.attach(w, 1, r, 1, 1)
        g.attach(self.label("Nome pode ter espaço, acento e maiúscula. Login não: só minúsculas, números, - e _ (regra do Linux).", hint=True), 1, 4, 1, 1)
        g.attach(Gtk.Separator(), 0, 5, 2, 1)
        g.attach(self.chk_same, 0, 6, 2, 1)
        g.attach(self.label("Senha do root:"), 0, 7, 1, 1); g.attach(self.e_rpw, 1, 7, 1, 1)
        g.attach(self.label("Repita a senha do root:"), 0, 8, 1, 1); g.attach(self.e_rpw2, 1, 8, 1, 1)
        g.attach(self.label("Root sem senha = conta bloqueada (recomendado: use sudo com a senha do usuário).", hint=True), 1, 9, 1, 1)
        self.set_content("Crie o seu usuário", g)

    def p_locale(self):
        g = Gtk.Grid(row_spacing=12, column_spacing=14)
        self.c_key, self.c_tz = Gtk.ComboBoxText(hexpand=True), Gtk.ComboBoxText(hexpand=True)
        for k, n in KEYMAPS: self.c_key.append_text(n)
        for k, n in TZS: self.c_tz.append_text(n)
        self.c_key.set_active([k for k, _ in KEYMAPS].index(self.st["keymap"]))
        self.c_tz.set_active([k for k, _ in TZS].index(self.st["tz"]))
        g.attach(self.label("Layout do teclado:"), 0, 0, 1, 1); g.attach(self.c_key, 1, 0, 1, 1)
        g.attach(self.label("Fuso horário:"), 0, 1, 1, 1); g.attach(self.c_tz, 1, 1, 1, 1)
        self.set_content("Teclado e fuso horário", g)

    def p_confirm(self):
        v = self.vbox(14)
        s = self.st
        v.pack_start(self.label(
            "<b>Resumo</b>\n\nDisco: <b>%s</b>\nNome: <b>%s</b>   Usuário: <b>%s</b>\nRoot: <b>%s</b>\nTeclado: <b>%s</b>   Fuso: <b>%s</b>"
            % (GLib.markup_escape_text(s["disk"]), GLib.markup_escape_text(s["name"] or s["user"]),
               GLib.markup_escape_text(s["user"]),
               {"same": "mesma senha do usuário", "own": "senha própria", "lock": "bloqueado (use sudo)"}[s["rootmode"]],
               s["keymap"], s["tz"]), markup=True), False, False, 0)
        self.chk = Gtk.CheckButton(label="Entrar direto no desktop, sem pedir senha (como na ISO live)")
        self.chk.set_active(s["autologin"])
        v.pack_start(self.chk, False, False, 0)
        w = self.label("<span foreground='#b00020'><b>Atenção:</b> tudo em %s será APAGADO ao clicar em Instalar.</span>"
                       % GLib.markup_escape_text(s["disk"]), markup=True)
        v.pack_start(w, False, False, 0)
        self.set_content("Pronto para instalar", v)

    # --------------------------------------------------------- instalação
    def start_install(self):
        self.busy = True
        for b in (self.b_quit, self.b_back, self.b_next): b.set_visible(False)   # sem botão durante a instalação
        v = self.vbox(16)
        self.step = self.label("Preparando...")
        self.bar = Gtk.ProgressBar(); self.bar.set_show_text(True)
        self.shown = 0; self.target = 0; self.tick_n = 0
        self.draw_bar()
        v.pack_start(self.step, False, False, 0)
        v.pack_start(self.bar, False, False, 0)
        v.pack_start(self.label("Aguarde, não desligue o computador.", hint=True), False, False, 0)
        self.set_content("Instalando o UniBan", v)
        GLib.timeout_add(50, self.tick)

        s = self.st
        fd, path = tempfile.mkstemp(prefix="uniban-")
        with os.fdopen(fd, "w") as f:
            rpw = s["pw"] if s["rootmode"] == "same" else s["rootpw"]
            f.write("DISK=%s\nUSERNAME=%s\nFULLNAME=%s\nPASSWORD=%s\nROOT_PASSWORD=%s\nKEYMAP=%s\nTZ=%s\nAUTOLOGIN=%d\nREMOVE_INSTALLER=0\n" % (
                shlex.quote(s["disk"]), shlex.quote(s["user"]), shlex.quote(s["name"]), shlex.quote(s["pw"]), shlex.quote(rpw),
                shlex.quote(s["keymap"]), shlex.quote(s["tz"]), 1 if s["autologin"] else 0))
        os.chmod(path, 0o600)
        self.proc = subprocess.Popen(["sudo", "-n", "/usr/bin/uniban-install", "--gui", "-c", path],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.STDOUT, text=True, bufsize=1)
        threading.Thread(target=self.reader, args=(path,), daemon=True).start()

    # marcas fixas do backend fora da cópia (a cópia manda 1 marca por 1%)
    MARKS = (1, 3, 5, 85, 86, 91, 94, 95, 99, 100)

    def draw_bar(self):
        self.bar.set_fraction(self.shown / 100.0)
        self.bar.set_text("%d%%" % self.shown)

    def tick(self):
        """Barra anda 1% por vez (nunca pula, nunca volta). Em etapa longa sem
        marca (initramfs/GRUB) rasteja +1% a cada ~1,5 s, parando 1% antes da
        próxima marca - sem prometer o que o backend ainda não fez."""
        self.tick_n += 1
        if self.shown < self.target:
            self.shown += 1; self.draw_bar()
        elif self.shown < 99 and self.tick_n % 30 == 0:
            nxt = min([m for m in self.MARKS if m > self.target] or [100])
            if self.shown < nxt - 1 and self.target not in range(5, 85):
                self.shown += 1; self.draw_bar()
        return self.busy or self.shown < self.target

    def reader(self, path):
        tail = []
        for line in self.proc.stdout:
            line = line.rstrip("\n")
            if line.startswith("@STEP "):
                GLib.idle_add(self.on_step, line[6:])
            elif line.startswith("@PCT "):
                GLib.idle_add(self.on_pct, line[5:])
            elif line.startswith("@ASK_REMOVE "):
                GLib.idle_add(self.on_ask, line.split()[1])
            elif line.strip():
                tail.append(line); tail = tail[-8:]
        rc = self.proc.wait()
        try: os.unlink(path)
        except OSError: pass
        GLib.idle_add(self.on_done, rc, "\n".join(tail))

    def on_step(self, txt):
        self.step.set_text(txt)

    def on_pct(self, p):
        try: self.target = max(self.target, min(100, int(p)))
        except ValueError: pass

    def on_ask(self, kb):
        self.busy = True; self.target = self.shown = 100
        v = self.vbox(14)
        v.pack_start(self.label("<big><b>Instalação finalizada!</b></big>\n\nDeseja desinstalar o instalador?", markup=True), False, False, 0)
        v.pack_start(self.label(
            "Espaço em disco: <b>%s</b>\nRAM em uso: <b>0 MB</b> com ele fechado (<b>%s</b> enquanto este assistente está aberto)\n\n"
            "O instalador só gasta RAM enquanto está aberto. Se remover, para reinstalar vai precisar da ISO."
            % (fmt_size(kb), fmt_size(my_rss_kb())), markup=True), False, False, 0)
        row = Gtk.Box(spacing=10)
        keep = Gtk.Button(label="Manter instalador"); rem = Gtk.Button(label="Desinstalar instalador")
        keep.connect("clicked", lambda *_: self.answer("no")); rem.connect("clicked", lambda *_: self.answer("yes"))
        row.pack_start(keep, False, False, 0); row.pack_start(rem, False, False, 0)
        v.pack_start(row, False, False, 0)
        self.set_content("Instalação finalizada", v)

    def answer(self, a):
        try:
            self.proc.stdin.write(a + "\n"); self.proc.stdin.flush()
        except OSError:
            pass
        v = self.vbox(); v.pack_start(self.label("Finalizando..."), False, False, 0)
        self.set_content("Instalando o UniBan", v)

    def on_done(self, rc, tail):
        self.busy = False
        v = self.vbox(14)
        if rc == 0:
            v.pack_start(self.label("<big><b>Tudo pronto!</b></big>\n\nRemova o pendrive/DVD e reinicie o computador.", markup=True), False, False, 0)
            row = Gtk.Box(spacing=10)
            rb = Gtk.Button(label="Reiniciar agora"); rb.get_style_context().add_class("danger")
            lb = Gtk.Button(label="Continuar no sistema live")
            rb.connect("clicked", lambda *_: (subprocess.Popen(["systemctl", "reboot"]), None))
            lb.connect("clicked", lambda *_: Gtk.main_quit())
            row.pack_start(rb, False, False, 0); row.pack_start(lb, False, False, 0)
            v.pack_start(row, False, False, 0)
            self.set_content("Instalação concluída", v)
        else:
            v.pack_start(self.label("<big><b>A instalação falhou.</b></big>\n\nNada foi perdido além do disco escolhido. Log: /var/log/uniban-install.log", markup=True), False, False, 0)
            v.pack_start(self.label(tail), False, False, 0)
            self.set_content("Erro", v)
        if rc != 0:
            self.b_quit.set_visible(True); self.b_quit.set_sensitive(True)   # erro: deixa sair


def main():
    css = CSS
    if os.path.isfile(BANNER):
        css += (".banner-img { background-image: url(\"file://%s\"); }\n" % BANNER).encode()
    prov = Gtk.CssProvider(); prov.load_from_data(css)
    Gtk.StyleContext.add_provider_for_screen(Gdk.Screen.get_default(), prov,
                                             Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
    w = Installer(); w.show_all()
    Gtk.main()


if __name__ == "__main__":
    main()
