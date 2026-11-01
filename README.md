# spoon

[![Package Version](https://img.shields.io/hexpm/v/spoon)](https://hex.pm/packages/spoon)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://spoon.hexdocs.pm/)

```sh
gleam add spoon@1
```

```gleam
import spoon

pub fn main() -> Nil {
      spoon.new("https://example.com")
      |> spoon.run()
}
```

Further documentation can be found at <https://spoon.hexdocs.pm/>.

## Development

```sh
gleam run   # Run the project
gleam test  # Run the tests
```

## TODO

### Extensibility: `guard`/`extract` split, composed by hand

- [ ] Split `middleware.gleam` into `guard.gleam` (preconditions) and `extract.gleam` (data producers).
- [ ] Give `next` access to the request `uri.Uri`, not just the `Response`.
- [ ] Move `same_host`/`resolve`/`protocol_http` out of `on_page` and into `next` as `List(uri.Uri) -> List(uri.Uri)` guards.
- [ ] Shrink `on_page` down to just the `status_ok` gate that decides the accumulator item.
- [ ] Add `extract.content_type(resp) -> List(String)` segments, mirroring `wisp.path_segments`.
- [ ] Decide whether `guard.content_type` (the reject-gate form) is still worth keeping once `case` + `extract.content_type` covers dispatch too.
- [ ] Give short-circuiting guards a real outcome type instead of overloading `Result` with "reject" and "error."
- [ ] Path include/exclude checks (glob or regex allow/deny lists) as `prefetch`-stage guards.
- [ ] `rel="nofollow"` / `noindex` handling and canonical-link preference as `next`-stage guards.
- [ ] Sitemap.xml ingestion via `extract.sitemap_locs`, dispatched from `next` via `case extract.content_type(resp)`.

### Robustness: fetcher crash handling

- [ ] Switch the fetcher child spec's restart strategy to `Temporary` (via `factory.restart_strategy`).
- [ ] Coordinator calls `process.monitor` on each fetcher pid right after a successful `factory.start_child`.
- [ ] Add `WorkerDown(process.Down)` to `coordinator.Message`, handled like `Errored`.
- [ ] Decide retry policy for crashed fetchers: re-enqueue the link (needs `dict.Dict(process.Pid, uri.Uri)` in `State`) or drop it.
- [ ] Retry with backoff for transient fetch failures (timeouts, 5xx), with a per-url retry count.

### Politeness

- [ ] Robots.txt support as a dedicated toggle (`spoon.respect_robots(config, Bool)`, default `True`), backed by an actor caching `dict.Dict(host, RobotRules)` per host.
- [ ] Decide whether that robots-cache actor is supervised or started unsupervised.
- [ ] Rate limiting as a dedicated config knob (`spoon.rate_limit(config, Delay)` or per-host override), needing a `Proceed`/`Defer`/`Reject` verdict instead of `Result`.
- [ ] Have the coordinator stop busy-looping and schedule `process.send_after(self, ..., Retry)` once nothing in the frontier is eligible.
- [ ] Parse and expose `Crawl-delay` from `robots.txt` as the rate limiter's default per-host delay.
- [ ] Per-host concurrency limit, not just the global `max_concurrency`.
- [ ] Configurable `User-Agent` header (`spoon.user_agent(config, String)`).

### Scope & filtering

- [ ] `spoon.allowed_domains(config, List(String))` (Colly-style) as an explicit host whitelist that _replaces_, not merges with, the default same-host-as-`base_url` check.
- [ ] `max_depth` config, separate from `max_pages`.
- [ ] Response size cap — reject/drop bodies over a configurable limit before fully buffering.
- [ ] Configurable frontier ordering (currently strict FIFO/BFS); consider a priority queue option.

### Observability

- [ ] Hook for fetch failures / dead links — `Errored` currently drops silently.
- [ ] Overall crawl timeout and graceful cancellation via a `Stop` message to the coordinator.

### Small stuff

- [ ] Write tests for the pure helpers (`normalize`, `resolve_url`, `guard` predicates) — currently zero coverage.
- [ ] Configurable fetch timeout/headers without having to replace the whole `fetch` function.
- [ ] Remove demo from docs/codebase

### Later / maybe

- [ ] Resumable/persisted crawl state via a swappable visited-set store.
- [ ] Multi-node distribution — the actor/OTP shape leaves room for it, not worth designing for now.

## Prior art

Frameworks consulted while shaping the TODO above:

- [Scrapy](https://scrapy.org/) (Python)
- [Colly](https://go-colly.org/) (Go)
- [Apache Nutch](https://nutch.apache.org/) (Java)
- [Heritrix](https://github.com/internetarchive/heritrix3) (Java)
- [StormCrawler](https://stormcrawler.net/) (Java)
- [Crawly](https://github.com/elixir-crawly/crawly) (Elixir)
- [Hop](https://github.com/seanmor5/hop) (Elixir)
