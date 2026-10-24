# Deploying TypeGraph

The stack is two containers (see `compose.yaml`): `web` (Caddy) faces the
internet and `gateway` (the analyzer) sits behind it. Caddy gets and renews the
Let's Encrypt certificate on its own, so TLS setup is just a domain plus a
`.env` file.

## What the server needs

- **Linux on the architecture you'll build for** (x86_64 or arm64). Build on the
  server itself; building Swift through QEMU emulation is very slow.
- **Docker Engine with the compose plugin**, rootful (the default install).
  Rootless Docker or Podman forward connections through a userland proxy, so
  every client shows up with the same address and they all share one rate limit.
- **About 4 GB RAM and 2 CPUs.** The release build of swift-syntax is the peak.
  At run time the gateway is capped at 2 GB, and each worker uses one core while
  it analyzes.
- **About 8 GB free disk** for the build images. `docker image prune` frees
  most of it after the build.
- **git**, to clone this repository. `swift-syntax/` is a submodule pinned to a
  commit on the `typegraph-app` branch of
  [filip-sakel/swift-syntax](https://github.com/filip-sakel/swift-syntax), so
  clone with `--recurse-submodules` (or run `git submodule update --init` in an
  existing clone).
- **Inbound 80/tcp, 443/tcp and 443/udp** (HTTP/3). Let's Encrypt needs port 80
  or 443 reachable to issue the certificate.
- **A `.env` file** next to `compose.yaml` (below).
- **A DNS record** for the domain (below).

## Domain

At your DNS provider, add an `A` record from the name (say
`typegraph.example.com`) to the server's IPv4 address. Wait until
`dig +short typegraph.example.com` prints that address before the first start,
or certificate issuance fails and Caddy retries with backoff.

Skip the `AAAA` record unless you've enabled IPv6 in Docker. Without that,
Docker forwards IPv6 clients through `docker-proxy`, and they all share one rate
limit.

## Setup

```sh
git clone --recurse-submodules <this repository> typegraph && cd typegraph
cat > .env <<'EOF'
SITE_ADDRESS=typegraph.example.com
HTTP_PORT=80
HTTPS_PORT=443
# Optional:
# WORKERS=4
# BUG_REPORT_URL=https://github.com/<owner>/<repo>/issues/new
EOF
scripts/up.sh      # → TypeGraph is up at https://typegraph.example.com
```

The first build takes several minutes. `WORKERS` is how many analyses can run
at once; one per core is a good default. `BUG_REPORT_URL` is compiled into
the client, so changing it means rebuilding, which `scripts/up.sh` does.

If something else in front already terminates TLS (Cloudflare proxying,
Traefik), keep `SITE_ADDRESS=:80` and point that proxy at `HTTP_PORT`. In that
case every request comes from the proxy's address, so the per-IP rate limit
needs `trusted_proxies` in the Caddyfile and `{client_ip}` as its key.

## Operating

```sh
git pull --recurse-submodules && scripts/up.sh # update
docker compose logs -f web                     # Caddy: requests, certificate renewals
docker compose logs -f gateway
docker compose exec gateway cat /var/log/typegraph/failures.jsonl
```

Back up two volumes:

- **`caddy_data`** holds the certificate and the ACME account. If you lose it,
  Caddy issues a new certificate, and Let's Encrypt limits how often it can do
  that.
- **`failures`** holds the log of failed analyses that bug reports refer to.

`docker compose down -v` deletes both.
