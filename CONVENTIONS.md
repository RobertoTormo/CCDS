# Team conventions — Lab 1 (Cloud Computing)

> **Status: PROPOSAL** — to be discussed and approved by the whole team.
> Items marked ❓ are open decisions.


## 1. Repository layout

```
lab1-cloud/
├── README.md            # How to deploy (deliverable #4)
├── CONVENTIONS.md       # This file
├── .gitignore
├── basic/               # frontend (nginx), letsencrypt, registry, NFS
│   ├── compose.yml      # local development
│   ├── production.yml   # Swarm deployment
│   ├── .env.example
│   └── <service>/       # one folder per service with a Dockerfile (build context)
├── app/                 # core app, db, redis, static, smtp, auto, dump backup
├── stats/               # grafana + companion
├── atenea/              # moodle + db
└── docs/                # documentation (architecture, data & backups, decisions)
```

**One compose pair per stack** (`compose.yml` + `production.yml`).
*Rationale:* it mirrors the four stacks of Figure 1; on Swarm each stack is
deployed with `docker stack deploy -c <stack>/production.yml <stack>`, so a
stack can be updated or rolled back without touching the others.

---

## 2. Stack names

| Stack | Swarm stack name | Owner |
|---|---|---|
| basic | `basic` | ❓ |
| app | `app` | ❓ |
| stats | `stats` | ❓ |
| atenea | `atenea` | ❓ |

---

## 3. Networks

| Network | Type | Who joins it | Purpose |
|---|---|---|---|
| `proxy` | shared, **external**, overlay in production | nginx + every service nginx must reach | Lets the frontend proxy to services in other stacks |
| `<stack>_backend` (e.g. `app_backend`) | internal to the stack | services of that stack, **databases only here** | Isolation: DBs are never reachable from the proxy network |

- `proxy` is created **once**, outside the stacks:
  - local: `docker network create proxy`
  - Swarm: `docker network create --driver overlay --attachable proxy`
- Every stack declares it as external:
  ```yaml
  networks:
    proxy:
      external: true
  ```
- **Service names on `proxy`**: on a network shared between stacks, short names
  can collide (e.g. two stacks both have a `db`). Every service attached to
  `proxy` declares an explicit, unique alias `<stack>-<service>`:
  ```yaml
  networks:
    proxy:
      aliases: [app-core]
  ```
  nginx always uses these aliases (`proxy_pass http://app-core:8000;`).
  ⚠️ To be verified during integration on Swarm.

*Rationale:* slide "Compose: networks" — separate default/backend networks;
least privilege for the databases.

---

## 4. Domain and routing

Domain: ❓ `<name>.duckdns.org`

| Subdomain | Service | Internal target |
|---|---|---|
| `app.<domain>` | core app | `app-core:<port>` |
| `app.<domain>/static/` | static files (apache) | `app-static:80` |
| `moodle.<domain>` | Moodle | `atenea-moodle:<port>` |
| `grafana.<domain>` | Grafana | `stats-grafana:3000` |
| `registry.<domain>` | Docker registry | `basic-registry:5000` |
| ❓ | auto | ❓ (does it need an HTTP endpoint?) |

*Rationale for subdomains instead of paths:* Moodle and Grafana work best when
served at the root of a host; serving them under `/moodle/` requires extra
configuration on both nginx and the application.

---

## 5. Ports

- **Production:** only nginx publishes ports (80, 443). No other service has
  `ports:` → every service can be scaled (slide "Compose: scale": a service with
  published ports cannot scale with compose).
- **Local (`compose.yml`):** each owner may publish ports on `localhost` to test
  their stack alone. Use these ranges to avoid clashes on the same laptop:
  basic `80xx`, app `81xx`, stats `82xx`, atenea `83xx`.

---

## 6. Images

- Name: `<registry>/<stack>-<service>:<version>` (e.g. `registry.<domain>/app-core:1`)
- **Never `:latest` in `production.yml`.** Integer versions, incremented at
  every change (slide "Compose: scaled rollouts or rollback").
- Third-party images are pinned to a version too (e.g. `postgres:16`, not `postgres:latest`).
- Our VMs are **x86_64**, some laptops are Apple Silicon (ARM): images pushed to
  the registry must be built for `linux/amd64`:
  ```bash
  docker build --platform linux/amd64 -t <registry>/app-core:1 app/core
  ```

---

## 7. Secrets and configuration

- **Never commit secrets** (passwords, keys, tokens). They stay in a local
  `.env` file, which is git-ignored.
- Each stack commits a `.env.example` with the variable names and fake values.
- ❓ In production, consider Docker Swarm `secrets` / `configs` instead of
  environment variables (slide "About data": what is not data is part of the
  image, an environment variable, a config, or a secret).

---

## 8. Volumes and data

Volume name: `<service>_<content>` (e.g. `db_data`, `moodle_files`).

Every volume is documented in `docs/data.md` with this template:

| Volume | Service | Content | Data type (slide "About data") | Critical? | Backup? How? | Why |
|---|---|---|---|---|---|---|
| `db_data` | app db | PostgreSQL files | persistent | yes | yes, SQL dump by `dump-backup` | essential, not recomputable |
| `cache` | redis | cache | shared volatile | no | no | can be discarded at any time |

Data types to use: *persistent / volatile recomputable / shared volatile (cache) /
logs / not data (→ image, env, config, secret)*.

---

## 9. Git workflow

- `main` always contains a working version.
- Work on a branch per stack/feature (`basic/nginx`, `app/core`, …) and merge
  via pull request; at least one other member reads it.
- Commit messages in English, short and descriptive.

---

## 10. Documentation

- Language: ❓ English (same as the course material).
- Each owner documents their own services in `docs/`: what it does, image used
  and why, networks, volumes, how it scales (or why it does not).
