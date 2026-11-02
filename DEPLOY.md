# Deploying TypeGraph

The stack is a private proxy: `web` (Caddy) serves the client and `/api` in
plain HTTP on `127.0.0.1:4000` (`HTTP_PORT` picks another port), and `gateway`
(the analyzer) sits behind it on a Unix socket. Put a public reverse proxy in
front of it that:

- terminates TLS, and
- rate-limits `POST /api/analyze` per client IP (25 requests per 5 s suits a
  typing user), answering `429` without a body.

For fsakel.com, that proxy lives in
[fsakel-com](https://github.com/filip-sakel/fsakel-com).

## What the server needs

- **Linux on the architecture you'll build for** (x86_64 or arm64). Build on the
  server itself; building Swift through QEMU emulation is very slow.
- **Docker Engine with the compose plugin**, or **Podman 5 or later** with
  `docker-compose` as its compose provider.
- **About 4 GB RAM and 2 CPUs.** The release build of swift-syntax is the peak.
  At run time the gateway is capped at 2 GB, and each worker uses one core while
  it analyzes.
- **About 8 GB free disk** for the build images. `docker image prune` frees
  most of it after the build.
- **git**. `swift-syntax/` is a submodule pinned to a commit on the
  `typegraph-app` branch of
  [filip-sakel/swift-syntax](https://github.com/filip-sakel/swift-syntax), so
  clone with `--recurse-submodules` (or run `git submodule update --init` in an
  existing clone).

## Setup

```sh
git clone --recurse-submodules https://github.com/filip-sakel/swift-typegraph typegraph
cd typegraph
cat > .env <<'EOF'
# Optional:
# HTTP_PORT=4000
# WORKERS=4
# BUG_REPORT_URL=https://github.com/<owner>/<repo>/issues/new
EOF
scripts/up.sh      # → TypeGraph is up at http://localhost:4000
```

The first build takes several minutes. `WORKERS` is how many analyses can run
at once; one per core is a good default. `BUG_REPORT_URL` is compiled into
the client, so changing it means rebuilding, which `scripts/up.sh` does.

With rootless Podman, keep the containers running after you log out and
restart them at boot (it has no daemon to honor `restart: unless-stopped`):

```sh
sudo loginctl enable-linger "$USER"
systemctl --user enable --now podman.socket podman-restart.service
```

## Operating

With Podman, write `podman compose` for `docker compose`.

```sh
git pull --recurse-submodules && scripts/up.sh # update
docker compose logs -f gateway
docker compose exec gateway cat /var/log/typegraph/failures.jsonl
```

Back up the **`failures`** volume: it holds the log of failed analyses that
bug reports refer to. `docker compose down -v` deletes it.
