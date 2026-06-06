import csv
from pathlib import Path

csv_path = Path("tracks_import.csv")
out_path = Path("import_tracks.sql")

rows = list(csv.DictReader(csv_path.open("r", encoding="utf-8")))

statements = [
    "BEGIN;",
    "CREATE UNIQUE INDEX IF NOT EXISTS ux_songs_artist_title ON songs(artist, title);",
]


def q(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


for row in rows:
    title = (row.get("title") or "").strip()
    lyrics = f"текст песни {title}"
    if not title:
        continue

    search_text = " ".join(lyrics.lower().split())

    statements.append(
        "INSERT INTO songs (title, artist, lyrics_text, search_text, lyrics_source, lyrics_loaded_at) "
        f"VALUES ({q(title)}, 'Morgenshtern', {q(lyrics)}, {q(search_text)}, 'excel_import', NOW()) "
        "ON CONFLICT (artist, title) DO UPDATE SET "
        "lyrics_text = EXCLUDED.lyrics_text, "
        "search_text = EXCLUDED.search_text, "
        "lyrics_source = EXCLUDED.lyrics_source, "
        "lyrics_loaded_at = NOW();"
    )

statements.append("COMMIT;")
out_path.write_text("\n".join(statements), encoding="utf-8")
print(f"rows_in_csv={len(rows)};sql_statements={len(statements) - 3}")
