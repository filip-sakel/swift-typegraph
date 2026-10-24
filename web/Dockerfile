# The static client behind nginx, which also proxies /api to the gateway.
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

FROM docker.io/library/nginx:1.27-alpine
COPY web/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /web/dist /usr/share/nginx/html
