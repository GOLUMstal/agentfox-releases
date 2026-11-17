#!/usr/bin/env bash
# Agent Fox — installer and updater for Linux (Firefox + Claude Code).
#
#   Install:  curl -fsSL https://golumstal.github.io/agentfox-releases/install.sh | bash
#   Update:   agentfox-update          (also run daily by a systemd user timer)
#
# Installs the MCP server + native messaging host under ~/.local/share/agentfox,
# registers them with Firefox and Claude Code, sets up daily auto-updates and
# offers the signed Firefox extension. Needs only curl, tar, sha256sum, Node 18+.
set -euo pipefail

BASE_URL="${AGENTFOX_BASE_URL:-https://golumstal.github.io/agentfox-releases}"
ADDON_ID="agentfox@willow.sh"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/agentfox"
BIN_DIR="$HOME/.local/bin"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
NM_DIR="$HOME/.mozilla/native-messaging-hosts"
POLICY_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/agentfox/policy.json"

MODE=install
[[ "${1:-}" == "--update" ]] && MODE=update

log()  { printf '\033[1;33m[agentfox]\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31m[agentfox] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }
json() { node -e 'const j=JSON.parse(require("fs").readFileSync(0,"utf8")); const v=j[process.argv[1]]; process.stdout.write(v==null?"":String(v))' "$1"; }

# --- requirements -----------------------------------------------------------
for cmd in curl tar sha256sum; do
  command -v "$cmd" >/dev/null || fail "Falta '$cmd'. Instálalo con: sudo dnf install $cmd"
done
if ! command -v node >/dev/null; then
  fail "Falta Node.js. Instálalo con: sudo dnf install nodejs   (y vuelve a ejecutar este instalador)"
fi
NODE_MAJOR=$(node -p 'process.versions.node.split(".")[0]')
(( NODE_MAJOR >= 18 )) || fail "Node.js $NODE_MAJOR es demasiado antiguo; se necesita 18 o superior."

# --- latest release ---------------------------------------------------------
META=$(curl -fsSL --retry 3 "$BASE_URL/server.json?t=$(date +%s)")
VERSION=$(json version <<<"$META")
URL=$(json url <<<"$META")
SHA=$(json sha256 <<<"$META")
XPI_URL=$(json xpi <<<"$META")
[[ -n "$VERSION" && -n "$URL" && -n "$SHA" ]] || fail "No hay ninguna versión publicada todavía."

CURRENT=""
[[ -f "$DATA_DIR/current/package.json" ]] && CURRENT=$(json version < "$DATA_DIR/current/package.json")

if [[ "$CURRENT" == "$VERSION" ]]; then
  log "El servidor ya está en la última versión ($VERSION)."
else
  log "Instalando servidor $VERSION${CURRENT:+ (antes: $CURRENT)}..."
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  curl -fsSL --retry 3 -o "$TMP/server.tar.gz" "$URL"
  echo "$SHA  $TMP/server.tar.gz" | sha256sum -c --quiet - || fail "La suma SHA-256 no coincide; descarga rechazada."
  mkdir -p "$DATA_DIR/versions"
  tar -C "$TMP" -xzf "$TMP/server.tar.gz"
  rm -rf "$DATA_DIR/versions/$VERSION"
  mv "$TMP/agentfox-server-$VERSION" "$DATA_DIR/versions/$VERSION"
  # Atomic switch of the "current" symlink
  ln -sfn "versions/$VERSION" "$DATA_DIR/current.new"
  mv -T "$DATA_DIR/current.new" "$DATA_DIR/current"
  # Keep the two newest versions (a running server may still use the old one)
  ls -1 "$DATA_DIR/versions" | sort -t. -k1,1n -k2,2n -k3,3n | head -n -2 | while read -r old; do
    rm -rf "${DATA_DIR:?}/versions/$old"
  done
  log "Servidor $VERSION instalado. Las sesiones de Claude Code nuevas usarán esta versión."
fi

# --- native messaging host (Firefox) ----------------------------------------
mkdir -p "$NM_DIR"
cat > "$NM_DIR/agentfox.json" <<EOF
{
  "name": "agentfox",
  "description": "Agent Fox native messaging host",
  "path": "$DATA_DIR/current/bin/agentfox-nm-host",
  "type": "stdio",
  "allowed_extensions": ["$ADDON_ID"]
}
EOF

[[ "$MODE" == "update" ]] && exit 0

# ============================================================================
# First-time setup (install mode only)
# ============================================================================

# --- updater command + daily systemd user timer -----------------------------
mkdir -p "$BIN_DIR" "$UNIT_DIR"
cat > "$BIN_DIR/agentfox-update" <<EOF
#!/usr/bin/env bash
exec bash "$DATA_DIR/current/install.sh" --update "\$@"
EOF
chmod +x "$BIN_DIR/agentfox-update"

cat > "$UNIT_DIR/agentfox-update.service" <<EOF
[Unit]
Description=Agent Fox: actualizar servidor MCP y host nativo
After=network-online.target

[Service]
Type=oneshot
ExecStart=$BIN_DIR/agentfox-update
EOF
cat > "$UNIT_DIR/agentfox-update.timer" <<'EOF'
[Unit]
Description=Agent Fox: comprobar actualizaciones a diario

[Timer]
OnBootSec=10min
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
if systemctl --user daemon-reload 2>/dev/null && systemctl --user enable --now agentfox-update.timer >/dev/null 2>&1; then
  log "Actualizaciones automáticas diarias activadas (systemd: agentfox-update.timer)."
else
  log "No se pudo activar el temporizador de systemd; actualiza a mano con: agentfox-update"
fi

# --- default policy ---------------------------------------------------------
if [[ ! -f "$POLICY_FILE" ]]; then
  mkdir -p "$(dirname "$POLICY_FILE")"
  printf '{\n  "blockedDomains": []\n}\n' > "$POLICY_FILE"
fi

# --- Claude Code ------------------------------------------------------------
if command -v claude >/dev/null; then
  claude mcp remove --scope user agentfox >/dev/null 2>&1 || true
  claude mcp add --scope user agentfox -- "$DATA_DIR/current/bin/agentfox-mcp" >/dev/null
  log "Servidor MCP 'agentfox' registrado en Claude Code (ámbito usuario)."
else
  log "Claude Code no está instalado. Cuando lo instales, ejecuta:"
  log "  claude mcp add --scope user agentfox -- $DATA_DIR/current/bin/agentfox-mcp"
fi

# --- Firefox extension ------------------------------------------------------
installed=""
for f in "$HOME"/.mozilla/firefox/*/extensions.json; do
  [[ -f "$f" ]] || continue
  if node -e 'const a=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).addons||[]; process.exit(a.some(x=>x.id===process.argv[2]&&x.location==="app-profile")?0:1)' "$f" "$ADDON_ID"; then
    installed=yes
  fi
done
if [[ -n "$installed" ]]; then
  log "La extensión ya está instalada en Firefox; se actualiza sola."
elif [[ -n "$XPI_URL" ]]; then
  log "Falta la extensión de Firefox. Ábrela y pulsa «Añadir»:"
  log "  $XPI_URL"
  if command -v firefox >/dev/null && [[ -n "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ]]; then
    firefox "$XPI_URL" >/dev/null 2>&1 &
  fi
fi

log "Listo. Abre una sesión nueva de Claude Code para usar Agent Fox."
