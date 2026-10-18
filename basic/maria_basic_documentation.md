# Basic Stack (Frontend, TLS, SMTP) — Implementation Documentation

**Project:** CCDS (Cloud Computing and Distributed Systems)
**Component owner:** Maria
**Repository:** https://github.com/RobertoTormo/CCDS — folder `basic/`
**Swarm stack name:** `basic`
**Public domain:** `balkan-ccds.duckdns.org` (DuckDNS → public IP of `balkan1`, 68.221.168.102)

---

## 1. Scope and responsibilities

This part covers the shared entry point of the whole infrastructure (stack *basic* in Figure 1 of the assignment):

- **Frontend reverse proxy** (`nginx`): the only service reachable from the Internet, on ports 80/443. It routes requests to the services of the other stacks.
- **TLS** (`certbot`): obtains and renews a Let's Encrypt certificate for the frontend.
- **SMTP relay** (`smtp`): forwards e-mails from internal services to a mail provider (Gmail).

The Swarm cluster, the private registry (`10.0.0.4:5000`), the NFS server (`balkan1:/srv/nfs/shared`) and the shared overlay networks are team infrastructure: this stack consumes them.

## 2. Architecture

```
Internet ──80/443──► basic_nginx (2 replicas, ingress routing mesh, any node)
                         │  network "frontend" (overlay, shared between stacks)
                         ├── /api/...               ──► core:5000          (app stack, Adrian)
                         ├── /grafana/...           ──► stats_grafana:3000 (stats stack, Roberto)
                         ├── moodle.<domain>        ──► atenea-moodle:8080 (atenea stack, Maria)
                         └── /.well-known/acme-challenge/ ──► files written by certbot

basic_certbot (1 replica) ── writes certificate + challenge files ──► NFS volumes
basic_smtp    (2 replicas) ◄── "basic-smtp:587" from internal services ──► smtp.gmail.com:587
```

| Service | Image | Replicas | Published ports | Networks |
|---|---|---|---|---|
| `nginx` | `10.0.0.4:5000/basic-nginx:2` (own Dockerfile) | 2 | 80, 443 | `frontend` |
| `certbot` | `certbot/certbot:v5.8.0` | 1 | none | `basic_default` |
| `smtp` | `boky/postfix:5.1.0-alpine` | 2 | none | `frontend` (alias `basic-smtp`) |

### Routing table

