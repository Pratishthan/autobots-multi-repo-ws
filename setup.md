# Langfuse Setup Guide

Langfuse runs via Docker Compose. Postgres, Redis, and ClickHouse run on the host VM. Only Minio runs as a container.

---

## Prerequisites

Ensure the following services are running on your host VM before starting Docker Compose.

### Postgres

**macOS:**
```bash
brew install postgresql
brew services start postgresql
```

**Linux:**
```bash
sudo apt install postgresql
sudo systemctl enable postgresql
sudo systemctl start postgresql
```

Verify:
```bash
pg_isready -U postgres
```

---

### Redis

**macOS:**
```bash
brew install redis
brew services start redis
```

**Linux:**
```bash
sudo apt install redis-server
sudo systemctl enable redis-server
sudo systemctl start redis-server
```

Verify:
```bash
redis-cli ping
# Expected: PONG
```

---

### ClickHouse

ClickHouse runs as a standalone binary. Directory layout under `ws-jarvis/`:

```
click/
  clickhouse      ← binary
  config.xml      ← server config (sets data path + listen host)
  data/           ← all ClickHouse data
```

#### Start ClickHouse

Always run from `ws-jarvis/`. The config file pins the data path to `click/data/` and binds to all interfaces so Docker containers can reach it.

```bash
click/clickhouse server --config-file=click/config.xml
```

Run in the background:
```bash
click/clickhouse server --config-file=click/config.xml &> click/data/clickhouse.log &
```

Verify:
```bash
curl http://localhost:8123/ping   # Ok.
```

#### Stop ClickHouse

```bash
pkill -f clickhouse
```

If it doesn't stop:
```bash
kill -9 $(pgrep clickhouse)
```

#### Create the Langfuse ClickHouse user

```bash
click/clickhouse client --user default --query "CREATE USER IF NOT EXISTS clickhouse IDENTIFIED BY 'clickhouse';"
click/clickhouse client --user default --query "GRANT ALL ON default.* TO clickhouse;"
click/clickhouse client --user default --query "GRANT TABLE ENGINE ON * TO clickhouse;"
```

> Replace `'clickhouse'` with your actual password if you change `CLICKHOUSE_PASSWORD` in `.env`.

Verify grants:
```bash
click/clickhouse client --user default --query "SHOW GRANTS FOR clickhouse"
```

> Run client commands from `ws-jarvis/`. The binary is at `click/clickhouse`.

---

## Environment Configuration

Copy the example env file and fill in your secrets:

```bash
cp .env.example .env
```

Key variables to update (search for `# CHANGEME`):

| Variable | Description |
|---|---|
| `DATABASE_URL` | Postgres connection string |
| `CLICKHOUSE_PASSWORD` | Must match the password set above |
| `REDIS_AUTH` | Redis password |
| `SALT` | Random string for hashing |
| `ENCRYPTION_KEY` | 64-char hex — generate with `openssl rand -hex 32` |
| `NEXTAUTH_SECRET` | Random secret for NextAuth |
| `MINIO_ROOT_PASSWORD` | Minio admin password |

---

## Start Docker Compose

```bash
docker compose up -d
```

Langfuse will be available at http://localhost:3000.

---

## Troubleshooting

### ClickHouse connection refused from Docker

```
dial tcp 0.250.250.254:9000: connect: connection refused
```

ClickHouse is only listening on `127.0.0.1`. Ensure `click/config.xml` has `<listen_host>0.0.0.0</listen_host>` and restart:

```bash
pkill -f clickhouse || true
click/clickhouse server --config-file=click/config.xml &> click/data/clickhouse.log &
docker compose restart langfuse-web langfuse-worker
```

---

### ClickHouse migration fails — not enough privileges

Langfuse migrations require two categories of grants. Apply both:

```bash
# Grant full access to the default database
click/clickhouse client --user default --query "GRANT ALL ON default.* TO clickhouse;"

# Grant permission to use any table engine (MergeTree, ReplacingMergeTree, etc.)
click/clickhouse client --user default --query "GRANT TABLE ENGINE ON * TO clickhouse;"

docker compose restart langfuse-web langfuse-worker
```

### Services checklist before starting

| Service | Port | Verify |
|---|---|---|
| Postgres | 5432 | `pg_isready -U postgres` |
| Redis | 6379 | `redis-cli ping` → `PONG` |
| ClickHouse HTTP | 8123 | `curl http://localhost:8123/ping` → `Ok.` |
| ClickHouse native | 9000 | `click/clickhouse client --query "SELECT 1"` (from `ws-jarvis/`) |

### View logs

```bash
docker compose logs -f langfuse-web
docker compose logs -f langfuse-worker
```

### Restart individual services

```bash
docker compose restart langfuse-web langfuse-worker
```

### Full reset (destroys Minio data)

```bash
docker compose down -v
docker compose up -d
```
