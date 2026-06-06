# MorgenSearch

A Telegram bot and backend service for finding Morgenshtern(recognized in the Russian Federation as a foreign agent) tracks by a word or lyric fragment.

> **Important:** Due to copyright restrictions, the public repository does not store the full lyrics of the artist. In the import files and database dumps, the original lyrics have been replaced with placeholders.

## Product Context

### End users

- Telegram users who want to quickly find Morgenshtern tracks by lyrics.
- Developers/instructors who need an educational example of a microservice architecture with a bot, API, and database.

### Problem that your product solves for end users

- A user remembers a word or lyric line but does not remember the track title.
- Manual search across all tracks is time-consuming.

### Your solution

- The user sends text to the Telegram bot.
- The bot calls the backend endpoint `/search?q=...`.
- The backend searches PostgreSQL for matches and returns a list of track titles.
- Lyrics are fetched from `lyrics.ovh` and normalized for search.

## Features

### Implemented

- Telegram bot built with `python-telegram-bot`.
- FastAPI backend (`/health`, `/search`, `/admin/sync-lyrics`).
- PostgreSQL for storing tracks and lyrics.
- Automatic/manual lyrics sync from `lyrics.ovh`.
- Docker Compose container orchestration.
- pgAdmin for database inspection.

### Not yet implemented

- Caching for popular queries.
- Pagination and more flexible result sorting.
- Advanced filters (album, period, language).
- Automated tests (unit/integration/e2e) and a CI pipeline.

## Usage

1. Create a Telegram bot via BotFather and get a token.
2. In the project root, create `.env`:

```bash
cp .env.example .env
```

3. Set your token in `.env`:

```env
TELEGRAM_BOT_TOKEN=YOUR_REAL_BOT_TOKEN
```

4. Start the project:

```bash
docker compose up --build
```

5. **Load real lyrics into the database**. Since the repository provides only placeholders (due to copyright), you must find and add the actual lyrics for the search to function properly. You can manually update the dataset or try using the built-in sync endpoint to fetch them from the `lyrics.ovh` API:

```bash
curl -X POST "http://localhost:8000/admin/sync-lyrics?limit=50&force=true"
```

6. Open Telegram and send the bot a word or phrase that exists in the loaded lyrics.
7. The bot will return a list of matching tracks.

Additionally:

- Backend: `http://localhost:8000`
- Health check: `http://localhost:8000/health`
- pgAdmin: `http://localhost:5050`

## Deployment

### OS for VM

- Recommended OS: Ubuntu 24.04 LTS.

### What should be installed on the VM

- `git`
- `docker`
- `docker compose` plugin
- `curl`

Install the basic toolset on Ubuntu 24.04:

```bash
sudo apt update
sudo apt install -y git curl ca-certificates
sudo apt install -y docker.io docker-compose-v2
sudo usermod -aG docker $USER
newgrp docker
docker --version
docker compose version
```

### Step-by-step deployment instructions

1. Clone the repository:

```bash
git clone https://github.com/Zhend0sss/savel.git
cd savel
```

2. Create `.env` from the template:

```bash
cp .env.example .env
```

3. Open `.env` and set at least:

```env
TELEGRAM_BOT_TOKEN=YOUR_REAL_BOT_TOKEN
POSTGRES_DB=morgensearch
POSTGRES_USER=morgen
POSTGRES_PASSWORD=morgen
LYRICS_SOURCE=lyricsovh
AUTO_SYNC_LYRICS=false
PGADMIN_DEFAULT_EMAIL=admin@local.dev
PGADMIN_DEFAULT_PASSWORD=admin
```

4. Start the services:

```bash
docker compose up --build -d
```

5. Check backend health:

```bash
curl http://localhost:8000/health
```

Expected response:

```json
{ "status": "ok" }
```

6. Run lyrics synchronization:

```bash
curl -X POST "http://localhost:8000/admin/sync-lyrics?limit=50&force=true"
```

7. Send a query to the bot and verify the result in Telegram.

8. Stop and clean up:

```bash
docker compose down
docker compose down -v
```

## License

This project is open-source under the MIT License. See the [LICENSE](LICENSE) file for details.
