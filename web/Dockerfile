# The static client behind Caddy, which also proxies /api to the gateway and
# terminates TLS. Build from the repository root: docker build -f web/Dockerfile .

FROM docker.io/library/node:24-alpine AS build
RUN npm install -g pnpm@12.3.4
WORKDIR /web
COPY web/package.json web/pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile
COPY web/ ./
# Where "File a bug report" points, e.g. https://github.com/<owner>/<repo>/issues/new
ARG VITE_BUG_REPORT_URL=
ENV VITE_BUG_REPORT_URL=$VITE_BUG_REPORT_URL
RUN pnpm build

# Stock Caddy has no rate limiting; compile in the plugin (pinned: it has no
# recent release tag).
FROM docker.io/library/caddy:2.11.7-builder-alpine AS caddy
RUN xcaddy build --with github.com/mholt/caddy-ratelimit@5625512f24f6f59d6f64fb3aafe5eecff0b286db

FROM docker.io/library/caddy:2.11.7-alpine
COPY --from=caddy /usr/bin/caddy /usr/bin/caddy
COPY web/Caddyfile /etc/caddy/Caddyfile
COPY --from=build /web/dist /srv
