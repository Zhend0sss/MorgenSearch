import os
import logging

import requests
from telegram import Update
from telegram.ext import Application, CommandHandler, ContextTypes, MessageHandler, filters

BOT_TOKEN = os.getenv("TELEGRAM_BOT_TOKEN", "")
BACKEND_URL = os.getenv("BACKEND_URL", "http://backend:8000")

logging.basicConfig(
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    level=logging.INFO,
)
logger = logging.getLogger("morgensearch-bot")

START_GREETING = "Пошел нахуй."
NEXT_QUERY_PROMPT = "Дай отрывок песни либо иди нахуй."


async def on_start(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if update.message is None:
        return

    await update.message.reply_text(START_GREETING)
    await update.message.reply_text(NEXT_QUERY_PROMPT)


async def on_text(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if update.message is None or update.message.text is None:
        return

    query = update.message.text.strip()
    if not query:
        await update.message.reply_text(NEXT_QUERY_PROMPT)
        return

    logger.info("Incoming query: %s", query)

    try:
        response = requests.get(
            f"{BACKEND_URL}/search",
            params={"q": query},
            timeout=10,
        )
        response.raise_for_status()
        payload = response.json()
    except requests.RequestException:
        logger.exception("Backend request failed")
        await update.message.reply_text("Не удалось обратиться к backend. Попробуйте чуть позже.")
        await update.message.reply_text(NEXT_QUERY_PROMPT)
        return

    songs = payload.get("songs", [])
    if not songs:
        logger.info("No matches for query: %s", query)
        await update.message.reply_text(
            f"По запросу '{query}' у Morgenshtern ничего не найдено."
        )
        await update.message.reply_text(NEXT_QUERY_PROMPT)
        return

    logger.info("Found %s matches for query: %s", len(songs), query)

    lines = [f"Найдено: {len(songs)}", ""]
    lines.extend(f"- {title}" for title in songs)
    await update.message.reply_text("\n".join(lines))
    await update.message.reply_text(NEXT_QUERY_PROMPT)


def main() -> None:
    if not BOT_TOKEN:
        raise RuntimeError("TELEGRAM_BOT_TOKEN is not set")

    logger.info("Starting bot, backend URL: %s", BACKEND_URL)

    app = Application.builder().token(BOT_TOKEN).build()
    app.add_handler(CommandHandler("start", on_start))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, on_text))
    app.run_polling(drop_pending_updates=True)


if __name__ == "__main__":
    main()
