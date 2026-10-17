
#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

# ============================================================
# RASPBERRY CONTROL
# Instalador del bot de Telegram
# ============================================================

APP_NAME="raspberry-control"
APP_USER="raspberry-control"
APP_DIR="/opt/raspberry-control"
CONFIG_DIR="/etc/raspberry-control"
CONFIG_FILE="$CONFIG_DIR/bot.env"
STATE_DIR="/var/lib/raspberry-control"
SERVICE_NAME="raspberry-control-bot.service"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

log() {
    echo
    echo "[$APP_NAME] $*"
}

die() {
    echo
    echo "ERROR: $*" >&2
    exit 1
}

# ------------------------------------------------------------
# 1. Comprobaciones iniciales
# ------------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
    die "Ejecuta el instalador con: sudo bash install.sh"
fi

[[ -f "$SCRIPT_DIR/bot.py" ]] ||
    die "No se encuentra bot.py en el repositorio."

[[ -f "$SCRIPT_DIR/$SERVICE_NAME" ]] ||
    die "No se encuentra $SERVICE_NAME en el repositorio."

command -v apt-get >/dev/null 2>&1 ||
    die "Este instalador requiere Raspberry Pi OS o Debian."

command -v systemctl >/dev/null 2>&1 ||
    die "No se encontró systemctl. Se necesita un sistema con systemd."

if [[ -e "$CONFIG_FILE" && ! -f "$CONFIG_FILE" ]]; then
    die "$CONFIG_FILE existe, pero no es un archivo regular."
fi

log "Iniciando instalación..."

# ------------------------------------------------------------
# 2. Instalar dependencias del sistema
# ------------------------------------------------------------

export DEBIAN_FRONTEND=noninteractive

log "Actualizando paquetes..."

apt-get update

log "Instalando dependencias..."

apt-get install -y \
    ca-certificates \
    curl \
    git \
    golang-go \
    openssh-client \
    python3 \
    python3-venv \
    python3-pip \
    sudo

# ------------------------------------------------------------
# 3. Crear usuario de servicio
# ------------------------------------------------------------

log "Preparando usuario y directorios..."

if ! id "$APP_USER" >/dev/null 2>&1; then
    useradd \
        --system \
        --home-dir "$APP_DIR" \
        --no-create-home \
        --shell /usr/sbin/nologin \
        "$APP_USER"
fi

install -d -o root -g root -m 755 "$APP_DIR"

install -d \
    -o root \
    -g "$APP_USER" \
    -m 750 \
    "$CONFIG_DIR"

install -d \
    -o "$APP_USER" \
    -g "$APP_USER" \
    -m 750 \
    "$STATE_DIR"

# ------------------------------------------------------------
# 4. Instalar el código del bot
# ------------------------------------------------------------

log "Copiando bot.py..."

install -o root -g root -m 644 \
    "$SCRIPT_DIR/bot.py" \
    "$APP_DIR/bot.py"

# ------------------------------------------------------------
# 5. Crear entorno virtual de Python
# ------------------------------------------------------------

log "Preparando entorno virtual..."

if [[ ! -x "$APP_DIR/venv/bin/python" ]]; then
    python3 -m venv "$APP_DIR/venv"
fi

"$APP_DIR/venv/bin/python" -m pip install \
    --upgrade pip

"$APP_DIR/venv/bin/python" -m pip install \
    "python-telegram-bot>=20,<23"

# ------------------------------------------------------------
# 6. Configurar credenciales de Telegram
# ------------------------------------------------------------

