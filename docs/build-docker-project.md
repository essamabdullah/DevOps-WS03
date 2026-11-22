# Step-by-Step Build Guide: Enterprise Docker Infrastructure (Project 02)

Nov 18, 2026 · @Essam Abdullah

## How to use this guide

Build the stack bottom-up, one service at a time: dependencies first, the entry point last. Each service is added to the same `docker-compose.yml`, started on its own, verified, and only then do you move on.

Build order:

1. **MariaDB** (no dependencies, holds state)
2. **Memcached** (no dependencies, stateless)
3. **RabbitMQ** (no dependencies, holds state)
4. **Tomcat** (needs all three above)
5. **NGINX** (needs Tomcat)

For every service you repeat the same four-part loop. This loop is the real skill the project is teaching:

1. **Write** the files (config, Dockerfile, compose block).
2. **Run** only that service: `docker compose up -d --build <service>`.
3. **Verify** it works: health status, logs, a functional test.
4. **Harden and re-verify**: non-root, `cap_drop: [ALL]`, `no-new-privileges`, `read_only`, limits. If something breaks, read the logs, find the one permission or path it needs, and grant only that.

Every service gets its own Dockerfile, even the ones built on official images. The pattern is always the same: start `FROM` the official image, add your files, set `USER` and `HEALTHCHECK`. The Dockerfile describes what the image *is*; the compose block describes how it *runs* in this deployment.

| Setting | Where it goes | Why |
| --- | --- | --- |
| Base image, config files, application code | Dockerfile | Baked into the image and versioned with it |
| Default user (`USER`) | Dockerfile, repeated as `user:` in compose | The image is safe by default; compose makes it explicit and wins if they differ |
| Health check (`HEALTHCHECK`) | Dockerfile, repeated as `healthcheck:` in compose | Same: image default, compose override |
| Internal port (`EXPOSE`) | Dockerfile | Documentation only, publishes nothing |
| Published ports, networks, volumes | Compose | Depend on the deployment, not the image |
| Secrets and environment values | Compose | Must never be inside an image |
| `read_only`, `cap_drop`, `no-new-privileges`, limits, restart | Compose only | Runtime settings: a Dockerfile cannot set them |

Two habits that save hours:

- Before you set `user:` for an official image, ask the image which user it was built for, for example `docker run --rm --entrypoint id mariadb:10.11 mysql`. Never guess UIDs.
- When a container misbehaves, run `docker compose logs -f <service>` first and `docker inspect <container>` second. Almost every failure in this project is a permission, a path, or a network name.

All commands assume Ubuntu 22.04/24.04 and that you are inside the project folder `enterprise-docker-infrastructure/`.

## Step 0: Prepare the host and the project skeleton

The goal of this step is a working Docker host plus every file that is shared by all five services: networks, volumes, secrets and non-secret settings.

### 0.1 Install Docker Engine and the Compose plugin

```bash
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh
sudo usermod -aG docker $USER
newgrp docker            # or log out and back in

docker version
docker compose version   # must be v2.x ("docker compose", not "docker-compose")
docker run --rm hello-world
```

Security note: membership in the `docker` group is equivalent to root on the host. Only add trusted users.

### 0.2 Create the directory structure

```bash
mkdir -p enterprise-docker-infrastructure && cd enterprise-docker-infrastructure
mkdir -p nginx mariadb memcached rabbitmq secrets scripts docs backups \
         tomcat/app/src/main/java/com/example tomcat/app/src/main/webapp
touch docker-compose.yml .env .env.example .gitignore README.md secrets/.gitkeep
```

Two deliberate changes from the brief. First, every service gets its own folder with a Dockerfile, including a new memcached folder. Second, instead of a prebuilt `tomcat/application.war`, you will build the WAR from a small source project in `tomcat/app/` inside a multi-stage Dockerfile. If your course gives you a ready WAR, you can skip the build stage and copy the WAR directly (shown in Step 4).

### 0.3 Keep secrets out of Git

`.gitignore`:

```gitignore
# real configuration and credentials
.env
secrets/*
!secrets/.gitkeep

# build output and backups
tomcat/app/target/
tomcat/vprofile-project/
*.war
backups/
```

Verify before your first commit: `git status` must not list anything inside `secrets/` except `.gitkeep`.

### 0.4 Non-secret settings: `.env` and `.env.example`

Compose reads `.env` automatically and substitutes `${VARIABLES}` in the compose file. Put names here, never passwords.

`.env.example` (committed) and `.env` (local copy, ignored):

```bash
DB_NAME=accounts                 # vprofile schema (use appdb for the sample app)
DB_USER=appuser
RABBITMQ_USER=appuser
REPO_URL=https://github.com/hkhcoder/vprofile-project.git
REPO_BRANCH=main
```

```bash
cp .env.example .env
```

### 0.5 Generate the secret files

```bash
chmod 700 secrets
gen() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 24; }

gen > secrets/db_root_password.txt
gen > secrets/db_password.txt
gen > secrets/rabbitmq_password.txt

# RabbitMQ reads its default user from a config snippet, so build one from the same password
printf 'default_user = %s\ndefault_pass = %s\n' "appuser" "$(cat secrets/rabbitmq_password.txt)" \
  > secrets/rabbitmq_credentials.conf

chmod 644 secrets/*.txt secrets/*.conf
ls -la secrets/
```

Why these permissions: Compose (without Swarm) bind-mounts each secret file into the container with the file's host permissions. The containers run as non-root UIDs (999, 10001 and so on) that do not own the file, so the file itself must be world-readable (644). The protection comes from the directory: `secrets/` is 700, so no other user on the host can reach the files. The `default_user` value must match `RABBITMQ_USER` in `.env`.

### 0.6 The compose skeleton

Start `docker-compose.yml` with everything the services will share. You will add one service at a time under `services:`.

```yaml
name: enterprise          # fixes the project name, so volumes are enterprise_db_data etc.

services:
  # added step by step

networks:
  frontend:               # NGINX <-> Tomcat
    driver: bridge
  backend:                # Tomcat <-> MariaDB, Memcached, RabbitMQ
    driver: bridge
    internal: true        # no route to or from the outside world

volumes:
  db_data:
  rabbitmq_data:

secrets:
  db_root_password:
    file: ./secrets/db_root_password.txt
  db_password:
    file: ./secrets/db_password.txt
  rabbitmq_password:
    file: ./secrets/rabbitmq_password.txt
  rabbitmq_credentials:
    file: ./secrets/rabbitmq_credentials.conf
```

What `internal: true` means: containers on `backend` can talk to each other, but Docker creates no gateway to the host or the internet for that network. Tomcat still reaches the outside through `frontend`, which is fine; the databases cannot reach anything except their neighbours.

**Done when:** `docker run --rm hello-world` works, the folders exist, the secrets are generated, and `git status` shows no secret files.

## Step 1: MariaDB (database)

MariaDB comes first because Tomcat needs it and it is the service where data loss hurts most. You will use the official image, run it as its built-in `mysql` user, feed it passwords from secret files, and keep it on the backend network only.

### 1.1 Find the image's own user

```bash
docker pull mariadb:10.11
docker run --rm --entrypoint id mariadb:10.11 mysql
# uid=999(mysql) gid=999(mysql) groups=999(mysql)
```

That is the UID you will put in `user:`. The brief's `10001` is only an example; official images own their data directories with their own UID, so you reuse it.

### 1.2 Write `mariadb/init.sql`

Scripts in `/docker-entrypoint-initdb.d/` run once, on the very first start, when the data volume is empty. The entrypoint has already created the database and the app user from the environment variables, and runs this file inside that database.

```sql
CREATE TABLE IF NOT EXISTS visits (
  id         BIGINT AUTO_INCREMENT PRIMARY KEY,
  visited_at DATETIME NOT NULL
);

-- Optional least privilege: the entrypoint grants ALL on the app database.
-- Uncomment to narrow it (names must match DB_NAME / DB_USER in .env).
-- REVOKE ALL PRIVILEGES ON appdb.* FROM 'appuser'@'%';
-- GRANT SELECT, INSERT, UPDATE, DELETE ON appdb.* TO 'appuser'@'%';
```

```bash
chmod 644 mariadb/init.sql
```

Deploying vprofile? Replace this `init.sql` with the repository's `src/main/resources/db_backup.sql`, as shown in 4.6. It creates the tables and the login user the application expects.

### 1.3 Write `mariadb/Dockerfile`

```dockerfile
# Start from the official image: you add your files and defaults on top.
# 10.11 LTS, not 11.x: vprofile's MySQL driver breaks on MariaDB 11 (see below).
FROM mariadb:10.11

# Bake the schema into the image. Root owns it, the mysql user can only read it.
COPY --chown=root:root --chmod=644 init.sql /docker-entrypoint-initdb.d/01-init.sql

# Default to the built-in mysql user (UID 999) instead of root
USER 999:999

# Documentation only: the port the server listens on inside the network
EXPOSE 3306

# Image-level health check; a compose healthcheck: overrides it
HEALTHCHECK --interval=10s --timeout=5s --retries=5 --start-period=60s \
  CMD healthcheck.sh --connect --innodb_initialized || exit 1
```

**Why MariaDB 10.11 and not 11.x (found the hard way).** vprofile ships MySQL Connector/J 8.0.32. MariaDB 10.x introduces itself to clients as `5.5.5-10.x`; MariaDB 11 dropped that prefix and reports `11.4`. The driver then thinks it is talking to MySQL 8+, sends a MySQL-only metadata query (`INFORMATION_SCHEMA.KEYWORDS ... RESERVED`) that MariaDB rejects, and Hibernate crashes at startup with a `NullPointerException` in `JdbcServicesImpl.configure`. The database looks perfectly healthy from every other angle, which makes this hard to spot. Matching the database to the version the app was built for (10.11 LTS) fixes it without touching the application.

If you already ran 11.x, MariaDB cannot open that data directory with 10.11: remove the volume once (`docker compose rm -f mariadb && docker volume rm enterprise_db_data`) and let `init.sql` rebuild it.

