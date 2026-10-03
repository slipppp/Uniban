#!/bin/sh
# UniBan - atualizador via GitHub Releases
#
# Fluxo: detecta versão instalada -> consulta última release -> compara ->
#        baixa -> valida -> faz backup -> aplica -> (falhou? desfaz).
#
# O que ele atualiza: SÓ arquivos gerenciados do UniBan (lista PATHS abaixo:
# scripts/logo/wallpaper em /usr/share/uniban etc). NÃO mexe em pacotes
# Debian, config do usuário nem no autologin (o instalador pode ter mudado).
# Mudança em hook/pacote precisa de ISO nova - isso não dá pra aplicar
# num sistema instalado.
#
# Formato aceito (nessa ordem):
#   1) asset da release "uniban-update*.tar.gz" (layout da raiz: usr/ etc/ ...)
#      validado por sha256 (campo "digest" da API ou asset "*.sha256").
#   2) fallback: tarball do código-fonte da tag (config/includes.chroot/...).
#      GitHub não publica hash disso -> só validação estrutural + aviso.
#
# Uso: uniban-update [--check] [-y]
#   --check  só mostra se tem versão nova
#   -y       não pergunta antes de aplicar
#
# Variáveis (só pra teste): UNIBAN_API, UNIBAN_ROOT

REPO="slipppp/Uniban"
API="${UNIBAN_API:-https://api.github.com/repos/$REPO/releases/latest}"
ROOT="${UNIBAN_ROOT:-}"                       # prefixo do sistema alvo ("" = real)
VERFILE="$ROOT/usr/share/uniban/version"
STATE="$ROOT/var/lib/uniban"

# Só estes caminhos (relativos à raiz do sistema) são aceitos de um update.
# Tudo fora daqui é descartado na validação.
PATHS="usr/share/uniban/ usr/share/backgrounds/uniban/ usr/share/applications/uniban- etc/xdg/autostart/uniban- etc/lightdm/lightdm-gtk-greeter.conf.d/60-uniban- usr/bin/uniban-"

TMP=""
BACKUP=""
NEWLIST=""

say()  { printf '[uniban-update] %s\n' "$*"; }
err()  { printf '[uniban-update] ERRO: %s\n' "$*" >&2; }
cleanup() { [ -n "$TMP" ] && [ -d "$TMP" ] && rm -rf "$TMP"; }

# versão "UnibanV0.2" / "v0.2" / "0.2" -> "0.2". Sem número -> vazio.
norm_ver() {
  printf '%s' "$1" | sed -n 's/^[^0-9]*\([0-9][0-9.]*[0-9]\).*$/\1/p; t; s/^[^0-9]*\([0-9]\)$/\1/p'
}

# $1 > $2 ? (sort -V: o maior fica por último)
ver_gt() {
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$1" ]
}

path_ok() {
  for p in $PATHS; do
    case "$1" in "$p"*) return 0 ;; esac
  done
  return 1
}

# pega valor de uma chave JSON (a API do GitHub vem indentada, 1 chave/linha)
json_first() { sed -n "s/^ *\"$1\": *\"\([^\"]*\)\".*/\1/p" | head -n 1; }

# ---------------------------------------------------------------- rede
fetch() {  # fetch URL DEST  (mostra barra de progresso)
  curl -fL --retry 2 --connect-timeout 15 --progress-bar -o "$2" "$1"
}

# ------------------------------------------------------------ validação
# lista o tar, rejeita caminho perigoso e tipo estranho (link/device).
# imprime o prefixo de topo a remover (strip) em $TMP/strip
validate_tar() {
  tar="$1"
  gzip -t "$tar" 2>/dev/null || { err "arquivo corrompido (gzip -t falhou)"; return 1; }
  tar -tzvf "$tar" > "$TMP/list.v" 2>/dev/null || { err "tar ilegível"; return 1; }
  tar -tzf  "$tar" > "$TMP/list.n" 2>/dev/null || { err "tar ilegível"; return 1; }

  # só arquivo regular (-) e diretório (d). link/hardlink/device = rejeita
  if cut -c1 "$TMP/list.v" | grep -qv '^[-d]$'; then
    err "update contém link/dispositivo - rejeitado"
    return 1
  fi
  if grep -qE '(^/|(^|/)\.\.(/|$))' "$TMP/list.n"; then
    err "update contém caminho absoluto ou '..' - rejeitado"
    return 1
  fi
  [ -s "$TMP/list.n" ] || { err "update vazio"; return 1; }
  return 0
}