if [[ ! -f "$CONFIG_FILE" ]]; then
    log "Configuración inicial de Telegram"

    echo "Crea u obtén el token con @BotFather."
    echo "El token se guardará solamente en esta Raspberry Pi."
    echo

    while true; do
        read -r -s -p "Token del bot: " BOT_TOKEN
        echo

        if [[ -n "$BOT_TOKEN" &&
              "$BOT_TOKEN" != *$'\n'* &&
              "$BOT_TOKEN" != *$'\r'* &&
              "$BOT_TOKEN" != *$'\t'* ]]; then
            break
        fi

        echo "Token vacío o inválido. Inténtalo de nuevo."
    done

    while true; do
        read -r -p "ID numérico autorizado de Telegram: " USER_ID

        if [[ "$USER_ID" =~ ^[0-9]+$ ]]; then
            break
        fi

        echo "El ID debe contener solo números."
    done

    # No sobrescribir una configuración preexistente.
    if [[ -e "$CONFIG_FILE" ]]; then
        unset BOT_TOKEN USER_ID
        die "El archivo de configuración apareció durante la instalación."
    fi

    TEMP_CONFIG="$(mktemp "$CONFIG_DIR/bot.env.XXXXXX")"

    {
        printf 'TELEGRAM_BOT_TOKEN=%s\n' "$BOT_TOKEN"
        printf 'TELEGRAM_AUTHORIZED_USER_ID=%s\n' "$USER_ID"
    } > "$TEMP_CONFIG"

    chown root:"$APP_USER" "$TEMP_CONFIG"
    chmod 640 "$TEMP_CONFIG"

    mv "$TEMP_CONFIG" "$CONFIG_FILE"

    unset BOT_TOKEN USER_ID TEMP_CONFIG

else
    log "Validando configuración existente..."

    if ! grep -q '^TELEGRAM_BOT_TOKEN=.' "$CONFIG_FILE"; then
        die "Falta TELEGRAM_BOT_TOKEN en $CONFIG_FILE."
    fi

    if ! grep -Eq '^TELEGRAM_AUTHORIZED_USER_ID=[0-9]+$' \
        "$CONFIG_FILE"; then
        die "TELEGRAM_AUTHORIZED_USER_ID falta o no es numérico."
    fi

    chown root:"$APP_USER" "$CONFIG_FILE"
    chmod 640 "$CONFIG_FILE"

    log "Configuración existente conservada."
fi

# ------------------------------------------------------------
# 7. Instalar el servicio systemd del bot
# ------------------------------------------------------------

log "Instalando servicio systemd..."

install -o root -g root -m 644 \
    "$SCRIPT_DIR/$SERVICE_NAME" \
    "/etc/systemd/system/$SERVICE_NAME"

systemctl daemon-reload

log "Habilitando arranque automático..."

systemctl enable "$SERVICE_NAME"

# ------------------------------------------------------------
# 8. Iniciar el bot
# ------------------------------------------------------------

log "Iniciando el servicio..."

if ! systemctl restart "$SERVICE_NAME"; then
    systemctl --no-pager --full status "$SERVICE_NAME" || true
    journalctl -u "$SERVICE_NAME" -n 40 --no-pager || true
    die "No se pudo iniciar el bot. Revisa el diagnóstico anterior."
fi

sleep 2

if ! systemctl is-active --quiet "$SERVICE_NAME"; then
    systemctl --no-pager --full status "$SERVICE_NAME" || true
    journalctl -u "$SERVICE_NAME" -n 40 --no-pager || true
    die "El servicio no está activo. Revisa los registros."
fi

# ------------------------------------------------------------
# 9. Resumen final
# ------------------------------------------------------------

log "INSTALACIÓN DEL BOT COMPLETADA"

echo
echo "Servicio: $SERVICE_NAME"
echo "Directorio: $APP_DIR"
echo "Configuración: $CONFIG_FILE"
echo "Arranque automático: habilitado"
echo "Estado: $(systemctl is-active "$SERVICE_NAME")"

echo
echo "Comandos útiles:"
echo "  sudo systemctl status $SERVICE_NAME"
echo "  sudo journalctl -u $SERVICE_NAME -f"
echo "  sudo systemctl restart $SERVICE_NAME"
echo "  sudo systemctl is-enabled $SERVICE_NAME"

echo
echo "NOTA:"
echo "Este instalador configura el bot de Telegram."
echo "La instalación y recuperación automática de Upterm"
echo "se integrarán en una siguiente etapa."

echo
echo "No compartas el token del bot ni lo subas a GitHub."
