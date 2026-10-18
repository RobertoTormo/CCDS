# Core Application and Data Layer — Implementation Documentation

**Project:** CCDS (Cloud Computing and Distributed Systems)  
**Component owner:** Adrian  
**Repository:** https://github.com/RobertoTormo/CCDS  
**Branch:** `adrian/core-app-production`  
**Documentation status:** Based on implementation and test results recorded during the project work.

---

## 1. Scope and responsibilities

My project responsibility is the Core Application and Data layer. The work covered:

- A Flask-based HTTP API.
- PostgreSQL persistence.
- Redis caching.
- Development and production container configuration.
- Docker image build and publication to the team's private registry.
- Docker Swarm deployment configuration.
- Database credentials supplied to production containers through a Swarm secret.
- Automated PostgreSQL backups to shared NFS storage.
- Testing the application, production routing, backup archive and restore process.
- Preparing the application files for integration into the shared GitHub repository.

Infrastructure components such as the Swarm cluster, private registry service, shared NFS server and shared overlay networks are team infrastructure. They are consumed by this component rather than owned by this part of the work.

## 2. Application architecture

The component consists of these services:

| Service | Purpose |
|---|---|
| `core` | Flask API served by Gunicorn |
| `postgres` | Persistent relational data store |
| `redis` | Cache for item data |
| `static` | Apache HTTP server serving static HTML in the development Compose configuration |
| `backup` | PostgreSQL backup job that writes dump archives to a backup directory; production uses the shared NFS volume |

### Request flow

In production, a client reaches the Core API through Traefik. The production router matches the `/api` prefix and strips that prefix before forwarding the request to the Core service on container port `5000`.

Examples:

- External request `GET /api/health` is forwarded to Flask as `GET /health`.
- External request `GET /api/items` is forwarded to Flask as `GET /items`.
- External request `POST /api/items` is forwarded to Flask as `POST /items`.

The Core service is attached to the `frontend` and `backend` overlay networks. PostgreSQL and Redis are attached to `backend`, so the database and cache do not need to be published on host ports.

## 3. Source files

The application files prepared under `app/` are:

```text
app/
├── .gitignore
├── compose.dev.yml
├── production.yml
├── backup/
│   └── backup.sh
├── core/
│   ├── Dockerfile
│   ├── app.py
│   └── requirements.txt
├── db/
├── redis/
└── static/
    └── html/
        └── index.html
```

Some directories (`db/` and `redis/`) were present but no additional custom files in them were included in the staged file list at the time of the push.

### Main configuration files

- `core/app.py`: API endpoints, database connectivity, Redis cache handling and automatic database schema initialization.
- `core/Dockerfile`: builds the Python application image and runs Gunicorn.
- `core/requirements.txt`: pinned Python package dependencies.
- `compose.dev.yml`: local development services and ports.
- `production.yml`: Docker Swarm production stack.
- `backup/backup.sh`: development backup script. Production backup execution is defined in `production.yml`.
- `static/html/index.html`: static page served by Apache in the development setup.
- `.gitignore`: excludes local secrets and generated files from Git.

## 4. Core API

The Flask application is served by Gunicorn, bound to `0.0.0.0:5000` with two Gunicorn workers.

### Endpoints

| Method | Endpoint inside Flask | Purpose | Expected behavior |
|---|---|---|---|
| `GET` | `/` | Basic service status | Returns JSON identifying `core-app` as running |
| `GET` | `/health` | Application/database health check | Returns healthy status when PostgreSQL can execute `SELECT 1`; otherwise returns HTTP `503` |
| `GET` | `/items` | Read item records | Reads cached items when available, otherwise queries PostgreSQL and caches the result |
| `POST` | `/items` | Create an item | Validates the item name, inserts a record, invalidates the item cache and returns HTTP `201` |

The production URL paths are prefixed by `/api` at the proxy, for example `GET /api/health`.

### Item data and cache behavior

- Item records are stored in PostgreSQL.
- Redis caches the item list using the key `items`.
- The cache TTL is 30 seconds.
- If Redis is unavailable, the application degrades gracefully and can read from PostgreSQL.
- After a successful item insertion, the cache is invalidated so a subsequent read can retrieve current data from the database.

### Dependencies

`core/requirements.txt` pins these dependencies:

- Flask `3.1.2`
- `psycopg[binary]` `3.2.10`
- Redis Python client `5.2.1`
- Gunicorn `23.0.0`

## 5. Automatic database schema initialization

The application now initializes its required schema during startup. It creates the `items` table if it does not already exist:

```sql
CREATE TABLE IF NOT EXISTS items (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL
);
```

The initializer:

1. Attempts to connect to PostgreSQL.
2. Uses a PostgreSQL advisory transaction lock to serialize initialization across replicas/workers.
3. Creates the table if absent.
4. Retries failed PostgreSQL initialization attempts up to 12 times, waiting 5 seconds between attempts.
5. Logs successful initialization and raises an error if all attempts fail.