Read it line by line:

- `FROM mariadb:10.11`: pin a version tag, never `latest`, so a rebuild next month gives the same database.
- `COPY --chown --chmod`: the schema travels with the image instead of being a loose bind-mounted file. `--chmod` needs BuildKit, the default builder since Docker 23.
- `USER 999:999`: numeric IDs, not the name `mysql`, so tools such as Kubernetes `runAsNonRoot` can verify the user is not root.
- `HEALTHCHECK`: any container started from this image is monitored, even with plain `docker run`.

What is deliberately **not** in this file: no password (`ENV MARIADB_PASSWORD=...` would be readable by anyone with `docker image inspect`), no `VOLUME` (the base image already declares `/var/lib/mysql`), and no `read_only` or capability settings (those exist only at runtime).

Build and inspect the image on its own before compose uses it:

```bash
docker build -t enterprise/mariadb:1.0 ./mariadb
docker image inspect enterprise/mariadb:1.0 \
  --format 'user={{.Config.User}} health={{json .Config.Healthcheck.Test}}'
# user=999:999 health=["CMD-SHELL","healthcheck.sh --connect --innodb_initialized || exit 1"]
docker history enterprise/mariadb:1.0 | head -6   # your layers on top of the official ones
```

### 1.4 Add the service to `docker-compose.yml`

```yaml
services:
  mariadb:
    build:
      context: ./mariadb                  # folder with Dockerfile + init.sql
    image: enterprise/mariadb:1.0         # name for the built image
    user: "999:999"                       # same as the Dockerfile USER, stated explicitly
    environment:
      MARIADB_ROOT_PASSWORD_FILE: /run/secrets/db_root_password
      MARIADB_DATABASE: ${DB_NAME}
      MARIADB_USER: ${DB_USER}
      MARIADB_PASSWORD_FILE: /run/secrets/db_password
    secrets:
      - db_root_password
      - db_password
    volumes:
      - db_data:/var/lib/mysql            # init.sql is now inside the image
    networks:
      - backend                           # no ports: section at all
    read_only: true
    tmpfs:
      - /tmp
      - /run/mysqld                       # socket and pid file
    cap_drop: [ALL]
    security_opt:
      - no-new-privileges:true
    healthcheck:                          # overrides the Dockerfile HEALTHCHECK
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 60s
    deploy:
      resources:
        limits:
          cpus: "1.0"
          memory: 768M
    restart: unless-stopped
```

What each hardening line does here:

- `user: "999:999"`: the entrypoint normally starts as root and drops to `mysql` with `gosu`. Starting directly as 999 skips that, so no root step ever happens.
- `cap_drop: [ALL]`: because the process never switches user and already owns its data, it needs no capabilities (no `SETUID`, `SETGID` or `CHOWN`).
- `read_only: true` + `tmpfs`: the image filesystem is frozen. Only three places are writable: the data volume, `/tmp` and `/run/mysqld` (tmpfs mounts are mode 1777 by default, so UID 999 can write there).
- `*_FILE` variables: the entrypoint reads the password from the file, so the password never appears in `docker inspect` or in the compose file.

Learning tip: for your very first run, comment out `read_only`, `tmpfs`, `cap_drop` and `security_opt`, confirm it works, then put them back and confirm again. That is exactly the "validate before enforcing" step the brief asks for.

### 1.5 Run and verify

```bash
docker compose config --quiet && echo "compose file OK"
docker compose up -d --build mariadb
docker compose logs -f mariadb        # wait for "ready for connections", Ctrl+C to leave
docker compose ps                     # STATUS must become "Up ... (healthy)"
```

Functional test, logged in as the app user (not root):

```bash
docker compose exec mariadb sh -c \
  'mariadb -u"$MARIADB_USER" -p"$(cat /run/secrets/db_password)" "$MARIADB_DATABASE" -e "SHOW TABLES; SELECT CURRENT_USER();"'
# expect: visits   and   appuser@%
```

Security checks:

```bash
docker compose top mariadb            # UID column: 999 for mariadbd, never root
docker compose exec mariadb id        # uid=999(mysql)
docker compose exec mariadb touch /etc/x   # must fail: Read-only file system
docker inspect enterprise-mariadb-1 \
  --format 'caps={{.HostConfig.CapDrop}} opts={{.HostConfig.SecurityOpt}} ro={{.HostConfig.ReadonlyRootfs}}'
sudo ss -tlnp | grep 3306 || echo "3306 not published on the host: good"
```

Important gotcha: the passwords and `init.sql` are applied only when `db_data` is empty. If you change a secret later, MariaDB keeps the old one. In the lab you can reset with `docker compose down -v` (this deletes all database data), or change the password with `ALTER USER` inside the database.

**Done when:** `mariadb` is healthy, the app user can query `visits`, the process runs as 999, and port 3306 is not on the host.

## Step 2: Memcached (cache)

Memcached is the easiest service to harden fully: it is stateless, writes nothing to disk, and needs no secrets. It is a good place to practise the loop quickly.

### 2.1 Inspect the image

```bash
docker pull memcached:1.6-alpine
docker run --rm --entrypoint sh memcached:1.6-alpine -c 'id; which nc'
# uid=11211(memcache) gid=11211(memcache)   and   /usr/bin/nc
```

The image already runs as `memcache` (UID 11211). Setting `user:` explicitly still matters: it documents the intent and protects you if a future image tag changes its default. `nc` (from BusyBox) is what the health check will use.

### 2.2 Write `memcached/Dockerfile`

```dockerfile
FROM memcached:1.6-alpine

# Explicit non-root user, even though the base image already uses it:
# your image stays safe even if a future base tag changes its default
USER 11211:11211

EXPOSE 11211

# Default runtime flags: 128 MB cache, 1024 connections, 2 threads
CMD ["memcached", "-m", "128", "-c", "1024", "-t", "2"]

# Shell form, because the check needs a pipe
HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=10s \
  CMD echo stats | nc -w 2 127.0.0.1 11211 | grep -q uptime || exit 1
```

Two Dockerfile ideas this file teaches:

- **Exec form vs shell form.** `CMD ["memcached", ...]` (JSON array) runs the program directly, so it receives stop signals and shuts down cleanly. `HEALTHCHECK CMD echo stats | nc ...` (plain string) runs through `/bin/sh -c`, which is needed here because a pipe is a shell feature.
- **Defaults in the image, overrides in compose.** The cache size lives in `CMD`. If one environment needs a bigger cache, compose can override it with `command:` without rebuilding the image.

Build it and watch the health check work without compose:

```bash
docker build -t enterprise/memcached:1.0 ./memcached
docker run -d --name mc-test enterprise/memcached:1.0
sleep 35                                           # first check runs after one interval
docker inspect -f '{{.State.Health.Status}}' mc-test   # healthy
docker exec mc-test id                             # uid=11211(memcache)
docker rm -f mc-test
```

### 2.3 Add the service

```yaml
  memcached:
    build:
      context: ./memcached
    image: enterprise/memcached:1.0
    user: "11211:11211"
    # no command: needed, the Dockerfile CMD sets the flags
    networks:
      - backend
    read_only: true
    cap_drop: [ALL]
    security_opt:
      - no-new-privileges:true
    healthcheck:
      test: ["CMD-SHELL", "echo stats | nc -w 2 127.0.0.1 11211 | grep -q uptime"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s
    deploy:
      resources:
        limits:
          cpus: "0.25"
          memory: 192M
    restart: unless-stopped
```

Notes:

- `CMD-SHELL` in compose is the equivalent of the Dockerfile's shell-form `HEALTHCHECK`. Keeping both identical means the image behaves the same with or without compose.
- Size the container limit above the cache size (`-m 128`). Memcached also uses memory for connections and threads; if the limit equals the cache size, the kernel OOM-kills it under load.
- No `tmpfs` is needed: Memcached never writes to the filesystem, so `read_only: true` works as is.
- No volume, by design: a cache that survives restarts can serve stale data. The brief explicitly says no persistence here.

### 2.4 Run and verify

```bash
docker compose up -d --build memcached
docker compose ps memcached          # (healthy)
docker compose top memcached         # UID 11211
```

Test it the way Tomcat will reach it: by service name, from another container on the backend network.

```bash
docker run --rm --network enterprise_backend busybox sh -c \
  "printf 'set k 0 60 5\r\nhello\r\nget k\r\nquit\r\n' | nc -w 2 memcached 11211"
# STORED / VALUE k 0 5 / hello / END
```

This also proves Docker's built-in DNS: the name `memcached` resolves only for containers attached to `enterprise_backend`.

**Done when:** Memcached is healthy, runs as 11211, answers `set` and `get` by service name, and has no published port.

## Step 3: RabbitMQ (message broker)

RabbitMQ combines the two hard parts of the previous services: it keeps state on a volume like MariaDB, and it needs credentials. It adds one trap of its own, the node name, which you must pin or your data appears to vanish on every recreate.

### 3.1 Inspect the image

```bash
docker pull rabbitmq:3.13-management
docker run --rm --entrypoint id rabbitmq:3.13-management rabbitmq
# uid=999(rabbitmq) gid=999(rabbitmq)
```

The `-management` tag includes the web UI on port 15672. You will not publish it; it stays reachable only inside the backend network. (3.13 matches the course diagram but no longer receives community support. For anything beyond this lab, use a 4.x tag such as rabbitmq:4.1-management; the files in this guide work with it unchanged.)

### 3.2 Write `rabbitmq/rabbitmq.conf`

```ini
listeners.tcp.default = 5672
management.tcp.port   = 15672

# the built-in guest user may only log in from localhost
loopback_users.guest = true

# log to stdout only, so nothing is written to the read-only filesystem
log.console       = true
log.console.level = info
log.file          = false

# respect the container memory limit (512 MiB) instead of the host's RAM
total_memory_available_override_value = 536870912
vm_memory_high_watermark.relative     = 0.6
```

```bash
chmod 644 rabbitmq/rabbitmq.conf
```