# ------------------------------------------------------- backup/rollback
rollback() {
  err "falhou - desfazendo..."
  if [ -n "$BACKUP" ] && [ -f "$BACKUP" ]; then
    tar -C "${ROOT:-/}" -xzpf "$BACKUP" 2>/dev/null && say "arquivos antigos restaurados"
  fi
  if [ -n "$NEWLIST" ] && [ -f "$NEWLIST" ]; then
    while IFS= read -r f; do rm -f "${ROOT:-}/$f"; done < "$NEWLIST"
  fi
}

# ------------------------------------------------------------------ main
main() {
  CHECK=0; YES=0
  for a in "$@"; do
    case "$a" in
      --check) CHECK=1 ;;
      -y|--yes) YES=1 ;;
      -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; return 0 ;;
      *) err "opção desconhecida: $a"; return 2 ;;
    esac
  done

  for t in curl tar gzip sha256sum sort sed; do
    command -v "$t" >/dev/null 2>&1 || { err "falta '$t' (apt install $t)"; return 1; }
  done

  # root só é necessário pra aplicar
  if [ "$CHECK" -eq 0 ] && [ -z "$UNIBAN_ROOT" ] && [ "$(id -u)" -ne 0 ]; then
    exec sudo "$0" "$@"
  fi

  TMP="$(mktemp -d)" || { err "mktemp falhou"; return 1; }
  trap cleanup EXIT INT TERM

  # 1) versão instalada
  CUR="$(norm_ver "$(cat "$VERFILE" 2>/dev/null)")"
  [ -n "$CUR" ] || { err "versão instalada não encontrada em $VERFILE"; return 1; }
  say "versão instalada: $CUR"
  if grep -qs 'boot=live' /proc/cmdline 2>/dev/null; then
    say "aviso: sessão live - mudanças somem ao reiniciar (instale antes)"
  fi

  # 2) última release
  say "consultando $API"
  if ! curl -fsSL --connect-timeout 15 -H 'Accept: application/vnd.github+json' \
        -o "$TMP/rel.json" "$API"; then
    err "não consegui acessar GitHub (sem internet? limite da API?)"
    return 1
  fi
  TAG="$(json_first tag_name < "$TMP/rel.json")"
  [ -n "$TAG" ] || { err "resposta da API sem tag_name"; return 1; }
  NEW="$(norm_ver "$TAG")"
  [ -n "$NEW" ] || { err "tag '$TAG' sem número de versão"; return 1; }
  say "última release: $NEW (tag $TAG)"

  # 3) compara
  if ! ver_gt "$NEW" "$CUR"; then
    say "já está atualizado."
    return 0
  fi
  say "versão nova disponível: $CUR -> $NEW"
  [ "$CHECK" -eq 1 ] && return 0

  # 4) escolhe o que baixar
  URL="$(sed -n 's/^ *"browser_download_url": *"\([^"]*uniban-update[^"\/]*\.tar\.gz\)".*/\1/p' \
         "$TMP/rel.json" | head -n 1)"
  SHA=""
  if [ -n "$URL" ]; then
    # digest da API: na ordem real do GitHub vem ANTES do browser_download_url
    # do mesmo asset ("name" abre o asset -> zera). Senão, asset .sha256 irmão.
    SHA="$(awk -v u="$URL" '
      /"name":/   { last = "" }
      /"digest":/ { d = $0; sub(/.*sha256:/, "", d); sub(/".*/, "", d); last = d }
      /"browser_download_url":/ { if (index($0, u) && last != "") { print last; exit } }
    ' "$TMP/rel.json")"
    case "$SHA" in *[!0-9a-f]*) SHA="" ;; esac
    [ "${#SHA}" -eq 64 ] || SHA=""
    if [ -z "$SHA" ]; then
      if curl -fsSL "$URL.sha256" -o "$TMP/asset.sha256" 2>/dev/null; then
        SHA="$(grep -o '[0-9a-f]\{64\}' "$TMP/asset.sha256" | head -n 1)"
      fi
    fi
    [ -n "$SHA" ] || { err "asset de update sem sha256 - não vou aplicar sem validar"; return 1; }
  else
    URL="$(json_first tarball_url < "$TMP/rel.json")"
    [ -n "$URL" ] || { err "release sem asset de update nem tarball_url"; return 1; }
    say "aviso: release sem asset uniban-update*.tar.gz - uso o código-fonte da tag (sem checksum publicado)"
  fi

  if [ "$YES" -eq 0 ]; then
    printf '[uniban-update] aplicar %s? [s/N] ' "$NEW"
    read -r ans
    case "$ans" in s|S|y|Y) ;; *) say "cancelado."; return 0 ;; esac
  fi

  # 5) baixa
  say "baixando..."
  fetch "$URL" "$TMP/update.tar.gz" || { err "download falhou"; return 1; }

  # 6) valida
  say "validando..."
  if [ -n "$SHA" ]; then
    GOT="$(sha256sum "$TMP/update.tar.gz" | cut -d' ' -f1)"
    if [ "$GOT" != "$SHA" ]; then
      err "sha256 não confere (esperado $SHA, veio $GOT) - NADA foi alterado"
      return 1
    fi
    say "sha256 ok"
  fi
  validate_tar "$TMP/update.tar.gz" || return 1

  mkdir "$TMP/stage"
  tar -C "$TMP/stage" -xzf "$TMP/update.tar.gz" 2>/dev/null || { err "extração falhou"; return 1; }

  # acha a raiz do overlay: fonte da tag (*/config/includes.chroot) ou layout direto
  OV=""
  for d in "$TMP"/stage/*/config/includes.chroot "$TMP"/stage/config/includes.chroot "$TMP/stage"; do
    if [ -d "$d" ] && { [ -d "$d/usr" ] || [ -d "$d/etc" ]; }; then OV="$d"; break; fi
  done
  [ -n "$OV" ] || { err "update sem usr/ ou etc/ - formato desconhecido"; return 1; }

  # lista só arquivos permitidos; descarta o resto
  ( cd "$OV" && find . -type f | sed 's|^\./||' ) | while IFS= read -r f; do
    path_ok "$f" || continue
    # instalador removido pelo usuário (marca .no-installer): não traz de volta
    case "$f" in *uniban-install*) [ -e "${ROOT:-}/usr/share/uniban/.no-installer" ] && continue ;; esac
    printf '%s\n' "$f"
  done > "$TMP/apply.list"
  [ -s "$TMP/apply.list" ] || { err "update sem nenhum arquivo permitido"; return 1; }
  say "$(wc -l < "$TMP/apply.list") arquivo(s) a atualizar"

  # 7) backup (só o que já existe) + lista do que é novo
  mkdir -p "$STATE" || { err "sem permissão em $STATE"; return 1; }
  BACKUP="$STATE/backup-$CUR.tar.gz"
  NEWLIST="$STATE/new-files.list"
  : > "$TMP/exist.list"; : > "$NEWLIST"
  while IFS= read -r f; do
    if [ -e "${ROOT:-}/$f" ]; then printf '%s\n' "$f" >> "$TMP/exist.list"
    else printf '%s\n' "$f" >> "$NEWLIST"; fi
  done < "$TMP/apply.list"
  if [ -s "$TMP/exist.list" ]; then
    tar -C "${ROOT:-/}" -czpf "$BACKUP" -T "$TMP/exist.list" || { err "backup falhou - nada alterado"; return 1; }
  else
    tar -czf "$BACKUP" -T /dev/null
  fi
  say "backup: $BACKUP"

  # 8) aplica (tar remove+recria cada arquivo: este script em execução não quebra)
  say "aplicando..."
  if ! tar -C "$OV" -cf - -T "$TMP/apply.list" | tar -C "${ROOT:-/}" -xpf - ; then
    rollback; return 1
  fi
  # scripts do UniBan precisam de +x (zip/GitHub nem sempre preserva)
  for f in $(grep -E '^usr/share/uniban/.*\.sh$|^usr/bin/uniban-' "$TMP/apply.list"); do
    chmod 755 "${ROOT:-}/$f" 2>/dev/null
  done

  # 9) confere que o essencial continua legível; marca versão
  for f in $(grep -E '\.sh$' "$TMP/apply.list"); do
    if ! sh -n "${ROOT:-}/$f" 2>/dev/null; then
      err "$f com erro de sintaxe após update"
      rollback; return 1
    fi
  done
  printf '%s\n' "$NEW" > "$VERFILE" || { rollback; return 1; }
  say "ok: atualizado $CUR -> $NEW (backup em $BACKUP)"
  return 0
}

main "$@"
exit $?
