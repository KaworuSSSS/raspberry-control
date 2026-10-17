
#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="raspberry-control"
APP_USER="raspberry-control"
APP_DIR="/opt/raspberry-control"
CONFIG_DIR="/etc/raspberry-control"
CONFIG_FILE="$CONFIG_DIR/bot.env"
SERVICE_NAME="raspberry-control-bot.service"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [[ $EUID -ne 0 ]]; then
    echo "Ejecuta: sudo bash install.sh"
    exit 1
fi

if [[ ! -f "$SCRIPT_DIR/bot.py" ||
      ! -f "$SCRIPT_DIR/raspberry-control-bot.service" ]]; then
    echo "ERROR: ejecuta el instalador desde el repositorio completo."
    exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
    echo "ERROR: se requiere un sistema basado en Debian."
    exit 1
fi

echo "======================================"
echo " RASPBERRY CONTROL - INSTALADOR"
echo "======================================"

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y \
    ca-certificates curl git golang-go \
    openssh-client python3 python3-venv \
    python3-pip sudo

if ! id "$APP_USER" >/dev/null 2>&1; then
    useradd --system \
        --home-dir "$APP_DIR" \
        --no-create-home \
        --shell /usr/sbin/nologin \
        "$APP_USER"
fi

install -d -o root -g root -m 755 "$APP_DIR"
install -d -o root -g "$APP_USER" -m 750 "$CONFIG_DIR"
install -d -o "$APP_USER" -g "$APP_USER" -m 750 \
    /var/lib/raspberry-control

install -o root -g root -m 644 \
    "$SCRIPT_DIR/bot.py" "$APP_DIR/bot.py"

echo
echo "Preparando entorno virtual..."
python3 -m venv "$APP_DIR/venv"
"$APP_DIR/venv/bin/python" -m pip install \
    --upgrade pip
"$APP_DIR/venv/bin/python" -m pip install \
    "python-telegram-bot>=20,<23"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo
    echo "Configuración inicial de Telegram"
    echo "Obtén el token mediante @BotFather."
    echo "El token no se guardará en GitHub."

    while true; do
        read -r -s -p "Token del bot: " BOT_TOKEN
        echo
        if [[ -n "$BOT_TOKEN" &&
              "$BOT_TOKEN" != *$'\n'* &&
              "$BOT_TOKEN" != *$'\r'* ]]; then
            break
        fi
        echo "Token vacío o inválido."
    done

    while true; do
        read -r -p "ID numérico autorizado de Telegram: " USER_ID
        if [[ "$USER_ID" =~ ^[0-9]+$ ]]; then
            break
        fi
        echo "El ID debe contener solo números."
    done

    umask 027
    {
        printf 'TELEGRAM_BOT_TOKEN=%s\n' "$BOT_TOKEN"
        printf 'TELEGRAM_AUTHORIZED_USER_ID=%s\n' "$USER_ID"
    } > "$CONFIG_FILE"

    unset BOT_TOKEN USER_ID
    chown root:"$APP_USER" "$CONFIG_FILE"
    chmod 640 "$CONFIG_FILE"
else
    echo "Configuración existente conservada."
    chown root:"$APP_USER" "$CONFIG_FILE"
    chmod 640 "$CONFIG_FILE"
fi

install -o root -g root -m 644 \
    "$SCRIPT_DIR/$SERVICE_NAME" \
    "/etc/systemd/system/$SERVICE_NAME"

systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"

echo
echo "======================================"
echo " INSTALACIÓN DEL BOT COMPLETADA"
echo "======================================"
echo
systemctl --no-pager --full status "$SERVICE_NAME" || true

echo
echo "Comandos útiles:"
echo "  sudo systemctl status $SERVICE_NAME"
echo "  sudo journalctl -u $SERVICE_NAME -f"
echo "  sudo systemctl restart $SERVICE_NAME"
echo
echo "IMPORTANTE: Upterm se integrará en el siguiente paso."
