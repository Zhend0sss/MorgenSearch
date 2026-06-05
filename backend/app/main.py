import os
from typing import List
from urllib.parse import quote

import psycopg2
import requests
from fastapi import FastAPI, HTTPException, Query
from psycopg2.extras import RealDictCursor

app = FastAPI(title="MorgenSearch Backend", version="1.0.0")

DB_NAME = os.getenv("POSTGRES_DB", "morgensearch")
DB_USER = os.getenv("POSTGRES_USER", "morgen")
DB_PASSWORD = os.getenv("POSTGRES_PASSWORD", "morgen")
DB_HOST = os.getenv("DB_HOST", "postgres")
DB_PORT = int(os.getenv("DB_PORT", "5432"))
LYRICS_SOURCE = os.getenv("LYRICS_SOURCE", "lyricsovh")
AUTO_SYNC_LYRICS = os.getenv("AUTO_SYNC_LYRICS", "false").lower() == "true"

TARGET_ARTIST = "Morgenshtern"
SONG_CATALOG = [
    "Cristal & МОЁТ",
    "Cadillac",
    "El Problema",
    "ICE",
    "Yung Hefner",
    "SHOW",
    "DINERO",
    "PABLO",
    "Новый Мерин",
    "Последняя Любовь",
    "12",
    "Мне пох",
    "DOMOFON",
    "Lollipop",
    "Family",
    "WATAFUK?!",
    "Guf died",
    "Я когда-нибудь уйду",
    "TURN IT ON!",
    "Новый Бентли",
    "SHEIKH",
    "ARISTOCRAT",
    "Почему?",
    "AUF",
    "POMADA",
    "SILHOUETTE",
    "BOUNTY",
    "Insomnia",
    "DISS ON MY HEAD",
    "Leck",
]


def get_connection() -> psycopg2.extensions.connection:
    return psycopg2.connect(
        dbname=DB_NAME,
        user=DB_USER,
        password=DB_PASSWORD,
        host=DB_HOST,
        port=DB_PORT,
    )


def normalize_search_text(value: str) -> str:
    return " ".join(value.lower().split())


def fetch_lyrics_from_source(artist: str, title: str) -> dict | None:
    if LYRICS_SOURCE != "lyricsovh":
        return None

    encoded_artist = quote(artist, safe="")
    encoded_title = quote(title, safe="")
    source_url = f"https://api.lyrics.ovh/v1/{encoded_artist}/{encoded_title}"

    try:
        response = requests.get(source_url, timeout=12)
    except requests.RequestException:
        return None

    if response.status_code != 200:
        return None

    payload = response.json()
    lyrics = payload.get("lyrics", "").strip()
    if not lyrics:
        return None

    return {
        "lyrics": lyrics,
        "source": "lyricsovh",
        "source_url": source_url,
    }


def ensure_schema_and_seed() -> None:
    ddl = """
    CREATE TABLE IF NOT EXISTS songs (
        id SERIAL PRIMARY KEY,
        title TEXT NOT NULL,
        artist TEXT NOT NULL,
        search_text TEXT NOT NULL DEFAULT ''
    );
    ALTER TABLE songs ADD COLUMN IF NOT EXISTS lyrics_text TEXT;
    ALTER TABLE songs ADD COLUMN IF NOT EXISTS lyrics_source TEXT;
    ALTER TABLE songs ADD COLUMN IF NOT EXISTS lyrics_source_url TEXT;
    ALTER TABLE songs ADD COLUMN IF NOT EXISTS lyrics_loaded_at TIMESTAMP;
    """

    insert_sql = """
    INSERT INTO songs (title, artist, search_text)
    VALUES (%s, %s, '')
    ON CONFLICT DO NOTHING;
    """

    with get_connection() as conn:
        with conn.cursor() as cursor:
            cursor.execute(ddl)
            for title in SONG_CATALOG:
                cursor.execute(insert_sql, (title, TARGET_ARTIST))


def sync_lyrics(limit: int, force: bool) -> dict:
    if limit < 1:
        raise HTTPException(status_code=400, detail="limit must be > 0")

    select_sql = """
    SELECT id, title, COALESCE(search_text, '') AS search_text
    FROM songs
    WHERE artist = %s
    ORDER BY id
    LIMIT %s;
    """

    update_sql = """
    UPDATE songs
    SET lyrics_text = %s,
        search_text = %s,
        lyrics_source = %s,
        lyrics_source_url = %s,
        lyrics_loaded_at = NOW()
    WHERE id = %s;
    """

    updated = 0
    not_found = 0
    skipped = 0
    processed_titles: List[str] = []

    with get_connection() as conn:
        with conn.cursor(cursor_factory=RealDictCursor) as cursor:
            cursor.execute(select_sql, (TARGET_ARTIST, limit))
            rows: List[dict] = cursor.fetchall()

            for row in rows:
                if row["search_text"] and not force:
                    skipped += 1
                    continue

                data = fetch_lyrics_from_source(TARGET_ARTIST, row["title"])
                if data is None:
                    not_found += 1
                    continue

                cursor.execute(
                    update_sql,
                    (
                        data["lyrics"],
                        normalize_search_text(data["lyrics"]),
                        data["source"],
                        data["source_url"],
                        row["id"],
                    ),
                )
                updated += 1
                processed_titles.append(row["title"])

    return {
        "artist": TARGET_ARTIST,
        "source": LYRICS_SOURCE,
        "updated": updated,
        "not_found": not_found,
        "skipped": skipped,
        "updated_titles": processed_titles,
    }


@app.on_event("startup")
def on_startup() -> None:
    ensure_schema_and_seed()
    if AUTO_SYNC_LYRICS:
        sync_lyrics(limit=len(SONG_CATALOG), force=False)


@app.get("/health")
def health() -> dict:
    return {"status": "ok"}


@app.post("/admin/sync-lyrics")
def sync_lyrics_endpoint(
    limit: int = Query(10, ge=1, le=200),
    force: bool = Query(False),
) -> dict:
    return sync_lyrics(limit=limit, force=force)


@app.get("/search")
def search_tracks(q: str = Query(..., min_length=1)) -> dict:
    query = q.strip()
    if not query:
        raise HTTPException(status_code=400, detail="Search query must not be empty")

    query_normalized = normalize_search_text(query)

    sql = """
    SELECT DISTINCT title
    FROM songs
    WHERE artist = %s
            AND (
                        COALESCE(lyrics_text, '') ILIKE %s
                 OR COALESCE(search_text, '') ILIKE %s
            )
    ORDER BY title;
    """

    try:
        with get_connection() as conn:
            with conn.cursor(cursor_factory=RealDictCursor) as cursor:
                cursor.execute(
                    sql,
                    (
                        TARGET_ARTIST,
                        f"%{query}%",
                        f"%{query_normalized}%",
                    ),
                )
                rows: List[dict] = cursor.fetchall()
    except psycopg2.Error as exc:
        raise HTTPException(status_code=500, detail=f"Database error: {exc.pgerror or str(exc)}") from exc

    titles = [row["title"] for row in rows]
    return {
        "artist": TARGET_ARTIST,
        "query": query,
        "count": len(titles),
        "songs": titles,
    }
