
#!/usr/bin/env python3
"""Raspberry Control: bot de administración para Raspberry Pi."""

import asyncio
import logging
import os
import platform
from pathlib import Path

from telegram import Update
from telegram.ext import (
    Application,
    CommandHandler,
    ContextTypes,
)

APP_DIR = Path("/opt/raspberry-control")
STATE_DIR = Path("/var/lib/raspberry-control")
DATA_FILE = Path(
    os.environ.get(
        "RASPBERRY_DATA_FILE",
        str(STATE_DIR / "datos.txt"),
    )
)

UPTERM_SERVICE = "raspberry-control-upterm.service"
AUTHORIZED_ID = 0

logging.basicConfig(
    format="%(asctime)s %(levelname)s %(message)s",
    level=logging.INFO,
)
logging.getLogger("httpx").setLevel(logging.WARNING)
logger = logging.getLogger(__name__)


def load_config():
    token = os.environ.get("TELEGRAM_BOT_TOKEN", "").strip()
    user_id = os.environ.get(
        "TELEGRAM_AUTHORIZED_USER_ID", ""
    ).strip()

    if not token or not user_id:
        raise RuntimeError(
            "Faltan TELEGRAM_BOT_TOKEN o "
            "TELEGRAM_AUTHORIZED_USER_ID."
        )

    if not user_id.isdigit() or int(user_id) <= 0:
        raise RuntimeError("El ID autorizado no es válido.")

    return token, int(user_id)


def authorized(update: Update) -> bool:
    user = update.effective_user
    chat = update.effective_chat

    return (
        user is not None
        and chat is not None
        and chat.type == "private"
        and user.id == AUTHORIZED_ID
    )


async def reply(update: Update, text: str):
    message = update.effective_message
    if not message:
        return

    text = text or "(sin salida)"
    for start in range(0, len(text), 3500):
        await message.reply_text(text[start:start + 3500])


async def require_auth(update: Update) -> bool:
    if not authorized(update):
        await reply(update, "Acceso denegado.")
        return False
    return True


async def run_command(args, timeout=10):
    """Ejecuta un comando fijo, sin shell."""
    process = await asyncio.create_subprocess_exec(
        *args,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT,
    )

    try:
        output, _ = await asyncio.wait_for(
            process.communicate(),
            timeout=timeout,
        )
    except asyncio.TimeoutError:
        process.kill()
        await process.communicate()
        return "Tiempo agotado."

    text = output.decode("utf-8", errors="replace").strip()
    if not text:
        text = "(sin salida)"

    return f"{text}\n\nCódigo: {process.returncode}"


async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not await require_auth(update):
        return

    await reply(
        update,
        "🍓 RASPBERRY CONTROL\n\n"
        "/status - Estado del sistema\n"
        "/pwd - Directorio de trabajo\n"
        "/ls - Archivos de datos\n"
        "/procesos - Procesos activos\n"
        "/datos - Leer archivo de datos\n"
        "/terminal comando - Diagnóstico permitido\n"
        "/upterm estado - Estado de Upterm\n"
        "/upterm iniciar - Iniciar terminal remota\n"
        "/upterm detener - Detener terminal remota\n"
        "/upterm conexion - Consultar registros de conexión\n"
        "/help - Mostrar ayuda\n\n"
        "Para ejecutar comandos Linux completos, "
        "conéctate por SSH mediante Upterm."
    )


async def help_command(
    update: Update, context: ContextTypes.DEFAULT_TYPE
):
    await start(update, context)


async def status(
    update: Update, context: ContextTypes.DEFAULT_TYPE
):
    if not await require_auth(update):
        return

    lines = [
        f"Equipo: {platform.node()}",
        f"Sistema: {platform.system()} {platform.release()}",
        f"Python: {platform.python_version()}",
    ]

    try:
        load = os.getloadavg()
        lines.append(
            f"Carga: {load[0]:.2f}, {load[1]:.2f}, {load[2]:.2f}"
        )
    except (OSError, AttributeError):
        pass

    try:
        stat = os.statvfs("/")
        total = stat.f_blocks * stat.f_frsize
        free = stat.f_bavail * stat.f_frsize
        used = 100 * (total - free) / total if total else 0
        lines.append(f"Disco raíz usado: {used:.1f}%")
    except OSError:
        pass

    await reply(update, "\n".join(lines))


async def pwd(
    update: Update, context: ContextTypes.DEFAULT_TYPE
):
    if not await require_auth(update):
        return
    await reply(update, str(STATE_DIR))


async def ls(
    update: Update, context: ContextTypes.DEFAULT_TYPE
):
    if not await require_auth(update):
        return

    try:
        if not STATE_DIR.is_dir():
            return await reply(update, "No existe el directorio de datos.")

        entries = sorted(
            STATE_DIR.iterdir(),
            key=lambda path: path.name.lower(),
        )
        output = "\n".join(
            ("📁 " if path.is_dir() else "📄 ") + path.name
            for path in entries[:80]
        )
        await reply(update, output or "(directorio vacío)")
    except OSError as exc:
        await reply(update, f"No se pudo listar: {exc}")


