# The static client behind Caddy, which also proxies /api to the gateway.
# Build from the repository root: docker build -f web/Dockerfile .

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

FROM docker.io/library/caddy:2.11.7-alpine
# The image gives caddy cap_net_bind_service; with cap_drop ALL (compose.yaml)
# the kernel refuses to exec it. Port 4000 needs no capability, so drop it.
RUN setcap -r /usr/bin/caddy
COPY web/Caddyfile /etc/caddy/Caddyfile
COPY --from=build /web/dist /srv
