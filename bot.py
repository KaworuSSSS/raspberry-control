
#!/usr/bin/env python3
"""Raspberry Control: bot administrativo para Raspberry Pi."""

import asyncio
import os
import platform
import shlex
from pathlib import Path

from telegram import Update
from telegram.ext import (
    Application,
    CommandHandler,
    ContextTypes,
)

TOKEN_FILE = Path("/etc/raspberry-control/bot.env")


def load_config():
    token = os.environ.get("TELEGRAM_BOT_TOKEN", "").strip()
    user_id = os.environ.get("TELEGRAM_AUTHORIZED_USER_ID", "").strip()

    if not token or not user_id:
        raise RuntimeError(
            "Configura TELEGRAM_BOT_TOKEN y "
            "TELEGRAM_AUTHORIZED_USER_ID en el servicio."
        )

    if not user_id.isdigit():
        raise RuntimeError("El ID autorizado debe ser numérico.")

    return token, int(user_id)


def authorized(update: Update) -> bool:
    user = update.effective_user
    return (
        user is not None
        and str(user.id) == os.environ.get(
            "TELEGRAM_AUTHORIZED_USER_ID", ""
        ).strip()
    )


async def deny(update: Update):
    if update.effective_message:
        await update.effective_message.reply_text(
            "Acceso denegado. Tu ID no está autorizado."
        )


async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not authorized(update):
        return await deny(update)

    await update.effective_message.reply_text(
        "🍓 RASPBERRY CONTROL\n\n"
        "/status - Estado del sistema\n"
        "/pwd - Directorio actual\n"
        "/ls - Archivos del directorio\n"
        "/upterm - Estado del servicio Upterm\n"
        "/help - Mostrar ayuda\n\n"
        "La terminal remota se administra mediante SSH/Upterm."
    )


async def help_command(
    update: Update, context: ContextTypes.DEFAULT_TYPE
):
    if not authorized(update):
        return await deny(update)

    await start(update, context)


async def status(
    update: Update, context: ContextTypes.DEFAULT_TYPE
):
    if not authorized(update):
        return await deny(update)

    text = (
        f"🖥 Sistema: {platform.system()} {platform.release()}\n"
        f"🐍 Python: {platform.python_version()}\n"
        f"🏠 Host: {platform.node()}\n"
    )

    try:
        load1, load5, load15 = os.getloadavg()
        text += (
            f"📊 Carga: {load1:.2f}, {load5:.2f}, "
            f"{load15:.2f}\n"
        )
    except (OSError, AttributeError):
        pass

    try:
        stat = os.statvfs("/")
        total = stat.f_blocks * stat.f_frsize
        free = stat.f_bavail * stat.f_frsize
        used_pct = (total - free) * 100 / total if total else 0
        text += f"💾 Disco raíz usado: {used_pct:.1f}%\n"
    except OSError:
        pass

    await update.effective_message.reply_text(text)


async def pwd(
    update: Update, context: ContextTypes.DEFAULT_TYPE
):
    if not authorized(update):
        return await deny(update)

    await update.effective_message.reply_text(os.getcwd())


async def ls(
    update: Update, context: ContextTypes.DEFAULT_TYPE
):
    if not authorized(update):
        return await deny(update)

    try:
        entries = sorted(Path.cwd().iterdir(), key=lambda p: p.name.lower())
        result = "\n".join(
            ("📁 " if p.is_dir() else "📄 ") + p.name
            for p in entries[:60]
        ) or "(directorio vacío)"
        await update.effective_message.reply_text(result[:4000])
    except OSError as exc:
        await update.effective_message.reply_text(
            f"No se pudo listar: {exc}"
        )


async def upterm(
    update: Update, context: ContextTypes.DEFAULT_TYPE
):
    if not authorized(update):
        return await deny(update)

    proc = await asyncio.create_subprocess_exec(
        "systemctl",
        "is-active",
        "raspberry-control-upterm.service",
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT,
    )
    out, _ = await proc.communicate()
    state = out.decode(errors="replace").strip() or "desconocido"

    await update.effective_message.reply_text(
        f"Servicio Upterm: {state}"
    )


def main():
    token, user_id = load_config()
    os.environ["TELEGRAM_AUTHORIZED_USER_ID"] = str(user_id)

    app = Application.builder().token(token).build()
    app.add_handler(CommandHandler("start", start))
    app.add_handler(CommandHandler("help", help_command))
    app.add_handler(CommandHandler("status", status))
    app.add_handler(CommandHandler("pwd", pwd))
    app.add_handler(CommandHandler("ls", ls))
    app.add_handler(CommandHandler("upterm", upterm))

    print("Raspberry Control iniciado.")
    app.run_polling(drop_pending_updates=True)


if __name__ == "__main__":
    main()
