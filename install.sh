
#!/usr/bin/env bash
set -Eeuo pipefail

# Raspberry Control - preparacion inicial
# Compatible con Raspberry Pi OS basado en Debian.

if [[ "${EUID}" -ne 0 ]]; then
    echo "Ejecuta este instalador con sudo:"
    echo "sudo bash install.sh"
    exit 1
fi

if [[ ! -f /etc/os-release ]]; then
    echo "No se pudo identificar el sistema operativo."
    exit 1
fi

. /etc/os-release

if [[ "${ID:-}" != "raspbian" && "${ID:-}" != "debian" ]]; then
    echo "Aviso: sistema detectado: ${PRETTY_NAME:-desconocido}"
    echo "Se intentara continuar si usa APT."
fi

if ! command -v apt-get >/dev/null 2>&1; then
    echo "Este instalador requiere apt-get."
    exit 1
fi

echo "======================================"
echo " RASPBERRY CONTROL"
echo " Preparando dependencias"
echo "======================================"

export DEBIAN_FRONTEND=noninteractive

apt-get update
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

echo
echo "Versiones instaladas:"
python3 --version
git --version
go version

echo
echo "Preparacion inicial completada."
echo "El siguiente paso sera configurar el bot y los servicios seguros."
