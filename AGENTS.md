# Agent notes

Keep notes about working in this repo here, in git, not in an agent's private memory.

## Restart the gateway after rebuilding the server

The gateway (`typegraph-gateway`, Hummingbird, port 8080) starts its
`typegraph-worker` processes once, at launch, and reuses them. Rebuilding
replaces the worker binary on disk but not the running workers, so the app keeps
serving the old analyzer. A worker is only replaced after a crash, a timeout or
1000 jobs.

After any server rebuild (`swift build` or `swift test` in `server/`), stop the
gateway and start it again before testing a change in the app or reporting it
as fixed. Check the change through the gateway, not only `typegraph-worker --once`:

```sh
curl -s -X POST localhost:8080/api/analyze -H 'X-Consent: 1' -H 'content-type: application/json' \
  -d '{"source": "struct A {}", "revision": 1}'
```

A debug build peaks just above the workers' default 10 MiB memory limit and
fails with `memoryLimit`. Raise the limit to run it:

```sh
cd server && MAX_MEMORY_KIB=1000000 .build/debug/typegraph-gateway
```
