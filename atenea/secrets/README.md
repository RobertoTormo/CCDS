# Secrets for the atenea stack (production)

These files are read by `docker stack deploy` and turned into Docker Swarm
secrets, mounted in the containers at `/run/secrets/<name>` (in memory, never
in the image nor in environment variables). They are git-ignored.

Create them once, on the manager node, from the repo root:

```bash
mkdir -p atenea/secrets
openssl rand -base64 24 | tr -d '\n' > atenea/secrets/balkandb_password.txt
openssl rand -base64 24 | tr -d '\n' > atenea/secrets/balkandb_root_password.txt
openssl rand -base64 18 | tr -d '\n' > atenea/secrets/moodle_admin_password.txt
chmod 600 atenea/secrets/*.txt
```

The Moodle admin user is `admin`; its password is in `moodle_admin_password.txt`.
