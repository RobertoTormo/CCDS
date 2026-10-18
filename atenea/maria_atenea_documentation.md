# Atenea Stack (Moodle LMS + database) — Implementation Documentation

**Project:** CCDS (Cloud Computing and Distributed Systems)
**Component owner:** Maria
**Repository:** https://github.com/RobertoTormo/CCDS — folder `atenea/`
**Swarm stack name:** `atenea`
**Public URL:** https://moodle.balkan-ccds.duckdns.org (TLS terminated by `basic_nginx`)

---

## 1. Scope and responsibilities

Containerisation of the Learning Management System of Figure 1 (*atenea*: Moodle + db), for local development and for production on Docker Swarm, including persistent data, secrets and backups.

## 2. Architecture

| Service | Image | Replicas | Networks | Role |
|---|---|---|---|---|
| `moodle` | `oksigenia/moodle:5.3.0-r16` | 2 | `frontend` (alias `atenea-moodle`), `atenea_backend` | web (Apache + PHP), cron disabled |
| `moodle-cron` | same image, `command: cron` | 1 | `atenea_backend` | Moodle scheduled tasks |
| `moodle-redis` | `redis:7-alpine` | 1 | `atenea_backend` | PHP sessions + Moodle application cache |
| `balkandb` | `mariadb:11.4` | 1 (pinned to `balkan1`) | `atenea_backend` | Moodle database |
| `backup` | `mariadb:11.4` | 1 | `atenea_backend` | daily DB dump + moodledata archive |

Request flow: browser → `https://moodle.balkan-ccds.duckdns.org` → `basic_nginx` (TLS) → `atenea-moodle:8080` on the `frontend` network → one of the `moodle` replicas → `balkandb` / `moodle-redis` on the private `atenea_backend` network.

## 3. Design decisions and justification

**Moodle 5.3 + MariaDB 11.4.** Moodle 5.3 is the current stable release (LTS); it requires MariaDB ≥ 11.4, so `mariadb:11.4` was chosen. The assignment lists MariaDB among the supported DBMS. The database service is named `balkandb`; MariaDB is the DBMS technology.

**Image `oksigenia/moodle`.** A maintained image with the official, unmodified Moodle code, multi-arch (amd64/arm64: works on the Apple Silicon laptop and on the x86_64 VMs), configured entirely through environment variables, with `_FILE` variants for Docker secrets and a separate cron mode. Pinned to the immutable tag `5.3.0-r16` (CONVENTIONS §6, slide 4: tags for rollouts and rollbacks; `5.3` is rebuilt weekly and would change under us).

**Scalability: web separated from cron.** The assignment requires every service to be scalable except CronJobs and DBMS. Moodle's cron must run once, not once per replica, so the web replicas run with `MOODLE_CRON=off` and a dedicated `moodle-cron` service (1 replica) runs the scheduled tasks. The image coordinates containers sharing the same volumes so that only one performs upgrades.

**Shared state for multiple replicas.**
- `moodledata` (uploaded files) is on NFS, so every replica on any node sees the same files.
- Sessions and cache are in Redis (`MOODLE_REDIS_HOST`): file sessions on NFS are fragile with several replicas (file locking). Redis holds shared volatile data (slide 5): no persistence, no backup — losing it only logs users out.
- Moodle code (`/var/www/moodle`) is **not** a volume: it comes from the image, identical in every replica (slide 5: what is not data belongs to the image). Plugins would be added with a `Dockerfile` `FROM oksigenia/moodle`, never installed from the web UI.

**Database: local volume pinned to one node, protected by dumps.** A DBMS does not scale horizontally (slide 4: "do you think we can scale the database service?"). Database files are not put on NFS because of locking/corruption risks with shared storage (slide 5: "share data… data corruption?"). `balkandb` runs on `balkan1` (placement constraint) with a local volume — the same strategy used for the core app's PostgreSQL — and disaster recovery relies on dumps (slide 5: "for DBMS you may need specific dumps").

**Secrets.** Passwords are Docker Swarm secrets (`balkandb_password`, `balkandb_root_password`, `moodle_admin_password`), mounted in memory at `/run/secrets/…` and passed with the `_FILE` variables. They are not in the image, not in environment variables, not in git, and the admin password is never printed in the logs (slide 5: what is not data is image, environment variable, config or secret).

**Network isolation.** Only `moodle` joins the shared `frontend` network; the database and Redis are only on the private overlay `atenea_backend` and are unreachable from the proxy (CONVENTIONS §3, least privilege). No service publishes ports in production.

**HTTPS behind a proxy.** `MOODLE_URL=https://moodle.balkan-ccds.duckdns.org` with `MOODLE_SSL_PROXY=auto`: Moodle knows TLS ends at nginx, avoiding redirect loops and mixed content. nginx forwards `X-Forwarded-Proto`.

**Compose → Swarm differences.** `restart` → `deploy.restart_policy`; `depends_on` is ignored by `docker stack deploy`, which is harmless because the image waits for the database before starting.