Credentials do not go in this file. They live in `secrets/rabbitmq_credentials.conf` (created in Step 0), which is mounted as a secret into RabbitMQ's `conf.d/` directory. RabbitMQ merges `rabbitmq.conf` with every file in `/etc/rabbitmq/conf.d/`.

Why not `RABBITMQ_DEFAULT_PASS_FILE`? The `_FILE` variables were removed from the official image in 3.9, so a config snippet delivered as a secret is the clean way to keep the password out of the environment.

### 3.3 Write `rabbitmq/Dockerfile`

```dockerfile
FROM rabbitmq:3.13-management

# Non-secret broker configuration, baked in; the broker user can read but not change it
COPY --chown=root:root --chmod=644 rabbitmq.conf /etc/rabbitmq/rabbitmq.conf

# Run as the built-in rabbitmq user (UID 999); the entrypoint then skips its root-only steps
USER 999:999

# 5672 = AMQP for the app, 15672 = management UI (internal only, never published)
EXPOSE 5672 15672

HEALTHCHECK --interval=30s --timeout=10s --retries=5 --start-period=60s \
  CMD rabbitmq-diagnostics -q ping || exit 1
```

The split to remember: `rabbitmq.conf` has no secrets, so it is copied into the image. `rabbitmq_credentials.conf` holds the password, so it is never copied; compose mounts it as a secret at runtime. A good test of your Dockerfile: you could push this image to a public registry and leak nothing.

Trade-off to note in your docs: with the config baked in, changing `rabbitmq.conf` means rebuilding the image (`docker compose up -d --build rabbitmq`). In exchange, the image you tested is exactly the image you run, with no loose files on the host.

```bash
docker build -t enterprise/rabbitmq:1.0 ./rabbitmq
docker image inspect enterprise/rabbitmq:1.0 --format 'user={{.Config.User}} ports={{json .Config.ExposedPorts}}'
docker run --rm --entrypoint cat enterprise/rabbitmq:1.0 /etc/rabbitmq/rabbitmq.conf   # your config is inside
```

### 3.4 Add the service

```yaml
  rabbitmq:
    build:
      context: ./rabbitmq       # Dockerfile + rabbitmq.conf
    image: enterprise/rabbitmq:1.0
    user: "999:999"
    hostname: rabbitmq          # pins the node name rabbit@rabbitmq (see below)
    secrets:
      - source: rabbitmq_credentials
        target: /etc/rabbitmq/conf.d/90-credentials.conf
    volumes:
      - rabbitmq_data:/var/lib/rabbitmq   # rabbitmq.conf is now inside the image
    networks:
      - backend
    read_only: true
    tmpfs:
      - /tmp
    cap_drop: [ALL]
    security_opt:
      - no-new-privileges:true
    healthcheck:
      test: ["CMD", "rabbitmq-diagnostics", "-q", "ping"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s
    deploy:
      resources:
        limits:
          cpus: "1.0"
          memory: 512M
    restart: unless-stopped
```

The `hostname` line is the trap mentioned above. RabbitMQ stores its data in `/var/lib/rabbitmq/mnesia/rabbit@<hostname>`. Without a fixed hostname, every recreated container gets a new random hostname, starts a brand-new empty database, and your queues and messages seem lost, even though they are still on the volume.

`read_only: true` is worth trying here because logs go to stdout and data goes to the volume. If startup fails with a write error, read the path in `docker compose logs rabbitmq`, add that path under `tmpfs:`, and record the finding in `docs/security.md`. If you cannot make it work, remove `read_only` for this service only and document why; the brief allows exceptions when they are justified.

### 3.5 Run and verify

```bash
docker compose up -d --build rabbitmq
docker compose logs -f rabbitmq            # wait for "Server startup complete"
docker compose ps rabbitmq                 # (healthy), may take up to a minute
docker compose top rabbitmq                # beam.smp runs as UID 999

docker compose exec rabbitmq rabbitmqctl list_users
# appuser  [administrator]     <- and no guest user
```

If `list_users` shows only `guest`, RabbitMQ never saw your credentials file. Check that it really is where RabbitMQ reads it:

```bash
docker compose exec rabbitmq sh -c 'ls /etc/rabbitmq/conf.d/; sed "s/default_pass.*/default_pass = ***/" /etc/rabbitmq/conf.d/90-credentials.conf'
# 10-defaults.conf  90-credentials.conf
# default_user = appuser
# default_pass = ***
```

The folder is `conf.d`, not `config.d`. A typo in the secret's `target` gives no error at all: Docker mounts the file where you point it and RabbitMQ silently ignores a folder it does not know. After fixing the target, remember that `default_user` is applied only to an empty volume, so either recreate `rabbitmq_data` or create the user once by hand:

```bash
docker compose exec rabbitmq rabbitmqctl add_user appuser "$(cat secrets/rabbitmq_password.txt)"
docker compose exec rabbitmq rabbitmqctl set_permissions -p / appuser ".*" ".*" ".*"
docker compose exec rabbitmq rabbitmqctl delete_user guest
```

Persistence test (do it now, before Tomcat exists):

```bash
docker compose exec rabbitmq rabbitmqctl add_vhost persist-test
docker compose up -d --force-recreate rabbitmq
# wait until healthy again, then:
docker compose exec rabbitmq rabbitmqctl list_vhosts     # persist-test is still there
docker compose exec rabbitmq rabbitmqctl delete_vhost persist-test
```

Try the same test once with the `hostname:` line removed. Seeing the vhost disappear is the fastest way to understand why it matters.

Optional least-privilege step: the default user gets the `administrator` tag, which the application does not need. Add `default_user_tags.administrator = false` to `rabbitmq.conf` (before first start, or with `rabbitmqctl set_user_tags appuser` afterwards) and use `rabbitmqctl` inside the container for administration.

**Done when:** RabbitMQ is healthy, runs as 999, `appuser` exists and `guest` does not, and a vhost survives `--force-recreate`.

## Step 4: Tomcat (Java application)

Tomcat is the first service where you write your own image. You will build a small Java web app with two endpoints, package it in a multi-stage Dockerfile, and run it as a dedicated user that cannot even modify its own code.

The app gives you exactly what the brief requires: `/health` for the container health check, and `/status`, which talks to MariaDB, Memcached and RabbitMQ so you can prove AC-04, AC-05 and AC-06. If your course provides its own application, keep its WAR and see 4.4 for the one-line change, but it must still expose a `/health` endpoint.

### 4.1 The application source (`tomcat/app/`)

`tomcat/app/pom.xml`:

```xml
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>
  <groupId>com.example</groupId>
  <artifactId>app</artifactId>
  <version>1.0.0</version>
  <packaging>war</packaging>

  <properties>
    <maven.compiler.release>17</maven.compiler.release>
    <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>
  </properties>

  <dependencies>
    <dependency> <!-- provided by Tomcat 10.1 at runtime -->
      <groupId>jakarta.servlet</groupId>
      <artifactId>jakarta.servlet-api</artifactId>
      <version>6.0.0</version>
      <scope>provided</scope>
    </dependency>
    <dependency>
      <groupId>org.mariadb.jdbc</groupId>
      <artifactId>mariadb-java-client</artifactId>
      <version>3.4.1</version>
    </dependency>
    <dependency>
      <groupId>net.spy</groupId>
      <artifactId>spymemcached</artifactId>
      <version>2.12.3</version>
    </dependency>
    <dependency>
      <groupId>com.rabbitmq</groupId>
      <artifactId>amqp-client</artifactId>
      <version>5.21.0</version>
    </dependency>
  </dependencies>

  <build>
    <finalName>app</finalName>
    <plugins>
      <plugin>
        <groupId>org.apache.maven.plugins</groupId>
        <artifactId>maven-war-plugin</artifactId>
        <version>3.4.0</version>
        <configuration>
          <failOnMissingWebXml>false</failOnMissingWebXml>
        </configuration>
      </plugin>
    </plugins>
  </build>
</project>
```

`tomcat/app/src/main/java/com/example/Config.java` reads plain settings from environment variables and passwords from secret files:

```java
package com.example;

import java.nio.file.Files;
import java.nio.file.Path;

final class Config {
    private Config() {}

    static String env(String name, String fallback) {
        String v = System.getenv(name);
        return (v == null || v.isBlank()) ? fallback : v;
    }

    /** Reads a secret from the file named by an env var, e.g. DB_PASSWORD_FILE. */
    static String secret(String fileVar) {
        String path = System.getenv(fileVar);
        if (path == null) throw new IllegalStateException(fileVar + " is not set");
        try {
            return Files.readString(Path.of(path)).trim();
        } catch (Exception e) {
            // never put the secret value in a message or a log
            throw new IllegalStateException("cannot read secret file for " + fileVar);
        }
    }
}
```

`tomcat/app/src/main/java/com/example/HealthServlet.java`, the liveness endpoint. It deliberately checks nothing external: if MariaDB is down, restarting Tomcat would not help, so Tomcat should not report itself unhealthy.

```java
package com.example;

import jakarta.servlet.annotation.WebServlet;
import jakarta.servlet.http.HttpServlet;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;

@WebServlet("/health")
public class HealthServlet extends HttpServlet {
    @Override
    protected void doGet(HttpServletRequest req, HttpServletResponse resp) throws IOException {
        resp.setContentType("text/plain");
        resp.getWriter().println("UP");
    }
}
```

`tomcat/app/src/main/java/com/example/StatusServlet.java`, the dependency check. Each request writes a row, increments a cache counter and publishes a durable message:

