
#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

APP_NAME="raspberry-control"
APP_USER="raspberry-control"
APP_DIR="/opt/raspberry-control"
CONFIG_DIR="/etc/raspberry-control"
CONFIG_FILE="$CONFIG_DIR/bot.env"
STATE_DIR="/var/lib/raspberry-control"
BOT_SERVICE="raspberry-control-bot.service"
UPTERM_SERVICE="raspberry-control-upterm.service"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

log() { echo; echo "[$APP_NAME] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Ejecuta: sudo bash install.sh"
[[ -f "$SCRIPT_DIR/bot.py" ]] || die "Falta bot.py"
[[ -f "$SCRIPT_DIR/$BOT_SERVICE" ]] || die "Falta $BOT_SERVICE"
[[ -f "$SCRIPT_DIR/$UPTERM_SERVICE" ]] || die "Falta $UPTERM_SERVICE"

command -v apt-get >/dev/null || die "Se requiere Debian/Raspberry Pi OS."
command -v systemctl >/dev/null || die "Se requiere systemd."

export DEBIAN_FRONTEND=noninteractive

log "Instalando dependencias..."
apt-get update
apt-get install -y \
    ca-certificates \
    git \
    golang-go \
    openssh-client \
    python3 \
    python3-venv \
    python3-pip \
    sudo

log "Preparando usuario y directorios..."
if ! id "$APP_USER" >/dev/null 2>&1; then
    useradd --system --home-dir "$APP_DIR" --no-create-home \
        --shell /usr/sbin/nologin "$APP_USER"
fi

install -d -o root -g root -m 755 "$APP_DIR"
install -d -o root -g "$APP_USER" -m 750 "$CONFIG_DIR"
install -d -o "$APP_USER" -g "$APP_USER" -m 750 "$STATE_DIR"

log "Instalando bot..."
install -o root -g root -m 644 "$SCRIPT_DIR/bot.py" "$APP_DIR/bot.py"

if [[ ! -x "$APP_DIR/venv/bin/python" ]]; then
    python3 -m venv "$APP_DIR/venv"
fi

"$APP_DIR/venv/bin/python" -m pip install --upgrade pip
"$APP_DIR/venv/bin/python" -m pip install "python-telegram-bot>=20,<23"

log "Instalando Upterm..."
GOBIN=/usr/local/bin go install github.com/owenthereal/upterm/cmd/upterm@latest
[[ -x /usr/local/bin/upterm ]] || die "No se encontró /usr/local/bin/upterm"

log "Configurando credenciales de Telegram..."
if [[ ! -f "$CONFIG_FILE" ]]; then
    read -r -s -p "Token del bot de Telegram: " BOT_TOKEN
    echo
    [[ -n "$BOT_TOKEN" ]] || die "Token vacío."

    read -r -p "ID numérico autorizado de Telegram: " USER_ID
    [[ "$USER_ID" =~ ^[0-9]+$ ]] || die "ID no válido."

    TEMP_CONFIG="$(mktemp "$CONFIG_DIR/bot.env.XXXXXX")"
    printf 'TELEGRAM_BOT_TOKEN=%s\nTELEGRAM_AUTHORIZED_USER_ID=%s\n' \
        "$BOT_TOKEN" "$USER_ID" > "$TEMP_CONFIG"

    chown root:"$APP_USER" "$TEMP_CONFIG"
    chmod 640 "$TEMP_CONFIG"
    mv "$TEMP_CONFIG" "$CONFIG_FILE"
    unset BOT_TOKEN USER_ID TEMP_CONFIG
else
    grep -q '^TELEGRAM_BOT_TOKEN=.' "$CONFIG_FILE" ||
        die "Falta TELEGRAM_BOT_TOKEN en $CONFIG_FILE"
    grep -Eq '^TELEGRAM_AUTHORIZED_USER_ID=[0-9]+$' "$CONFIG_FILE" ||
        die "Falta TELEGRAM_AUTHORIZED_USER_ID numérico"
    chown root:"$APP_USER" "$CONFIG_FILE"
    chmod 640 "$CONFIG_FILE"
    log "Se conservaron las credenciales existentes."
fi

log "Configurando clave pública SSH..."
if [[ ! -s "$CONFIG_DIR/authorized_keys" ]]; then
    echo "Pega la línea completa de tu clave PUBLICA SSH."
    echo "Debe comenzar por ssh-ed25519, ssh-rsa o ecdsa-sha2-."
    read -r -p "Clave pública: " PUBLIC_KEY

    [[ "$PUBLIC_KEY" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-[^[:space:]]+)[[:space:]]+[A-Za-z0-9+/=]+([[:space:]].*)?$ ]] ||
        die "Formato de clave pública no válido."

    printf '%s\n' "$PUBLIC_KEY" > "$CONFIG_DIR/authorized_keys"
    unset PUBLIC_KEY