This was added to the application and included in image `core-app:1.2`.

**Verification:** A separate disposable database was used to test automatic schema creation. The test was reported as successful. This validates fresh-database initialization without relying only on the existing production table.

## 6. Development environment

The local Compose configuration is `compose.dev.yml`.

| Component | Development configuration |
|---|---|
| Core API | Host port `5001` mapped to container port `5000` |
| Static Apache page | Host port `8081` mapped to container port `80` |
| PostgreSQL | `postgres:17`, persistent Compose volume |
| Redis | `redis:7-alpine`, AOF enabled and persistent Compose volume |
| Backup job | PostgreSQL client image; writes backups to a local Compose volume |

The development Core service receives `DATABASE_URL` and `REDIS_URL` through environment variables. Local database credentials are sourced from `.env`, which is excluded from Git.

### Development checks performed

The following checks succeeded:

- Started/rebuilt the development Core service with Docker Compose.
- `curl -i http://localhost:5001/health` returned a healthy response.
- `curl -i http://localhost:5001/items` returned item data from the development database.
- Ran the development backup script and created a non-empty PostgreSQL custom-format dump.
- Restored a development dump into a separate restore-test database and checked the restored rows.

**Port note:** Host port `5000` is used by the container registry on the manager, not the development Core API. The development API uses port `5001`.

## 7. Production image and deployment

### Image publication

The application image was built, tagged and pushed to the team registry:

```text
10.0.0.4:5000/core-app:1.2
```

The registry endpoint is the private address of the manager node. It uses plain HTTP and is configured as an insecure registry on the Swarm nodes in the existing project environment.

### Production stack

The production stack file is `production.yml`. It defines:

- `core`: two replicas, attached to `frontend` and `backend`.
- `postgres`: one replica, placed on `balkan1`.
- `redis`: one replica, placed on `balkan1`.
- `backup`: one replica, placed on `balkan1`, with the external `nfsvolume` mounted at `/backups`.

The production stack uses the pre-created external `frontend` and `backend` networks and the external `nfsvolume`. Those resources are maintained by the infrastructure workstream.

The production Core service uses the `db_password` Docker Swarm secret. The application reads the secret path specified by `DB_PASSWORD_FILE`, rather than requiring the production password to be embedded in the image or committed to Git.

The PostgreSQL container uses `POSTGRES_PASSWORD_FILE` to read the same secret. The production stack declares the secret as external, so it must already exist in the Swarm before deployment.

### Deployment commands

From the app directory, the stack was validated and deployed using the project's environment configuration:

```bash
set -a
. ./.env
set +a

docker stack config -c production.yml >/dev/null
docker stack deploy -c production.yml coreprod
```

The `.env` file is for variable substitution and must remain private. Do not print its contents or commit it. Production credentials are supplied to services through the Swarm secret.

### Production status verified

The deployed services were observed in a healthy state:

- `coreprod_core`: 2/2 replicas.
- `coreprod_postgres`: 1/1 replica.
- `coreprod_redis`: 1/1 replica.
- `coreprod_backup`: 1/1 replica.

The Core application replicas were running image `10.0.0.4:5000/core-app:1.2`.

### Production HTTP checks

The following requests succeeded through the configured proxy:

```bash
curl -i http://localhost:81/api/health
curl -i http://localhost:81/api/items
```

The health endpoint returned HTTP `200` with a healthy status and a connected database. The items endpoint returned the production record:

```json
[
  {"id": 1, "name": "production test"}
]
```

The existing production data remained available after the application image rollout.

## 8. Credentials and secret handling

- `.env` is excluded from Git.
- `db_password.txt` was used temporarily to create the Swarm secret and was not intended for repository publication.
- The production stack consumes the external Swarm secret `db_password`.
- Production services read the secret from `/run/secrets/db_password`.
- The production password is not part of the application image.
- The staged Git file list for the application branch did not include `.env`, `db_password.txt`, or database dump files.

**Security follow-up:** A development password was exposed in terminal output during configuration validation. Avoid sharing that output again, and rotate any credential that was reused outside development. Keep all credentials out of commits and logs.

The registry currently uses plain HTTP on the internal network. This is the established project configuration, not a claim that the registry transport is encrypted.

## 9. Database backup and restore

### Development backup script

`backup/backup.sh`:

1. Waits until PostgreSQL accepts connections.
2. Uses `pg_dump` in custom archive format.
3. Writes to a temporary `.partial` file.
4. Checks that the archive is non-empty.
5. Renames it to its final `.dump` filename only after a successful dump.
6. Removes dump files older than seven days.

This reduces the risk of treating an incomplete dump as a valid backup.

### Production backups