```java
package com.example;

import com.rabbitmq.client.Channel;
import com.rabbitmq.client.ConnectionFactory;
import com.rabbitmq.client.MessageProperties;
import jakarta.servlet.annotation.WebServlet;
import jakarta.servlet.http.HttpServlet;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import net.spy.memcached.MemcachedClient;

import java.io.IOException;
import java.io.PrintWriter;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.ResultSet;
import java.sql.Statement;
import java.time.Instant;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.Callable;

@WebServlet("/status")
public class StatusServlet extends HttpServlet {

    private static final String QUEUE = "app.events";

    @Override
    protected void doGet(HttpServletRequest req, HttpServletResponse resp) throws IOException {
        Map<String, String> results = new LinkedHashMap<>();
        // single & so every check runs even if an earlier one fails
        boolean ok = check("mariadb", this::checkDatabase, results)
                   & check("memcached", this::checkCache, results)
                   & check("rabbitmq", this::checkBroker, results);
        resp.setStatus(ok ? 200 : 503);
        resp.setContentType("text/plain");
        PrintWriter out = resp.getWriter();
        results.forEach((k, v) -> out.println(k + ": " + v));
    }

    private static boolean check(String name, Callable<String> test, Map<String, String> results) {
        try {
            results.put(name, "OK " + test.call());
            return true;
        } catch (Exception e) {
            results.put(name, "FAIL " + e.getClass().getSimpleName() + ": " + e.getMessage());
            return false;
        }
    }

    private String checkDatabase() throws Exception {
        Class.forName("org.mariadb.jdbc.Driver"); // register the driver shipped in WEB-INF/lib
        String url = "jdbc:mariadb://" + Config.env("DB_HOST", "mariadb") + ":3306/"
                   + Config.env("DB_NAME", "appdb") + "?connectTimeout=3000";
        try (Connection c = DriverManager.getConnection(url,
                     Config.env("DB_USER", "appuser"), Config.secret("DB_PASSWORD_FILE"));
             Statement s = c.createStatement()) {
            s.executeUpdate("INSERT INTO visits (visited_at) VALUES (NOW())");
            try (ResultSet rs = s.executeQuery("SELECT COUNT(*) FROM visits")) {
                rs.next();
                return "(visits=" + rs.getLong(1) + ")";
            }
        }
    }

    private String checkCache() throws Exception {
        MemcachedClient mc = new MemcachedClient(
                new InetSocketAddress(Config.env("MEMCACHED_HOST", "memcached"), 11211));
        try {
            long hits = mc.incr("hits", 1, 1); // creates the key with 1 if it is missing
            return "(hits=" + hits + ")";
        } finally {
            mc.shutdown();
        }
    }

    private String checkBroker() throws Exception {
        ConnectionFactory f = new ConnectionFactory();
        f.setHost(Config.env("RABBITMQ_HOST", "rabbitmq"));
        f.setUsername(Config.env("RABBITMQ_USER", "appuser"));
        f.setPassword(Config.secret("RABBITMQ_PASSWORD_FILE"));
        f.setConnectionTimeout(3000);
        try (com.rabbitmq.client.Connection conn = f.newConnection();
             Channel ch = conn.createChannel()) {
            ch.queueDeclare(QUEUE, true, false, false, null);           // durable queue
            ch.basicPublish("", QUEUE, MessageProperties.PERSISTENT_TEXT_PLAIN, // persistent message
                    ("visit at " + Instant.now()).getBytes(StandardCharsets.UTF_8));
            return "(queued=" + ch.messageCount(QUEUE) + ")";
        }
    }
}
```

`tomcat/app/src/main/webapp/index.html`:

```html
<!doctype html>
<html><head><meta charset="utf-8"><title>Enterprise Docker Lab</title></head>
<body>
  <h1>Enterprise Docker Lab</h1>
  <p><a href="status">/status</a> checks MariaDB, Memcached and RabbitMQ.
     <a href="health">/health</a> is the liveness probe.</p>
</body></html>
```

About the brief's "application-level retries": every `/status` request opens fresh connections, so the app recovers by itself as soon as a dependency comes back. A production app would use a connection pool (for example HikariCP) with retry settings; you will test this behaviour in 4.5.

### 4.2 Check the base image

```bash
docker pull tomcat:10.1-jre17
docker run --rm tomcat:10.1-jre17 sh -c 'id; which curl'
```

The image runs as root by default, which is why you create your own user. If `which curl` prints nothing, add this line to the runtime stage below, before `USER`:

```dockerfile
RUN apt-get update && apt-get install -y --no-install-recommends curl && rm -rf /var/lib/apt/lists/*
```

### 4.3 Write `tomcat/Dockerfile`

```dockerfile
# ---------- Stage 1: build (Maven + full JDK, never shipped) ----------
FROM maven:3.9-eclipse-temurin-17 AS build
WORKDIR /src
COPY app/pom.xml .
RUN mvn -q -B dependency:go-offline          # cached layer: only reruns when pom.xml changes
COPY app/src ./src
RUN mvn -q -B package -DskipTests \
 && mkdir -p /out/ROOT \
 && cd /out/ROOT && jar -xf /src/target/app.war

# ---------- Stage 2: runtime (JRE + Tomcat only) ----------
FROM tomcat:10.1-jre17

# dedicated non-root user: fixed UID, no home, no login shell
RUN groupadd --gid 10001 app \
 && useradd --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app \
 && rm -rf /usr/local/tomcat/webapps/* \
 && mkdir -p /usr/local/tomcat/conf/Catalina/localhost

# deployed already unpacked, so Tomcat never writes into webapps/ (needed for read_only)
COPY --from=build /out/ROOT /usr/local/tomcat/webapps/ROOT

USER 10001:10001
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=60s \
  CMD curl -fsS http://localhost:8080/health || exit 1

CMD ["catalina.sh", "run"]
```

And `tomcat/.dockerignore`, so local build output never enters the build context:

```gitignore
app/target/
```

Three design decisions worth explaining in your documentation:

- **Multi-stage**: Maven, the JDK and the source code stay in the build stage. The final image contains only the JRE, Tomcat and the compiled app, which makes it smaller and gives an attacker fewer tools.
- **Root-owned app files**: the copied files belong to root and are only readable by UID 10001. Even if the app is compromised, it cannot change its own code.
- **Unpacked WAR**: Tomcat normally unpacks `ROOT.war` at startup, which is a write. Unpacking at build time is what makes `read_only: true` possible.

### 4.4 Add the service

```yaml
  tomcat:
    build:
      context: ./tomcat
    image: enterprise/tomcat-app:1.0
    user: "10001:10001"
    environment:
      DB_HOST: mariadb
      DB_NAME: ${DB_NAME}
      DB_USER: ${DB_USER}
      DB_PASSWORD_FILE: /run/secrets/db_password
      MEMCACHED_HOST: memcached
      RABBITMQ_HOST: rabbitmq
      RABBITMQ_USER: ${RABBITMQ_USER}
      RABBITMQ_PASSWORD_FILE: /run/secrets/rabbitmq_password
      JAVA_OPTS: "-XX:MaxRAMPercentage=75.0"   # JVM heap follows the container limit
    secrets:
      - db_password             # note: no root password for the app
      - rabbitmq_password
    expose:
      - "8080"                  # documentation only; there is no ports: section
    networks:
      - frontend
      - backend
    depends_on:
      mariadb:
        condition: service_healthy
      memcached:
        condition: service_healthy
      rabbitmq:
        condition: service_healthy
    read_only: true
    tmpfs:
      - /tmp
      - /usr/local/tomcat/temp
      - /usr/local/tomcat/work
      - /usr/local/tomcat/logs
    cap_drop: [ALL]
    security_opt:
      - no-new-privileges:true
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://localhost:8080/health"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 60s
    deploy:
      resources:
        limits:
          cpus: "1.0"
          memory: 768M
    restart: unless-stopped
```

Using your course's WAR instead: put it at `tomcat/application.war` and replace stage 1 with:

```dockerfile
FROM eclipse-temurin:17-jdk AS build
COPY application.war /tmp/app.war
RUN mkdir -p /out/ROOT && cd /out/ROOT && jar -xf /tmp/app.war
```

Then map that app's own settings (JDBC URL, cache and broker hosts) to the service names `mariadb`, `memcached` and `rabbitmq`.

### 4.5 Build, run and verify

```bash
docker compose build tomcat
docker compose up -d tomcat        # starts any stopped dependency and waits for it to be healthy
docker compose logs -f tomcat      # wait for "Server startup in [...] milliseconds"
docker compose ps                  # four services (healthy)
```

There is no published port yet, so test from inside the container:

```bash
docker compose exec tomcat curl -s localhost:8080/health
# UP
docker compose exec tomcat curl -s localhost:8080/status
# mariadb: OK (visits=1)
# memcached: OK (hits=1)
# rabbitmq: OK (queued=1)

docker compose exec rabbitmq rabbitmqctl list_queues name messages durable
# app.events  1  true
```

Security checks:

```bash
docker compose top tomcat                         # java runs as UID 10001
docker compose exec tomcat touch /usr/local/tomcat/webapps/ROOT/x   # must fail
docker image inspect enterprise/tomcat-app:1.0 --format '{{.Config.User}} {{json .Config.Env}}'
# 10001:10001 and no password in the image environment
docker image ls | grep -E 'tomcat-app|maven'      # compare runtime vs build image size
```