## 4. Data and volumes

| Volume | Service | Content | Data type (slide 5) | Critical? | Backup? How? | Why |
|---|---|---|---|---|---|---|
| `atenea_balkandb_data` (local, `balkan1`) | balkandb | MariaDB files: users, courses, grades, settings | persistent | yes | yes, daily `mariadb-dump --single-transaction` by `backup` | essential, not recomputable |
| `atenea_moodle_files` (NFS `/srv/nfs/shared/atenea/moodledata`) | moodle, moodle-cron, backup (ro) | uploaded files, Moodle data directory | persistent (+ caches) | yes | yes, daily `tar.gz` without `cache`, `localcache`, `temp`, `sessions` | uploaded files are critical; caches are recomputable |
| `atenea_atenea_backups` (NFS `/srv/nfs/shared/atenea/backups`) | backup | dumps and archives, last 7 days | backup copies | yes | — | it is the backup |
| — (Redis memory) | moodle-redis | sessions, application cache | shared volatile | no | no | can be discarded at any time |

### Backup and restore

The `backup` service runs every 24 h (first run 2 minutes after start): consistent SQL dump of `balkandb` (`--single-transaction`, no table locks) and archive of moodledata, both compressed, older than 7 days deleted.

Restore procedure (documented, not yet rehearsed):

```bash
# 1. maintenance mode
docker exec -u www-data $(docker ps -qf name=atenea_moodle | head -1) moodle-cli maintenance --enable
# 2. database (on balkan1)
gunzip -c /srv/nfs/shared/atenea/backups/balkandb_<TS>.sql.gz | \
  docker exec -i $(docker ps -qf name=atenea_balkandb) \
  sh -c 'mariadb -uroot -p"$(cat /run/secrets/balkandb_root_password)" balkandb'
# 3. files
sudo tar -xzf /srv/nfs/shared/atenea/backups/moodledata_<TS>.tar.gz -C /srv/nfs/shared/atenea/moodledata
# 4. maintenance off
docker exec -u www-data $(docker ps -qf name=atenea_moodle | head -1) moodle-cli maintenance --disable
```

## 5. Deployment

### Production (Swarm, from the repository clone on the manager `balkan1`)

One-time prerequisites:

```bash
sudo mkdir -p /srv/nfs/shared/atenea/moodledata /srv/nfs/shared/atenea/backups
# secrets: see atenea/secrets/README.md (random passwords generated on the VM, git-ignored)
```

**First deploy** — only one web replica and no cron while Moodle installs itself into the empty database (two replicas would run two installations on the same database at the same time):

```bash
MOODLE_REPLICAS=1 MOODLE_CRON_REPLICAS=0 docker stack deploy -c atenea/production.yml atenea
docker service logs -f atenea_moodle     # wait for "Installation completed successfully"
```

**Every later deploy** (2 web replicas + cron):

```bash
git pull origin main
docker stack deploy -c atenea/production.yml atenea
```

Mail: Moodle sends through the relay `basic-smtp:587` (configured once in *Site administration → Server → Email*; the image applies `MOODLE_SMTP_*` variables only at first install).

### Local (Compose)

```bash
cp atenea/.env.example atenea/.env   # set the passwords (MOODLE_DB_PASSWORD = MARIADB_PASSWORD)
docker compose -f atenea/compose.yml up -d
# http://localhost:8300  (port range 83xx, bound to 127.0.0.1 only)
```

Note: MariaDB stores the user password in its volume at first initialisation; changing `.env` afterwards does not change it (this happened during development and was fixed with `ALTER USER`).

## 6. Tests performed (18 October 2026)

| Test | Result |
|---|---|
| Local: `docker compose up`, browser on `localhost:8300` | Moodle installed, admin login OK |
| Production first deploy | log: `Installation completed successfully`, `application cache stored in Redis at moodle-redis:6379`, `Moodle is ready at https://moodle.balkan-ccds.duckdns.org` |
| Scaling (`docker service ps atenea_moodle`) | 2 replicas Running on `balkan2` and `balkan3`; `balkandb` on `balkan1` |
| HTTPS access + admin login | OK |
| Backup | `DB dump OK` and `moodledata archive OK`; files present on NFS |
| E-mail (*Test outgoing mail configuration*) | delivered via `basic-smtp` → Gmail |

## 7. Known limitations

- **Database availability:** `balkandb` is pinned to `balkan1`; if that node fails, Moodle is unavailable until the node returns or the database is restored from the last dump on another node (RPO up to 24 h).
- **Backups are on the NFS server, which also runs on `balkan1`.** They survive the loss of a container or of the database volume, but not the loss of `balkan1`. A copy to external storage (e.g. Azure Blob) would be needed for a real off-site backup.
- **The restore procedure has not been rehearsed yet.**
- **Redis is a single replica:** if it restarts, logged-in users must log in again (no data loss).