The production `backup` service runs a loop that:

- Reads the PostgreSQL password from the Swarm secret.
- Waits for PostgreSQL readiness.
- Creates a custom-format dump under `/backups`.
- Mounts the shared external `nfsvolume` at `/backups`.
- Uses an atomic rename from `.partial` to `.dump` after a successful backup.
- Removes matching dump files older than seven days.
- Sleeps for 24 hours before the next backup attempt.

Example production backup path observed during testing:

```text
/backups/coredb_20261016_155636.dump
```

The exact timestamp and contents depend on when the job runs. The shared NFS storage was verified separately by writing a file and checking its availability across nodes.

### Restore testing

A production backup was inspected with `pg_restore --list`, which confirmed that it was a PostgreSQL custom-format archive. It was restored into a separate temporary database, and the restored `items` table contained the expected row:

```text
1 | production test
```

The temporary restore-test database was then dropped. The live production database and its persistent volume were not deleted as part of this test.

**Operational limitation:** The current retention policy is based on file age (seven days). A backup file existing on NFS is not by itself proof that a restore will succeed, so periodic restore tests remain important.

## 10. GitHub handoff

The application files were copied into the team repository:

- Repository: `https://github.com/RobertoTormo/CCDS`
- Branch: `adrian/core-app-production`

The branch was created from `main`, and the application files were staged for a commit and push. The user subsequently reported that the push was completed.

The staged application set contained these eight files:

```text
app/.gitignore
app/backup/backup.sh
app/compose.dev.yml
app/core/Dockerfile
app/core/app.py
app/core/requirements.txt
app/production.yml
app/static/html/index.html
```

The `.env` file, secret file and database dumps were excluded from the staged file list.

The team should review the branch and agree on the final integrated deployment configuration before merging to `main`.

## 11. Integration coordination

Items to coordinate with the other workstreams:

### Reverse proxy / Moodle / TLS

- Confirm the `/api` route and prefix-stripping behavior.
- Agree on hostnames and TLS configuration.
- Ensure the final proxy configuration does not conflict with the Core router.
- Agree on how the Core and Moodle/Atenea stacks are deployed together.

### Monitoring / auto-feeder

- Use the correct health endpoint: `/health` internally or `/api/health` through the proxy.
- Confirm network connectivity before using internal service DNS names.
- Agree on the JSON payload for `POST /api/items`, for example `{"name":"example"}`.
- Test monitoring and application recovery after a task restart.

### Infrastructure

- Confirm registry reachability from all Swarm nodes.
- Confirm the shared networks and external NFS volume are available before stack deployment.
- Document the combined deployment and shutdown procedures.

## 12. Known limitations and remaining work

1. **Database high availability:** PostgreSQL is configured as one replica pinned to `balkan1`. This is not a replicated database or automatic database failover arrangement.
2. **Redis high availability:** Redis is a single replica pinned to `balkan1`.
3. **Registry transport:** The registry uses internal HTTP rather than TLS.
4. **Backup cadence:** The production backup loop runs daily and keeps matching dump files for seven days. The team should confirm that this meets project requirements.
5. **Integrated end-to-end test:** The Core component's individual checks passed, but a final test with all teammates' components running together should still be performed.
6. **Documentation:** This document should be committed with the application branch and updated if the final integrated configuration changes.
7. **Production credential hygiene:** Rotate any credential that was exposed in logs or reused inappropriately.

## 13. Quick operational reference

### Check the stack

```bash
docker stack services coreprod
docker service ps coreprod_core
docker service logs --tail 50 coreprod_backup
```

### Test the API through the proxy

```bash
curl -i http://localhost:81/api/health
curl -i http://localhost:81/api/items
```

### Validate the production stack configuration

Run from the app directory after loading the private `.env` variables:

```bash
set -a
. ./.env
set +a
docker stack config -c production.yml >/dev/null
```

Do not share the output of a fully rendered stack configuration if it includes environment values or credentials.

### Deploy the production stack

```bash
docker stack deploy -c production.yml coreprod
```

Run this only when the necessary external networks, volume and Swarm secret exist, and after reviewing the proposed configuration change.

### Backup restore principle

Restore a dump into a separate test database first. Verify the schema and expected rows before relying on the backup for recovery. Do not test restoration by overwriting the live production database.

---

## Summary

The Core Application and Data workstream provides a containerized Flask API, PostgreSQL persistence, Redis caching, development and production configuration, Swarm secret-based production credentials, and automated PostgreSQL backups to shared NFS. The application image `core-app:1.2` was deployed with two Core replicas. API health, data retrieval, automatic schema initialization on a fresh database, backup archive validity, and a test restore were reported successful.

The main remaining task is integration with the team's proxy, Moodle/Atenea, monitoring and infrastructure components, followed by a shared end-to-end test and final documentation review.