| URL | Target | Notes |
|---|---|---|
| `http://*` | 301 → `https://` | except `/.well-known/acme-challenge/` (Let's Encrypt) |
| `https://balkan-ccds.duckdns.org/` | static text `balkan-ccds frontend OK` | health page of the frontend |
| `https://balkan-ccds.duckdns.org/api/…` | `core:5000/…` (prefix `/api` removed) | same contract the core app already had in Traefik |
| `https://balkan-ccds.duckdns.org/grafana/…` | `stats_grafana:3000/grafana/…` | path kept: Grafana runs with `GF_SERVER_SERVE_FROM_SUB_PATH=true`; WebSockets enabled |
| `https://app.balkan-ccds.duckdns.org/` | `core:5000` | alternative host for the core app |
| `https://grafana.balkan-ccds.duckdns.org/` | 301 → `/grafana/` | |
| `https://moodle.balkan-ccds.duckdns.org/` | `atenea-moodle:8080` | Moodle works best at the root of a host |

## 3. Design decisions and justification

**nginx as the frontend.** The assignment requires "an nginx/Apache/similar proxying to other services". A Traefik service already existed on the cluster (ports 81/8080, used for early tests); it was left untouched, but the public entry point on 80/443 is nginx, as in Figure 1. nginx does not need the Docker socket, so it can run on any node and scale; the configuration is code inside the image (slide 3: Dockerfile → reproducibility, infrastructure as code).

**Only the frontend publishes ports.** Every other service is reached through overlay networks (CONVENTIONS §5; slide 4 "Compose: scale": a service with published ports cannot be scaled by Compose). In Swarm, ports are published in *ingress* mode on all nodes (slide 6), so the 2 nginx replicas can run on any node while the Azure NSG only opens 80/443 on `balkan1`.

**Shared network `frontend` instead of `proxy`.** CONVENTIONS proposed an external network `proxy`, but the cluster already had the overlay network `frontend`, with the core app attached to it (alias `core`). Reusing it avoided redeploying the other stacks. Services are addressed by unique names (`core`, `stats_grafana`, `atenea-moodle`, `basic-smtp`) to avoid name collisions between stacks.

**Upstreams resolved at request time.** nginx uses Docker's embedded DNS (`resolver 127.0.0.11`) and `proxy_pass` with variables, so it starts even if a backend is not deployed yet (that route answers 502 until it exists). Stacks can therefore be deployed in any order.

**TLS with Let's Encrypt (HTTP-01).** `certbot` uses the *webroot* method: Let's Encrypt connects to port 80 of the domain and reads a challenge file served by nginx. This is the reason the frontend must own port 80 (the previous test service `web` on port 80 was removed after agreement with the team). One certificate covers `balkan-ccds.duckdns.org`, `app.`, `moodle.` and `grafana.` (DuckDNS resolves all sub-domains to the same IP).

**Certificates on NFS, nginx scalable, certbot as a CronJob.** The certificate and the challenge files live on two NFS volumes (`letsencrypt`, `certbot_www`), so certbot (running on one node) and every nginx replica (on any node) see the same files. certbot is a periodic job (renewal check every 12 h, renewal only if < 30 days left), hence 1 replica: the assignment allows non-scalable CronJob services.

**Zero-touch certificate reload.** At start, the image script `40-certs.sh` uses the Let's Encrypt certificate if present, otherwise a temporary self-signed one (so nginx always starts). Every 5 minutes it checks whether the certificate changed and runs `nginx -s reload`, which swaps the certificate without dropping connections. No manual step is needed after issuance or renewal.

**Registry not exposed.** CONVENTIONS listed `registry.<domain>`, but the registry has no authentication: exposing it would allow anyone on the Internet to push images. It stays reachable only inside the cluster (`10.0.0.4:5000`).

**SMTP relay in the basic stack.** Figure 1 draws SMTP inside the *app* stack; since this task was assigned to the frontend owner, the relay was placed in *basic*, the stack of services shared by everyone. It accepts mail only from private networks (`MYNETWORKS`) and only from our sender domains (`ALLOWED_SENDER_DOMAINS`), has no published port, and authenticates to Gmail with an *app password*. It is stateless (a mail stays in the queue only for the seconds needed to hand it to Gmail: shared volatile data, slide 5), so it runs with 2 replicas.

**Image versions pinned.** `basic-nginx:1` → `:2` when the routing changed (CONVENTIONS §6; slide 4 "scaled rollouts or rollback": rolling back is changing the tag). Third-party images are pinned too. `update_config: parallelism: 1` replaces one nginx replica at a time, so the site stays up during updates.

## 4. Data and volumes

| Volume | Service | Content | Data type (slide 5) | Critical? | Backup? | Why |
|---|---|---|---|---|---|---|
| `basic_letsencrypt` (NFS `/srv/nfs/shared/letsencrypt`) | certbot (rw), nginx (ro) | certificate, private key, ACME account | shared volatile, recomputable | no | no | if lost, certbot obtains a new certificate automatically (slide 5: "a TLS certificate: if you lose it you can generate it again") |
| `basic_certbot_www` (NFS `/srv/nfs/shared/certbot-www`) | certbot (rw), nginx (ro) | temporary ACME challenge files | volatile | no | no | only needed for a few seconds during validation |
| — (Postfix queue inside the container) | smtp | mails waiting to be relayed | volatile | no | no | delivered within seconds; not persisted |

Not data (slide 5): nginx configuration → in the image; domain → environment variable; Gmail credentials → `basic/smtp.env` (git-ignored, see §7).

## 5. Deployment

### Production (Swarm, from the repository clone on the manager `balkan1`)

One-time prerequisites:

```bash
# NFS folders for the certificate volumes
sudo mkdir -p /srv/nfs/shared/letsencrypt /srv/nfs/shared/certbot-www
# SMTP credentials (git-ignored): Gmail address + 16-character app password
cp basic/smtp.env.example basic/smtp.env && nano basic/smtp.env && chmod 600 basic/smtp.env
```

Build and push the nginx image (built on an x86_64 node, so it matches the cluster architecture; the registry is only reachable from the cluster):

```bash
docker build -t 10.0.0.4:5000/basic-nginx:2 basic/nginx
docker push 10.0.0.4:5000/basic-nginx:2
```

Deploy / update:

```bash
git pull origin main
docker stack deploy -c basic/production.yml basic
```

Moodle uses the relay with: *Site administration → Server → Email → Outgoing mail configuration* → SMTP hosts `basic-smtp:587`, security *None*, no username/password (the relay only accepts internal networks and authenticates to Gmail itself).

### Local (Compose)

```bash
docker compose -f basic/compose.yml up -d --build
# http://localhost:8080 → redirect → https://localhost:8443 (self-signed certificate)
```

Local mode has no Let's Encrypt, no NFS and binds ports only on `127.0.0.1` (range `80xx`, CONVENTIONS §5), as required ("compose.yml … without TLS nor mapped volumes").

## 6. Tests performed (18 October 2026)

| Test | Result |
|---|---|
| Certificate issuance (`docker service logs basic_certbot`) | `Successfully received certificate`, expires 2027-01-16 |
| nginx placement (`docker service ps basic_nginx`) | 2 replicas Running on `balkan2` and `balkan3` → NFS volumes and registry work across nodes |
| `https://balkan-ccds.duckdns.org/` | `balkan-ccds frontend OK`, valid certificate |
| `http://balkan-ccds.duckdns.org/` | redirected to HTTPS |
| `https://balkan-ccds.duckdns.org/api/` | `{"service":"core-app","status":"running"}` |
| `https://balkan-ccds.duckdns.org/grafana/` | 502 before the stats stack existed, Grafana UI after its deployment |
| `https://moodle.balkan-ccds.duckdns.org/` | Moodle login page |
| Rolling update `basic-nginx:1` → `:2` | completed without downtime |
| SMTP from Moodle (*Test outgoing mail configuration*) | Postfix log: `status=sent (250 2.0.0 OK …)`, mail received |

## 7. Known limitations

- **Gmail credentials are passed with `env_file`.** They are kept out of git, but they are visible in the service definition (`docker service inspect`) to anyone with manager access. The image does not document `_FILE`/Docker secrets support; a wrapper entrypoint reading a Swarm secret would be the next improvement.
- **Single public IP / NSG rule on `balkan1`.** If `balkan1` is down, the routing mesh on the other nodes still works, but DNS and the NSG point only to `balkan1`. A cloud load balancer in front of the three nodes would remove this single point of failure.
- **Let's Encrypt rate limits:** repeated certificate requests for the same names are limited per week; `--keep-until-expiring` avoids unnecessary requests.
- **The local compose file was not used during the production work**; it is provided for local development only.
