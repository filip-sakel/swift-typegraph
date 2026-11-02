# Swift TypeGraph

A web app that visualizes the `TypeGraph` that SwiftLexicalLookup builds for
a Swift snippet. The design is in [SPEC.md](SPEC.md); running it on a server
behind a public proxy is in [DEPLOY.md](DEPLOY.md).

## Run with Docker or Podman

```sh
scripts/up.sh                  # builds, starts, prints "TypeGraph is up at http://localhost:4000"
HTTP_PORT=9000 scripts/up.sh   # another host port
```

`scripts/up.sh` runs `docker compose up -d --build` when the docker daemon is
reachable and `podman compose up -d --build` otherwise, then prints the URL
from `compose port web 4000`. It listens on loopback only, in plain HTTP.
Set `COMPOSE` to choose, e.g.
`COMPOSE="sudo docker compose"` where docker needs root.

The first build compiles swift-syntax in release mode and takes several
minutes. It needs about 8 GB of free disk, most of it for the
`swiftlang/swift:nightly-main-noble` build image.

### Podman

`podman compose` hands off to `docker-compose`, which talks to podman's
Docker-compatible API socket. The script starts it; by hand:

```sh
systemctl --user start podman.socket        # once per boot, or `enable` it
podman compose up -d --build
podman compose port web 4000                # → 127.0.0.1:4000
```

Podman differences that are already handled:

- **Short image names**: podman won't resolve `swift:...` without a TTY, so the
  Dockerfiles use fully qualified names (`docker.io/...`).
- **Healthchecks**: podman builds OCI images, which drop `HEALTHCHECK`, so
  `compose.yaml` declares the gateway's healthcheck itself (`web` waits on it).

### Settings

Set these in the environment or in a `.env` file next to `compose.yaml`.

| Variable | Default | Meaning |
| --- | --- | --- |
| `HTTP_PORT` | `4000` | Loopback port for HTTP |
| `WORKERS` | `4` | Analyzer processes |
| `BUG_REPORT_URL` | (none) | Enables the "File a bug report" link, e.g. `https://github.com/you/repo/issues/new` |

### Operating

```sh
docker compose logs -f gateway     # or: podman compose logs -f gateway
docker compose down                # stop; -v also drops the failure log
docker compose exec gateway cat /var/log/typegraph/failures.jsonl
```

## Develop

```sh
cd server && swift build -c release -Xswiftc -DDEBUG && CHECK_INVARIANTS=1 swift run -c release typegraph-gateway   # :8080
cd web && pnpm install && pnpm dev                                                                                # :5173, proxies /api
```