fi

chown root:"$APP_USER" "$CONFIG_DIR/authorized_keys"
chmod 640 "$CONFIG_DIR/authorized_keys"

log "Configurando claves verificadas del servidor Upterm..."
cat > "$CONFIG_DIR/known_hosts" <<'KNOWN_HOSTS'
@cert-authority uptermd.upterm.dev ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICiecex8Dq718eSe1CCLgLvDmI7AagvCtax7brPFWkh4
@cert-authority [uptermd.upterm.dev]:443 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICiecex8Dq718eSe1CCLgLvDmI7AagvCtax7brPFWkh4
KNOWN_HOSTS

chown root:"$APP_USER" "$CONFIG_DIR/known_hosts"
chmod 640 "$CONFIG_DIR/known_hosts"

log "Instalando servicios systemd..."
install -o root -g root -m 644 \
    "$SCRIPT_DIR/$BOT_SERVICE" "/etc/systemd/system/$BOT_SERVICE"
install -o root -g root -m 644 \
    "$SCRIPT_DIR/$UPTERM_SERVICE" "/etc/systemd/system/$UPTERM_SERVICE"

log "Configurando permisos limitados para administrar Upterm..."
SYSTEMCTL="$(command -v systemctl)"
JOURNALCTL="$(command -v journalctl)"
SUDOERS="/etc/sudoers.d/raspberry-control-upterm"

cat > "$SUDOERS" <<EOF
$APP_USER ALL=(root) NOPASSWD: $SYSTEMCTL start $UPTERM_SERVICE, $SYSTEMCTL stop $UPTERM_SERVICE, $SYSTEMCTL is-active $UPTERM_SERVICE, $SYSTEMCTL is-enabled $UPTERM_SERVICE, $JOURNALCTL -u $UPTERM_SERVICE -n 40 --no-pager
EOF

chmod 440 "$SUDOERS"
visudo -cf "$SUDOERS" >/dev/null || die "Configuración sudoers inválida."

systemctl daemon-reload
systemctl enable "$BOT_SERVICE" "$UPTERM_SERVICE"

log "Iniciando Upterm..."
if ! systemctl restart "$UPTERM_SERVICE"; then
    systemctl --no-pager --full status "$UPTERM_SERVICE" || true
    journalctl -u "$UPTERM_SERVICE" -n 40 --no-pager || true
    die "Upterm no pudo arrancar."
fi

log "Iniciando bot..."
if ! systemctl restart "$BOT_SERVICE"; then
    systemctl --no-pager --full status "$BOT_SERVICE" || true
    journalctl -u "$BOT_SERVICE" -n 40 --no-pager || true
    die "El bot no pudo arrancar."
fi

sleep 3
systemctl is-active --quiet "$BOT_SERVICE" ||
    die "El bot no está activo; revisa journalctl."
systemctl is-active --quiet "$UPTERM_SERVICE" ||
    die "Upterm no está activo; revisa journalctl."

log "INSTALACIÓN COMPLETADA"
echo "Bot: $(systemctl is-active "$BOT_SERVICE")"
echo "Upterm: $(systemctl is-active "$UPTERM_SERVICE")"
echo "Arranque automático: habilitado"
echo
echo "Diagnóstico:"
echo "  sudo systemctl status $BOT_SERVICE"
echo "  sudo journalctl -u $BOT_SERVICE -n 50 --no-pager"
echo "  sudo systemctl status $UPTERM_SERVICE"
echo "  sudo journalctl -u $UPTERM_SERVICE -n 50 --no-pager"
echo
echo "No subas claves privadas ni el token de Telegram a GitHub."