async def procesos(
    update: Update, context: ContextTypes.DEFAULT_TYPE
):
    if not await require_auth(update):
        return

    output = await run_command([
        "/usr/bin/ps",
        "-eo",
        "pid,comm,%cpu,%mem",
        "--sort=-%cpu",
    ])
    await reply(update, output)


async def datos(
    update: Update, context: ContextTypes.DEFAULT_TYPE
):
    if not await require_auth(update):
        return

    try:
        if not DATA_FILE.is_file():
            return await reply(
                update,
                f"No existe el archivo de datos:\n{DATA_FILE}",
            )

        content = DATA_FILE.read_text(encoding="utf-8").strip()
        await reply(update, content or "(archivo vacío)")
    except OSError:
        logger.exception("Error leyendo el archivo de datos")
        await reply(update, "No se pudo leer el archivo de datos.")


DIAGNOSTICS = {
    "uname": ["/usr/bin/uname", "-a"],
    "uptime": ["/usr/bin/uptime"],
    "df": ["/usr/bin/df", "-h"],
    "free": ["/usr/bin/free", "-h"],
    "whoami": ["/usr/bin/whoami"],
    "date": ["/usr/bin/date"],
    "hostname": ["/usr/bin/hostname"],
    "ip": ["/usr/sbin/ip", "-brief", "address"],
}


async def terminal(
    update: Update, context: ContextTypes.DEFAULT_TYPE
):
    if not await require_auth(update):
        return

    if not context.args:
        return await reply(
            update,
            "Diagnósticos disponibles:\n"
            + ", ".join(sorted(DIAGNOSTICS))
            + "\n\nEjemplo: /terminal df",
        )

    command = context.args[0].lower()

    if len(context.args) != 1 or command not in DIAGNOSTICS:
        return await reply(
            update,
            "Comando no permitido. Usa /terminal para ver "
            "los diagnósticos disponibles. La terminal completa "
            "está disponible por SSH/Upterm.",
        )

    output = await run_command(DIAGNOSTICS[command])
    await reply(update, output)


async def upterm(
    update: Update, context: ContextTypes.DEFAULT_TYPE
):
    if not await require_auth(update):
        return

    action = context.args[0].lower() if context.args else "estado"

    if action not in {"estado", "iniciar", "detener", "conexion"}:
        return await reply(
            update,
            "Uso:\n"
            "/upterm estado\n"
            "/upterm iniciar\n"
            "/upterm detener\n"
            "/upterm conexion",
        )

    if action == "conexion":
        output = await run_command([
            "/usr/bin/sudo", "-n",
            "/usr/bin/journalctl",
            "-u", UPTERM_SERVICE,
            "-n", "40",
            "--no-pager",
        ], timeout=15)
        return await reply(update, output)

    if action == "estado":
        output = await run_command([
            "/usr/bin/systemctl",
            "is-active",
            UPTERM_SERVICE,
        ])
        enabled = await run_command([
            "/usr/bin/systemctl",
            "is-enabled",
            UPTERM_SERVICE,
        ])
        return await reply(
            update,
            f"Servicio Upterm: {output}\nArranque automático: {enabled}",
        )

    operation = "start" if action == "iniciar" else "stop"

    output = await run_command([
        "/usr/bin/sudo", "-n",
        "/usr/bin/systemctl", operation, UPTERM_SERVICE,
    ], timeout=20)

    state = await run_command([
        "/usr/bin/systemctl", "is-active", UPTERM_SERVICE,
    ])

    await reply(
        update,
        f"Acción: {action}\n{output}\nEstado actual: {state}",
    )


async def error_handler(
    update: object, context: ContextTypes.DEFAULT_TYPE
):
    logger.error(
        "Error procesando actualización",
        exc_info=context.error,
    )


def main():
    global AUTHORIZED_ID

    token, AUTHORIZED_ID = load_config()

    app = Application.builder().token(token).build()
    app.add_handler(CommandHandler("start", start))
    app.add_handler(CommandHandler("help", help_command))
    app.add_handler(CommandHandler("status", status))
    app.add_handler(CommandHandler("pwd", pwd))
    app.add_handler(CommandHandler("ls", ls))
    app.add_handler(CommandHandler("procesos", procesos))
    app.add_handler(CommandHandler("datos", datos))
    app.add_handler(CommandHandler("terminal", terminal))
    app.add_handler(CommandHandler("cmd", terminal))
    app.add_handler(CommandHandler("upterm", upterm))
    app.add_error_handler(error_handler)

    logger.info("Raspberry Control iniciado.")
    app.run_polling(drop_pending_updates=True)


if __name__ == "__main__":
    main()
