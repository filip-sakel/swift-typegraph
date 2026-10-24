# The gateway and the analyzer workers (SPEC §7). Build from the repository
# root, since the server depends on ../swift-syntax:
#   docker build -f server/Dockerfile .

# The engine needs a main-branch compiler, like the local toolchain.
FROM docker.io/swiftlang/swift:nightly-main-noble AS build
WORKDIR /src
COPY swift-syntax swift-syntax
COPY server/Package.swift server/Package.resolved server/
RUN cd server && swift package resolve
COPY server/Sources server/Sources
COPY server/Tests server/Tests
# Release build with `#if DEBUG` assertions on (measured: no meaningful cost).
RUN cd server \
 && swift build -c release -Xswiftc -DDEBUG --static-swift-stdlib \
 && mkdir /out \
 && cp "$(swift build -c release --show-bin-path)"/typegraph-gateway "$(swift build -c release --show-bin-path)"/typegraph-worker /out/

FROM docker.io/library/ubuntu:noble
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*
RUN useradd --system --no-create-home typegraph \
 && mkdir -p /var/log/typegraph \
 && chown typegraph /var/log/typegraph
COPY --from=build /out/ /usr/local/bin/
USER typegraph
ENV PORT=8080 \
    CHECK_INVARIANTS=1 \
    FAILURE_LOG=/var/log/typegraph/failures.jsonl
EXPOSE 8080
HEALTHCHECK --interval=15s --timeout=3s --start-period=10s \
  CMD curl -fsS http://localhost:8080/api/healthz || exit 1
CMD ["typegraph-gateway"]