Retry test (the brief's "reconnect when dependencies recover"):

```bash
docker compose stop memcached
docker compose exec tomcat curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/status   # 503
docker compose start memcached
sleep 15
docker compose exec tomcat curl -s localhost:8080/status    # all OK again, Tomcat never restarted
```

**Done when:** Tomcat is healthy, runs as 10001, `/status` returns three OK lines, and the app recovers from a stopped dependency without a restart.

### 4.6 Variant: Dockerfile for the vprofile application

Use this instead of 4.1 to 4.4 if you deploy the course's vprofile app. It turns the VM provisioning script (install JDK and Maven, clone, build, deploy to Tomcat 9) into a Dockerfile, with three changes the brief requires:

- **No passwords at build time.** The script `sed`s the passwords into `application.properties` before `mvn install`, so they end up inside the WAR, which fails AC-14. Here the file is taken out of the WAR and generated at container start from the secret files.
- **No systemd.** A container runs one process in the foreground: `catalina.sh run` replaces the unit file.
- **Non-root and read-only**, as in the rest of the guide.

Still **Tomcat 9**, as in the script: vprofile uses `javax.*`, which Tomcat 10+ does not support.

#### How the configuration gets in

The container's root filesystem is read-only, so the entrypoint cannot edit `WEB-INF/classes/application.properties`. Instead:

1. At build time, `application.properties` is moved out of the WAR and kept as a template.
2. Tomcat's `common.loader` gets one extra directory, `/run/appconfig`, which is a tmpfs.
3. At every start, `entrypoint.sh` fills the template from environment variables and secret files and writes it to `/run/appconfig/`.
4. When Spring asks for `classpath:application.properties`, the web app no longer has it, so Tomcat's class loader finds it in `/run/appconfig`.

The secrets exist only in memory (tmpfs) inside the running container: not in the image, not in `docker inspect`, not in Git.

#### Get the source code (cloned on the host)

The source lives next to the Dockerfile, so every build stage is visible and you can read or debug the code:

```bash
cd tomcat
git clone -b main https://github.com/hkhcoder/vprofile-project.git vprofile-project
cd ..
ls tomcat/vprofile-project               # pom.xml  src/

# the keys entrypoint.sh will replace
grep -E '^(jdbc|memcached|rabbitmq)' tomcat/vprofile-project/src/main/resources/application.properties
```

`tomcat/.dockerignore` keeps Git history and old build output out of the build context:

```gitignore
vprofile-project/.git
vprofile-project/target
```

Never put real passwords into `vprofile-project/src/main/resources/application.properties`: everything in that folder is copied into the image. The entrypoint fills in the real values at runtime.

#### `tomcat/Dockerfile` (vprofile)

```dockerfile
# syntax=docker/dockerfile:1
ARG JAVA_VERSION=11

# ---------- Stage 1: build the WAR from the cloned source ----------
FROM maven:3.9-eclipse-temurin-${JAVA_VERSION} AS build
ARG WAR_NAME=vprofile-v2.war
WORKDIR /src

COPY vprofile-project/pom.xml .
COPY vprofile-project/src ./src

# The cache mount keeps ~/.m2 between builds: dependencies download once,
# and the cache never ends up in the image
RUN --mount=type=cache,target=/root/.m2 \
    mvn -B -q package -DskipTests

# Unpack the WAR and take application.properties out: it becomes a runtime template
RUN mkdir -p /out/ROOT && cd /out/ROOT && jar -xf "/src/target/$WAR_NAME" \
 && mv WEB-INF/classes/application.properties /out/application.properties.template

# ---------- Stage 2: runtime (Tomcat 9 + JRE only) ----------
FROM tomcat:9.0-jre${JAVA_VERSION}

# Dedicated non-root user, clean webapps, and one extra class-loader directory
# (/run/appconfig, a tmpfs) where the generated application.properties will live
RUN groupadd --gid 10001 app \
 && useradd --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app \
 && rm -rf /usr/local/tomcat/webapps/* \
 && mkdir -p /usr/local/tomcat/conf/Catalina/localhost /opt/app \
 && sed -i 's|^common.loader=.*|&,"/run/appconfig"|' /usr/local/tomcat/conf/catalina.properties

COPY --from=build /out/ROOT /usr/local/tomcat/webapps/ROOT
COPY --from=build /out/application.properties.template /opt/app/application.properties.template
COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh

USER 10001:10001
EXPOSE 8080

# vprofile has no /health endpoint; /login returns 200 only once Spring has started
HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=90s \
  CMD curl -fsS -o /dev/null http://localhost:8080/login || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
```

`JAVA_VERSION=11` matches the VM provisioning: vprofile uses Spring 4.2 and Hibernate 4.3, which are safest on Java 11. A value under `build.args` in compose overrides this default, so keep both at 11.

Why there is no `mvn dependency:go-offline` caching layer: with vprofile it fails, because it also fetches optional dependencies (JasperReports needs `itext 2.1.7.js2` from old `http://` repositories) and Maven 3.8.1+ blocks HTTP repositories (`maven-default-http-blocker`). A normal `mvn package` skips those, and the cache mount gives the same speed-up.

**Alternative (Option A): clone inside the build.** Replace the two `COPY vprofile-project/...` lines with `ARG REPO_URL=https://github.com/hkhcoder/vprofile-project.git`, `ARG REPO_BRANCH=main`, an `apt-get install git` step and `RUN git clone --depth 1 -b "$REPO_BRANCH" "$REPO_URL" /src`. It builds straight from Git, which suits CI pipelines, but the source never appears on your machine and Docker caches the clone layer, so new commits need `docker compose build --no-cache tomcat`.

#### `tomcat/entrypoint.sh`

```sh
#!/bin/sh
# Builds application.properties from env vars + secret files, then starts Tomcat.
# Runs at every start, so nothing secret is ever stored in the image.
set -eu
umask 077
CONF=/run/appconfig/application.properties

DB_PASSWORD=$(cat "$DB_PASSWORD_FILE")
RABBITMQ_PASSWORD=$(cat "$RABBITMQ_PASSWORD_FILE")

sed \
  -e "s|^jdbc.url=jdbc:mysql://[^/]*/[^?]*|jdbc.url=jdbc:mysql://${DB_HOST}:3306/${DB_NAME}|" \
  -e "s|^jdbc.username=.*|jdbc.username=${DB_USER}|" \
  -e "s|^jdbc.password=.*|jdbc.password=${DB_PASSWORD}|" \
  -e "s|^memcached.active.host=.*|memcached.active.host=${MEMCACHED_HOST}|" \
  -e "s|^rabbitmq.address=.*|rabbitmq.address=${RABBITMQ_HOST}|" \
  -e "s|^rabbitmq.username=.*|rabbitmq.username=${RABBITMQ_USER}|" \
  -e "s|^rabbitmq.password=.*|rabbitmq.password=${RABBITMQ_PASSWORD}|" \
  /opt/app/application.properties.template > "$CONF"

echo "entrypoint: application.properties generated (values not printed)"
exec catalina.sh run
```

The `sed` lines replace the same keys as your script, plus the hostnames: `db01`, `mc01` and `rmq01` came from `/etc/hosts` on the VMs, while in Docker they are the service names `mariadb`, `memcached` and `rabbitmq`. Check the key names against your branch first with `grep -E '^(jdbc|memcached|rabbitmq)' src/main/resources/application.properties`. `exec` makes Tomcat replace the shell as PID 1, so `docker stop` reaches Java directly.

#### Changes outside the Tomcat folder

Your `.env` (Step 0) must contain `DB_NAME=accounts`. `REPO_URL` and `REPO_BRANCH` record which source you cloned (and feed Option A if you use it):

```bash
DB_NAME=accounts
REPO_URL=https://github.com/hkhcoder/vprofile-project.git   # same defaults as the Terraform variables
REPO_BRANCH=main
```

MariaDB needs the vprofile schema instead of the sample `visits` table. The schema ships in the repository:

```bash
cp tomcat/vprofile-project/src/main/resources/db_backup.sql mariadb/init.sql
docker compose stop tomcat mariadb
docker compose rm -f mariadb
docker volume rm enterprise_db_data      # init.sql only runs on an empty volume (deletes DB data)
docker compose up -d --build mariadb     # --build bakes the new init.sql into the image
```

Use the `mariadb:10.11` Dockerfile from Step 1.3; vprofile's driver does not work with MariaDB 11.

#### Compose block (vprofile)

```yaml
  tomcat:
    build:
      context: ./tomcat
      args:
        JAVA_VERSION: "11"            # same as the Dockerfile default
    image: enterprise/tomcat-app:1.0
    user: "10001:10001"
    environment:
      DB_HOST: mariadb
      DB_NAME: ${DB_NAME}
      DB_USER: ${DB_USER}
      DB_PASSWORD_FILE: /run/secrets/db_password
      MEMCACHED_HOST: memcached
      RABBITMQ_HOST: rabbitmq
      RABBITMQ_USER: ${RABBITMQ_USER}
      RABBITMQ_PASSWORD_FILE: /run/secrets/rabbitmq_password
      JAVA_OPTS: "-XX:MaxRAMPercentage=75.0"
    secrets: [db_password, rabbitmq_password]
    expose: ["8080"]
    networks: [frontend, backend]
    depends_on:
      mariadb:
        condition: service_healthy
      memcached:
        condition: service_healthy
      rabbitmq:
        condition: service_healthy
    read_only: true
    tmpfs:
      - /tmp
      - /usr/local/tomcat/temp
      - /usr/local/tomcat/work
      - /usr/local/tomcat/logs
      - /run/appconfig:mode=0700,uid=10001,gid=10001   # generated config, only the app user can read it
    cap_drop: [ALL]
    security_opt:
      - no-new-privileges:true
    healthcheck:
      test: ["CMD", "curl", "-fsS", "-o", "/dev/null", "http://localhost:8080/login"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 90s
    deploy:
      resources:
        limits:
          cpus: "1.0"
          memory: 768M
    restart: unless-stopped
```

#### Build, run and verify

```bash
docker compose build tomcat
docker compose up -d tomcat
docker compose logs -f tomcat     # "application.properties generated", then "Server startup in ..."
docker compose ps tomcat          # (healthy) after up to ~90 s

# the generated config points at the Docker service names (passwords not printed)
docker compose exec tomcat sh -c \
  'grep -E "^(jdbc.url|jdbc.username|memcached.active.host|rabbitmq.address)" /run/appconfig/application.properties'

docker compose exec tomcat curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/login   # 200
docker compose top tomcat         # java runs as UID 10001
```

AC-14 check: no password may appear anywhere in the image.

```bash
docker run --rm --entrypoint sh enterprise/tomcat-app:1.0 -c \
  'grep -rl "$0" /usr/local/tomcat/webapps /opt/app || echo "no secret in image"' "$(cat secrets/db_password.txt)"
```

Connectivity (AC-04 to AC-06), once NGINX is up in Step 5: log in through `http://<vm-ip>/` (the standard repository's `db_backup.sql` creates the user `admin_vp`), open the users list, and open a user twice. The first view says the data came from the database and was inserted into the cache, the second that it came from the cache (Memcached). The RabbitMQ page confirms the broker connection.

What changes elsewhere in the guide with vprofile: `/status` does not exist, so in `validate.sh` replace the `/status` check with `curl -s -o /dev/null -w '%{http_code}' http://localhost/login` expecting `200`, and do the database, cache and broker checks through the pages above.

Troubleshooting:

- `NullPointerException` at `JdbcServicesImpl.configure` while the database is healthy: MariaDB 11 with vprofile's MySQL Connector/J 8. Use `mariadb:10.11` (Step 1.3). To see the real database error in a case like this, test the connection directly with the app's own driver from a throwaway JDK container on the `enterprise_backend` network.
- `ACCESS_REFUSED - Login was refused` from RabbitMQ: the broker has no `appuser`. Check the `conf.d` mount and create the user (Step 3.5).
- Container stays `health: starting` then `unhealthy`, `/login` returns 404, but Java keeps running: the Spring context failed. Read the first `Caused by:` in `docker compose logs tomcat`, fix it, then `docker compose restart tomcat`. Docker does not restart an unhealthy container on its own.
- `Could not resolve placeholder 'jdbc.url'` or `application.properties cannot be opened`: the class-loader change did not apply. Check with `docker compose exec tomcat grep common.loader conf/catalina.properties`; the line must end in `"/run/appconfig"`.
- `Read-only file system` with a path in the logs: the app writes a log or temp file there. Add that exact path under `tmpfs:`.
- `Communications link failure`: Tomcat cannot reach MariaDB. Check that `DB_NAME=accounts` and that `mariadb` is healthy.
- Testing by IP: the port goes before the path (`http://172.19.0.2:8080/login`, not `/login:8080`), and `/` answers with an empty-bodied 302 redirect. Container IPs only work from the Docker host and change on recreate; test with `docker compose exec tomcat curl ...` or through NGINX.

## Step 5: NGINX (reverse proxy)

NGINX is the only container with a published port. It runs as UID 10001, listens on 8080 inside the container, and Docker maps host port 80 to it, so no process in any container ever needs root to bind a port.

### 5.1 Why 8080 inside and 80 outside

Ports below 1024 traditionally need root or the `NET_BIND_SERVICE` capability. Rather than add a capability back after `cap_drop: [ALL]`, the container listens on 8080 and `ports: "80:8080"` does the mapping on the host side. Users still type `http://your-server/`.

### 5.2 Write `nginx/nginx.conf`

A non-root NGINX cannot write to its default locations (`/var/run/nginx.pid`, `/var/cache/nginx/*`), so every writable path is moved to `/tmp`, which will be a tmpfs.

```nginx
worker_processes auto;
pid /tmp/nginx.pid;
error_log /dev/stderr warn;

events {
    worker_connections 1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    access_log    /dev/stdout;
    sendfile      on;
    server_tokens off;                      # hide the NGINX version

    # all temp paths on the tmpfs, so the root filesystem can be read-only
    client_body_temp_path /tmp/client_temp;
    proxy_temp_path       /tmp/proxy_temp;
    fastcgi_temp_path     /tmp/fastcgi_temp;
    uwsgi_temp_path       /tmp/uwsgi_temp;
    scgi_temp_path        /tmp/scgi_temp;

    upstream tomcat_backend {
        server tomcat:8080;                 # Docker service name, resolved by Docker DNS
        # server tomcat2:8080;              # add more instances here to load-balance
        keepalive 16;
    }

    server {
        listen 8080;
        server_name _;

        # NGINX's own health endpoint: does not touch Tomcat
        location = /nginx-health {
            access_log off;
            default_type text/plain;
            return 200 "ok\n";
        }

        location / {
            proxy_pass http://tomcat_backend;
            proxy_http_version 1.1;
            proxy_set_header Connection "";
            proxy_set_header Host              $host;
            proxy_set_header X-Real-IP         $remote_addr;
            proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_connect_timeout 5s;
            proxy_read_timeout    60s;
        }
    }
}
```

Note that there is no `user` directive: it only works when the master process starts as root, and here it never does.

### 5.3 Write `nginx/Dockerfile`

```dockerfile
FROM nginx:1.27-alpine

RUN addgroup -g 10001 -S app \
 && adduser -u 10001 -S -D -H -G app -s /sbin/nologin app \
 && rm -f /etc/nginx/conf.d/default.conf

COPY --chown=root:root --chmod=644 nginx.conf /etc/nginx/nginx.conf

USER 10001:10001
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=10s \
  CMD wget -q -O /dev/null http://127.0.0.1:8080/nginx-health || exit 1

CMD ["nginx", "-g", "daemon off;"]
```

Check the config before you even start a container:

```bash
docker build -t enterprise/nginx-proxy:1.0 ./nginx   # the compose block comes in 5.4
# NGINX resolves upstream names during the test, so join the network where "tomcat" exists
# (Tomcat must be running). Without --network you get: host not found in upstream "tomcat:8080"
docker run --rm --user 10001:10001 --network enterprise_frontend enterprise/nginx-proxy:1.0 nginx -t
# nginx: configuration file /etc/nginx/nginx.conf test is successful
```

### 5.4 Add the service

```yaml
  nginx:
    build:
      context: ./nginx
    image: enterprise/nginx-proxy:1.0
    user: "10001:10001"
    ports:
      - "80:8080"               # the ONLY published port in the whole project
    networks:
      - frontend                # not on backend: NGINX cannot see the databases
    depends_on:
      tomcat:
        condition: service_healthy
    read_only: true
    tmpfs:
      - /tmp
    cap_drop: [ALL]
    security_opt:
      - no-new-privileges:true
    healthcheck:
      test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1:8080/nginx-health"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s
    deploy:
      resources:
        limits:
          cpus: "0.50"
          memory: 128M
    restart: unless-stopped
```

The health check uses `127.0.0.1`, not `localhost`: in Alpine `localhost` can resolve to the IPv6 address `::1`, and this NGINX only listens on IPv4, so the check would fail for a confusing reason.

`depends_on` with `service_healthy` matters here for a second reason: NGINX resolves `tomcat` once at startup, and refuses to start if the name does not exist yet.

### 5.5 Run and verify

```bash
docker compose up -d nginx
docker compose ps                       # all five services (healthy)

curl -i http://localhost/nginx-health   # 200 ok, answered by NGINX alone
curl -i http://localhost/               # the index page, through Tomcat
curl http://localhost/status            # three OK lines, through the proxy
curl -sI http://localhost/ | grep -i '^server'   # "Server: nginx" without a version
```

From another machine, open `http://<vm-ip>/status`. If it does not load, check the VM firewall (`sudo ufw allow 80/tcp`) and your hypervisor's network settings.

Security checks:

```bash
docker compose top nginx                # master and workers all UID 10001
curl -s --max-time 3 http://localhost:8080/ || echo "Tomcat not reachable from the host: good"
docker compose exec nginx nc -z -w 2 mariadb 3306 \
  && echo "PROBLEM: nginx can reach mariadb" \
  || echo "nginx cannot reach mariadb: good (not on backend)"
```

**Done when:** all five containers are healthy, `http://<vm-ip>/status` works, NGINX runs as 10001, and NGINX cannot resolve the backend services.

## Step 6: Validate the whole stack against the acceptance criteria

With all five services running, prove each acceptance criterion with a command and save the output as your "security validation results" and "connectivity test results" deliverables. Run a clean rebuild first so you test what you will submit:

```bash
docker compose down            # keeps volumes
docker compose up -d --build
watch docker compose ps        # wait until all five show (healthy), Ctrl+C
```

| AC | What to check | Command | Expected |
| --- | --- | --- | --- |
| AC-01, AC-09 | All five up and healthy | `docker compose ps` | 5 lines, all `(healthy)` |
| AC-02, AC-03 | Access only through NGINX on 80 | `curl -i http://localhost/` | HTTP 200, page from Tomcat |
| AC-04, AC-05, AC-06 | Tomcat reaches DB, cache, broker | `curl http://localhost/status` | three `OK` lines |
| AC-07 | No root processes | `docker compose top` | no `root` in the UID column |
| AC-08 | Least privilege | `docker inspect` (CapDrop, SecurityOpt, ReadonlyRootfs) | `[ALL]`, `no-new-privileges:true` |
| AC-10 | Only NGINX publishes a port | `docker compose ps` (PORTS column) | only `0.0.0.0:80->8080/tcp` on nginx |
| AC-11 | Data survives recreation | Step 7 tests | rows and messages still there |
| AC-12 | Limits on every container | `docker stats --no-stream` | a MEM LIMIT per container, not host RAM |
| AC-13 | Recovery from a crash | Step 7 kill test | container restarts by itself |
| AC-14 | No credentials in images or Git | `validate.sh` + `git ls-files` | nothing found |
| AC-15 | Documentation | README review (Step 8) | deploy, validate, troubleshoot sections |

### 6.1 Automate the checks: `scripts/validate.sh`

```bash
#!/usr/bin/env bash
# Checks the running stack against the project acceptance criteria.
set -uo pipefail
cd "$(dirname "$0")/.."

SERVICES="nginx tomcat mariadb memcached rabbitmq"
PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
cid() { docker compose ps -q "$1"; }

echo "AC-01/09  running and healthy"
for s in $SERVICES; do
  c=$(cid "$s")
  if [ -z "$c" ]; then bad "$s is not running"; continue; fi
  h=$(docker inspect -f '{{.State.Health.Status}}' "$c")
  [ "$h" = "healthy" ] && ok "$s healthy" || bad "$s is $h"
done

echo "AC-02..06  application through NGINX"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://localhost/login)
[ "$code" = "200" ] && ok "NGINX -> Tomcat: /login returns 200" || bad "/login returned $code"
# open a TCP connection from inside Tomcat to each backend (bash /dev/tcp, no extra tools)
for target in mariadb:3306 memcached:11211 rabbitmq:5672; do
  docker compose exec -T tomcat bash -c "exec 3<>/dev/tcp/${target%:*}/${target#*:}" 2>/dev/null \
    && ok "tomcat -> $target" || bad "tomcat -> $target"
done

echo "RabbitMQ users"
docker compose exec -T rabbitmq rabbitmqctl -q list_users | grep -q "^appuser" \
  && ok "rabbitmq user appuser exists" || bad "rabbitmq user appuser missing"
docker compose exec -T rabbitmq rabbitmqctl -q list_users | grep -q "^guest" \
  && bad "default guest user still exists" || ok "no guest user"

echo "AC-07  non-root processes"
for s in $SERVICES; do
  docker compose top "$s" | awk '{print $1}' | grep -qx root \
    && bad "$s has a root process" || ok "$s has no root process"
done

echo "AC-08  hardening flags"
for s in $SERVICES; do
  c=$(cid "$s")
  caps=$(docker inspect -f '{{.HostConfig.CapDrop}}' "$c")
  sec=$(docker inspect -f '{{.HostConfig.SecurityOpt}}' "$c")
  ro=$(docker inspect -f '{{.HostConfig.ReadonlyRootfs}}' "$c")
  if [[ "$caps" == *ALL* && "$sec" == *no-new-privileges* ]]; then
    ok "$s cap_drop=ALL, no-new-privileges, read_only=$ro"
  else
    bad "$s caps=$caps security_opt=$sec"
  fi
done

echo "AC-10  published ports and isolation"
for s in $SERVICES; do
  p=$(docker port "$(cid "$s")" 2>/dev/null)
  if [ "$s" = "nginx" ]; then
    [ -n "$p" ] && ok "nginx publishes: $(echo $p)" || bad "nginx publishes nothing"
  else
    [ -z "$p" ] && ok "$s publishes nothing" || bad "$s publishes: $p"
  fi
done
docker compose exec -T nginx nc -z -w 2 mariadb 3306 >/dev/null 2>&1 \
  && bad "nginx can reach mariadb" || ok "nginx cannot reach the backend network"

echo "AC-12/13  limits and restart policy"
for s in $SERVICES; do
  c=$(cid "$s")
  mem=$(docker inspect -f '{{.HostConfig.Memory}}' "$c")
  cpu=$(docker inspect -f '{{.HostConfig.NanoCpus}}' "$c")
  pol=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$c")
  [ "$mem" -gt 0 ] && [ "$cpu" -gt 0 ] && ok "$s mem=$((mem/1048576))MiB cpus=$(awk "BEGIN{print $cpu/1e9}")" \
    || bad "$s has no limits"
  [ "$pol" = "unless-stopped" ] && ok "$s restart=$pol" || bad "$s restart=$pol"
done

echo "AC-14  no credentials in images or Git"
for img in enterprise/nginx-proxy:1.0 enterprise/tomcat-app:1.0 enterprise/mariadb:1.0 \
           enterprise/memcached:1.0 enterprise/rabbitmq:1.0; do
  meta=$(docker image inspect "$img"; docker history --no-trunc "$img")
  leak=0
  for f in secrets/*.txt; do echo "$meta" | grep -qF "$(cat "$f")" && leak=1; done
  [ $leak -eq 0 ] && ok "$img: no secret in config or history" || bad "$img contains a secret"
done
if git rev-parse --git-dir >/dev/null 2>&1; then
  tracked=$(git ls-files secrets .env | grep -v '\.gitkeep$')
  [ -z "$tracked" ] && ok "no secret files tracked by Git" || bad "tracked: $tracked"
fi

echo
echo "Result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
```

```bash
chmod +x scripts/validate.sh
./scripts/validate.sh | tee docs/validation-results.txt
```

### 6.2 Tune the resource limits

The brief asks you to analyse usage, not just set limits. Generate some load and watch:

```bash
for i in $(seq 1 200); do curl -s -o /dev/null http://localhost/status; done &
docker stats
```

Record peak MEM USAGE against MEM LIMIT for each service. A rule of thumb for the lab: keep normal peak below about 70% of the limit. If Tomcat sits near its limit, raise `memory` (the JVM heap follows via `MaxRAMPercentage`); if Memcached or NGINX use a fraction of theirs, lower them. Write the before and after numbers in `docs/security.md`.

**Done when:** `validate.sh` reports 0 failures and the output is saved in `docs/`.

## Step 7: Persistence, crash recovery and backups

These tests are destructive on purpose: you break things and prove the stack recovers. They cover AC-11 and AC-13 and give you the backup and recovery procedures the brief asks you to document.

### 7.1 Persistence across recreation (AC-11)

```bash
curl -s http://localhost/status                 # note visits=N and queued=M

docker compose up -d --force-recreate mariadb rabbitmq
watch docker compose ps                          # wait for both to be healthy again

curl -s http://localhost/status                 # visits=N+1, queued=M+1 or more
docker compose exec rabbitmq rabbitmqctl list_queues name messages durable
```

Then the full cycle: `docker compose down` followed by `docker compose up -d`. The data must still be there. Never add `-v` to `down` unless you mean it: `docker compose down -v` deletes `db_data` and `rabbitmq_data`.

Memcached is expected to lose its `hits` counter on recreation. That is the correct behaviour for a cache, and worth one sentence in your documentation.

### 7.2 Crash recovery (AC-13)

Simulate a real crash by killing the main process from the host. `docker stop` would not prove anything: Docker treats it as an intentional stop and `unless-stopped` will not restart the container.

```bash
docker inspect -f '{{.RestartCount}}' enterprise-tomcat-1          # e.g. 0
sudo kill -9 "$(docker inspect -f '{{.State.Pid}}' enterprise-tomcat-1)"
sleep 5
docker compose ps tomcat                                            # Up again, health: starting
docker inspect -f '{{.RestartCount}}' enterprise-tomcat-1          # 1
```

Repeat for each service. Then test a daemon restart, which simulates a host reboot:

```bash
sudo systemctl restart docker
watch docker compose ps        # all five return and become healthy
```

Document one limitation clearly: a container that is running but unhealthy is not restarted by Docker. The restart policy reacts only to the process exiting. In production this gap is closed by monitoring and alerting, or by an orchestrator such as Kubernetes.

### 7.3 Backups: `scripts/backup.sh`

```bash
#!/usr/bin/env bash
# Backs up MariaDB (logical dump) and RabbitMQ (definitions + data volume).
set -euo pipefail
cd "$(dirname "$0")/.."
umask 077                                   # backups contain password hashes
TS=$(date +%Y%m%d-%H%M%S)
DEST="backups/$TS"
mkdir -p "$DEST"

echo "MariaDB: logical dump of all databases"
docker compose exec -T mariadb sh -c \
  'MYSQL_PWD="$(cat /run/secrets/db_root_password)" exec mariadb-dump -uroot --all-databases --single-transaction --routines --events' \
  | gzip > "$DEST/mariadb-all.sql.gz"

echo "RabbitMQ: definitions (users, vhosts, queues, permissions)"
docker compose exec -T rabbitmq rabbitmqctl export_definitions - > "$DEST/rabbitmq-definitions.json"

echo "RabbitMQ: data volume (brief stop for a consistent copy)"
docker compose stop rabbitmq
docker run --rm -v enterprise_rabbitmq_data:/data:ro -v "$PWD/$DEST":/backup alpine \
  tar czf /backup/rabbitmq_data.tgz -C /data .
docker compose start rabbitmq

ls -lh "$DEST"
```

`MYSQL_PWD` keeps the root password out of the process list, where `-p<password>` would be visible. The script reads the password from the secret file inside the container, so it never appears in your shell history.

### 7.4 Restore drill

A backup you have never restored is only a hope. Run this once and record the result:

```bash
./scripts/backup.sh
TS=$(ls backups | tail -1)

# 1. damage the data
docker compose exec mariadb sh -c \
  'mariadb -u"$MARIADB_USER" -p"$(cat /run/secrets/db_password)" "$MARIADB_DATABASE" -e "DELETE FROM visits;"'

# 2. restore MariaDB
gunzip -c "backups/$TS/mariadb-all.sql.gz" | docker compose exec -T mariadb sh -c \
  'MYSQL_PWD="$(cat /run/secrets/db_root_password)" exec mariadb -uroot'

curl -s http://localhost/status     # visits is back to its old count + 1
```

Restoring the RabbitMQ volume follows the same pattern in reverse:

```bash
docker compose stop rabbitmq
docker run --rm -v enterprise_rabbitmq_data:/data -v "$PWD/backups/$TS":/backup alpine \
  sh -c 'find /data -mindepth 1 -delete && tar xzf /backup/rabbitmq_data.tgz -C /data && chown -R 999:999 /data'
docker compose start rabbitmq
```

The `chown` matters: RabbitMQ runs as 999 and must own its files after the restore.

**Done when:** data survives recreation and `down`/`up`, every service restarts after a kill, and you have restored a backup at least once.

## Step 8: Final compose file, deployment script, README and troubleshooting

You built the compose file one block at a time. Now refactor it: the four hardening lines are identical in every service, so move them into a YAML anchor and merge them in. The result behaves exactly the same and is easier to review.

### 8.1 Final `docker-compose.yml`

```yaml
name: enterprise

# shared hardening, merged into every service with <<: *hardening
x-hardening: &hardening
  read_only: true
  cap_drop: [ALL]
  security_opt:
    - no-new-privileges:true
  restart: unless-stopped

services:
  nginx:
    <<: *hardening
    build:
      context: ./nginx
    image: enterprise/nginx-proxy:1.0
    user: "10001:10001"
    ports:
      - "80:8080"
    networks: [frontend]
    depends_on:
      tomcat:
        condition: service_healthy
    tmpfs: [/tmp]
    healthcheck:
      test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1:8080/nginx-health"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s
    deploy:
      resources:
        limits: { cpus: "0.50", memory: 128M }

  tomcat:                    # vprofile variant (Step 4.6)
    <<: *hardening
    build:
      context: ./tomcat
      args:
        JAVA_VERSION: "11"   # vprofile (Spring 4.2) runs on Java 11
    image: enterprise/tomcat-app:1.0
    user: "10001:10001"
    environment:
      DB_HOST: mariadb
      DB_NAME: ${DB_NAME}
      DB_USER: ${DB_USER}
      DB_PASSWORD_FILE: /run/secrets/db_password
      MEMCACHED_HOST: memcached
      RABBITMQ_HOST: rabbitmq
      RABBITMQ_USER: ${RABBITMQ_USER}
      RABBITMQ_PASSWORD_FILE: /run/secrets/rabbitmq_password
      JAVA_OPTS: "-XX:MaxRAMPercentage=75.0"
    secrets: [db_password, rabbitmq_password]
    expose: ["8080"]
    networks: [frontend, backend]
    depends_on:
      mariadb:
        condition: service_healthy
      memcached:
        condition: service_healthy
      rabbitmq:
        condition: service_healthy
    tmpfs:
      - /tmp
      - /usr/local/tomcat/temp
      - /usr/local/tomcat/work
      - /usr/local/tomcat/logs
      - /run/appconfig:mode=0700,uid=10001,gid=10001
    healthcheck:
      test: ["CMD", "curl", "-fsS", "-o", "/dev/null", "http://localhost:8080/login"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 90s
    deploy:
      resources:
        limits: { cpus: "1.0", memory: 768M }

  mariadb:
    <<: *hardening
    build:
      context: ./mariadb
    image: enterprise/mariadb:1.0
    user: "999:999"
    environment:
      MARIADB_ROOT_PASSWORD_FILE: /run/secrets/db_root_password
      MARIADB_DATABASE: ${DB_NAME}
      MARIADB_USER: ${DB_USER}
      MARIADB_PASSWORD_FILE: /run/secrets/db_password
    secrets: [db_root_password, db_password]
    volumes:
      - db_data:/var/lib/mysql
    networks: [backend]
    tmpfs: [/tmp, /run/mysqld]
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 60s
    deploy:
      resources:
        limits: { cpus: "1.0", memory: 768M }

  memcached:
    <<: *hardening
    build:
      context: ./memcached
    image: enterprise/memcached:1.0
    user: "11211:11211"
    networks: [backend]
    healthcheck:
      test: ["CMD-SHELL", "echo stats | nc -w 2 127.0.0.1 11211 | grep -q uptime"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s
    deploy:
      resources:
        limits: { cpus: "0.25", memory: 192M }

  rabbitmq:
    <<: *hardening
    # read_only: false        # uncomment only if your read-only test failed, and document why
    build:
      context: ./rabbitmq
    image: enterprise/rabbitmq:1.0
    user: "999:999"
    hostname: rabbitmq
    secrets:
      - source: rabbitmq_credentials
        target: /etc/rabbitmq/conf.d/90-credentials.conf
    volumes:
      - rabbitmq_data:/var/lib/rabbitmq
    networks: [backend]
    tmpfs: [/tmp]
    healthcheck:
      test: ["CMD", "rabbitmq-diagnostics", "-q", "ping"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s
    deploy:
      resources:
        limits: { cpus: "1.0", memory: 512M }

networks:
  frontend:
    driver: bridge
  backend:
    driver: bridge
    internal: true

volumes:
  db_data:
  rabbitmq_data:

secrets:
  db_root_password:
    file: ./secrets/db_root_password.txt
  db_password:
    file: ./secrets/db_password.txt
  rabbitmq_password:
    file: ./secrets/rabbitmq_password.txt
  rabbitmq_credentials:
    file: ./secrets/rabbitmq_credentials.conf
```

Final project tree, with one Dockerfile per service:

```text
enterprise-docker-infrastructure/
├── docker-compose.yml
├── .env.example   .gitignore   README.md
├── nginx/       Dockerfile  nginx.conf
├── tomcat/      Dockerfile  entrypoint.sh  .dockerignore  vprofile-project/ (cloned source, git-ignored)
├── mariadb/     Dockerfile  init.sql        (copy of vprofile's db_backup.sql)
├── memcached/   Dockerfile
├── rabbitmq/    Dockerfile  rabbitmq.conf
├── secrets/     .gitkeep   (real files are git-ignored)
├── scripts/     deploy.sh  validate.sh  backup.sh
└── docs/        architecture.png  security.md  troubleshooting.md
```

Check that the anchor expanded the way you expect: `docker compose config` prints the fully merged file, and each service must show `cap_drop`, `read_only`, `restart` and `security_opt`.

### 8.2 `scripts/deploy.sh`

```bash
#!/usr/bin/env bash
# One-command deployment with pre-flight checks.
set -euo pipefail
cd "$(dirname "$0")/.."

for f in .env secrets/db_root_password.txt secrets/db_password.txt \
         secrets/rabbitmq_password.txt secrets/rabbitmq_credentials.conf; do
  [ -s "$f" ] || { echo "Missing $f. See README, section Secrets."; exit 1; }
done

docker compose config --quiet
docker compose up -d --build --wait --wait-timeout 300   # returns when all services are healthy
docker compose ps
echo "Application: http://$(hostname -I | awk '{print $1}')/"
```

`--wait` makes `up` block until every container is healthy, and fail if one is not, which is exactly what a deploy script should do.

### 8.3 What the README must contain (AC-15)

1. **Overview**: one paragraph and the architecture diagram (`docs/architecture.png`).
2. **Prerequisites**: OS, Docker and Compose versions, 4 GB RAM minimum.
3. **Secrets**: the commands from Step 0.5, and a warning never to commit `secrets/` or `.env`.
4. **Deploy**: `./scripts/deploy.sh`.
5. **Validate**: `./scripts/validate.sh`, with a sample of passing output.
6. **Security controls**: a table of service, UID, capabilities, read-only status and network, plus any exception you made and why (link `docs/security.md`).
7. **Backup and restore**: `./scripts/backup.sh` and the restore commands from Step 7.4.
8. **Troubleshooting**: link `docs/troubleshooting.md` (the table below is a good start).
9. **Known limitations**: HTTP only, lab use; unhealthy containers are not auto-restarted.

### 8.4 Troubleshooting table

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `secret file not found` on `up` | Step 0.5 not run | Generate the files in `secrets/` |
| MariaDB: `Permission denied` reading `/run/secrets/...` | Secret file is 600, container UID cannot read it | `chmod 644 secrets/*`, keep `secrets/` at 700 |
| MariaDB: `Access denied for user 'appuser'` after changing a secret | Init runs only on an empty volume | `ALTER USER` in the DB, or `docker compose down -v` (deletes data) |
| RabbitMQ: queues gone after recreate | No fixed `hostname:` | Add `hostname: rabbitmq` |
| Tomcat: `ACCESS_REFUSED` from RabbitMQ | `rabbitmq_credentials.conf` and `rabbitmq_password.txt` differ, or user created before the conf existed | Regenerate both from one password; `rabbitmqctl change_password` |
| Any service: `Read-only file system` in logs | A writable path is missing | Add that exact path under `tmpfs:` |
| Tomcat stuck in `health: starting` | `curl` missing, or app failed to deploy | `which curl` in the image; look for `SEVERE` in logs |
| NGINX: `host not found in upstream "tomcat"` | Tomcat not up, or NGINX not on `frontend` | Check `depends_on` and `networks` |
| NGINX: `Permission denied` on `/var/cache/nginx` or the pid file | Temp paths not moved to `/tmp` | Use the `nginx.conf` from Step 5.2 |
| Browser shows `502 Bad Gateway` | Tomcat down or unhealthy | `docker compose ps tomcat`, `docker compose logs tomcat` |
| Container restarts with exit code 137 | Out of memory, killed by the limit | `docker inspect -f '{{.State.OOMKilled}}' <name>`; raise `memory` |
| `bind: address already in use` on port 80 | Another web server on the host | `sudo ss -tlnp \| grep ':80 '`, stop it |

#### Problems met during the vprofile deployment

These all happened in a real run of this project. Most share one lesson: a container that is running is not the same as a service that works, so always check from the consumer's side.

| Symptom | Cause | Fix |
| --- | --- | --- |
| MariaDB: `/run/secret/db_root_password: No such file or directory` | Typo in the `_FILE` path (`secret` instead of `secrets`) | Use `/run/secrets/...`; `grep -n "/run/secret/" docker-compose.yml` must print nothing |
| `nc: bad address 'memcached'`, and `docker compose ps` is empty | The service was started with `docker compose run` (a one-off container without the service DNS name) | `docker rm -f` the `-run-` container, start with `docker compose up -d memcached` |
| Build fails at `mvn dependency:go-offline` with `maven-default-http-blocker` | Optional vprofile dependencies only exist on `http://` repositories | Build with `mvn package` and a cache mount (Step 4.6) |
| Tomcat: `NullPointerException` in `JdbcServicesImpl.configure`, DB looks healthy | MariaDB 11 with MySQL Connector/J 8 | `FROM mariadb:10.11` and recreate `db_data` (Step 1.3) |
| Tomcat: `ACCESS_REFUSED`, broker has only `guest` | Secret mounted to `config.d` instead of `conf.d`, so RabbitMQ never read it | Fix the `target`, then create `appuser` or recreate `rabbitmq_data` (Step 3.5) |
| New password, user or schema "ignored" | Init settings apply only to an empty volume | Change it inside the service (`ALTER USER`, `rabbitmqctl`) or recreate that one volume |
| `unhealthy` but never restarted | Restart policies react only to the process exiting | Fix the cause, then `docker compose restart <service>` |
| `curl http://<ip>/login:8080` fails | Port must come before the path | `curl -i http://<ip>:8080/login`, or better through NGINX |

### 8.5 Submission checklist

- [ ] `docker compose up -d --build --wait` succeeds from a fresh clone plus generated secrets
- [ ] `validate.sh` shows 0 failures; output saved in `docs/`
- [ ] Persistence, crash and restore drills done and written up
- [ ] `git ls-files` lists no file from `secrets/` except `.gitkeep`, and no `.env`
- [ ] README covers deploy, validate, backup and troubleshooting
- [ ] `docs/security.md` lists every exception to the hardening rules and why
