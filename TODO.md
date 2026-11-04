# TODO

I know this is LLM generated but this is my way of brainstorming and keeping track of tasks. The code will still be hand written, because that's the fun part and why i'm doing it.

## 1. Coordinator rework: origin-keyed scheduling

Robots policies, rate limits, and backoff are all scoped per origin (scheme + host + port, RFC 9309), matching grip's `Origin`, so the coordinator schedules origins, not URLs. Implemented in stages; every stage ends with a working crawler.

### 1a. Groundwork

- [x] Configurable `User-Agent` (`spoon.user_agent`), sent on every fetch and passed to `grip.rate`/`grip.is_allowed` in 1d.
- [ ] Injectable clock: `clock: fn() -> Int` on internal `config.Config`, default monotonic ms via FFI (can be negative, only differences matter). No public setter — tests build `config.Config` directly; the 1d robots cache reads the same clock for expiry.
- [ ] Sample `now` once per message and pass it down as `Int`. `send_after` wake-ups are hints, never authority: every dispatch re-checks `now`, so stale wakes are harmless and tests step the clock instead of waiting on timers. Naming convention: absolute instants end in `_at` (`next_at`, `Wake(at:)`), durations in `_ms` (`delay_ms`), the parameter is always `now`.

Checkpoint: the crawler identifies itself, and tests can step time instead of sleeping.

### 1b. Crash safety on the current coordinator

- [ ] Fetchers become `Temporary` children; the coordinator runs `process.monitor` on each pid after `factory.start_child`.
- [ ] `WorkerDown(process.Down)` message, handled like `Errored` until 1c adds requeueing.

Checkpoint: a crash in user handler code kills one fetch, not the crawl, and frees the slot.

### 1c. Origin-keyed frontier

Functional core, imperative shell — it's the Elm architecture (as in Lustre), so we keep its naming: `update(crawl, msg, now) -> #(Crawl, List(Effect))` in `spoon/internal/crawl`, `Effect = Fetch(Scoop) | Wake(at: Int) | Done(acc)` (data only, never callbacks). The coordinator stays as the shell: a one-pass interpreter (`factory.start_child`, `send_after`, reply). The frontier is a pure data structure in `spoon/internal/frontier`. Tests drive the core like a [captured continuation](https://crowdhailer.me/2026-07-30/a-universal-approach-to-mocking/): feed messages with literal `now` ints, assert full effect lists (order _and_ absence), interleave `Visited`/`WorkerDown` to cover concurrency — no fakes in core tests; stepped clock + recording `fetch` survive only as integration smoke over the shell. No test-only frontier dump; `spoon.stats` (section 2) if introspection is ever needed.

- [ ] Two-level frontier: `slots: Dict(Origin, Slot)` + `ready: PriorityQueue(#(Int, Origin))` keyed by `next_at`. `Slot` (per origin, Scrapy-style) holds `policy`, `delay_ms`, `scoops: Deque(Scoop)`, `next_at`, `in_flight: Option(Scoop)`, `failures`. API: `push`; `pop(frontier, now) -> Popped` with `Popped(Scoop, Frontier) | Cooling(until: Int) | Empty` — a real outcome type, not `Option`: `Cooling` tells the shell when to `Wake`, `Empty` feeds the finish check; `settle(frontier, origin, outcome, now)` with `Outcome = Success | Failure | Throttled(retry_after_ms: Option(Int))`; `requeue`. Invariant: an origin is in `ready` only with scoops and nothing in flight; stale entries skipped on pop. Until 1d: `policy = grip.allow_all()`, `delay_ms` from `spoon.rate_limit(config, Delay)`.
- [ ] `Scoop(url, depth, attempts)`. `attempts` gives up on one URL (e.g. 3); the host's `failures` drives origin backoff (1e) and resets on success.
- [ ] One request in flight per origin; `next_at = now + delay` set on completion, so slow servers get crawled slower.
- [ ] No busy-looping: `process.send_after` a wake-up for the earliest `next_at`.
- [ ] Link loop: scope pipeline from section 3, then enqueue on the origin's deque.
- [ ] `WorkerDown`: `requeue` — free the origin, `in_flight` scoop back at the front with `attempts + 1`.

Checkpoint: two origins crawl in parallel, a slow one doesn't block the other, and the default delay spaces requests per origin.

### 1d. Robots (grip)

- [ ] Robots cache actor: policy per `Origin`, parks callers on a miss, fetches via the factory, expires after ~24h. No crawling logic. Robots fetch derived from `make_fetch` with a ~500 KiB cap (RFC 9309) — the user's transport (proxy, test stub) covers robots.txt too.
- [ ] Per-origin delay from `grip.rate`, converted to ms once, falling back to the default.
- [ ] `origin.covers` on every link; uncovered links trigger a lookup for their own origin.
- [ ] `spoon.respect_robots(config, Bool)`, default `True`.
- [ ] Supervise `rest_for_one`: factory, robots cache, coordinator. A cache crash loses parked replies, so the coordinator restarts with it.

Checkpoint: a disallowed path never gets fetched; `Crawl-delay` stretches the request interval.

### 1e. Backoff

- [ ] One path through `settle` with `Throttled`: a 429/503 page and grip's rate-limited robots error both push the origin's `next_at` back — `Retry-After` when present, else exponential via `failures`.

Checkpoint: a 429-ing origin slows exponentially while others continue, tested with the stepped clock.

## 2. Builds on the new `Scoop`/`Host` (after 1c)

- [ ] `max_depth`, separate from `max_pages`.
- [ ] Redirect hop limit on the scoop; redirects don't increment depth. Targets still pass dedup, robots, and the origin's clock.
- [ ] Cap queued scoops per origin — with the max URL length below, bounds the frontier against spider traps (calendars, faceted search, session IDs).
- [ ] Progress stats: queued, in flight, done, failed, rejected via `spoon.stats(subject)`. Can be an observer over the effect stream in the shell, not core logic.
- [ ] Hook for fetch failures / dead links; `Errored` drops silently today. Same effect-stream observer site as stats.
- [ ] Crawl timeout and graceful cancellation via a `Stop` message.

## 3. Independent, any order

Crawl scope in the coordinator — a boundary an `on_page` override can't lose. Not the Origin's job: `Origin` is scheduling identity, scope is the crawl boundary; lands before 1c.

- [ ] `Scope` in config: `AllowedHosts(List(String))`, default `AllowedHosts([base_url.host])`, or `AllowAll`. `spoon.allowed_domains` _replaces_ the list (Colly-style), `spoon.allow_all_hosts` opts out explicitly — no empty-list sentinel, no Bool toggle. Exact match; glob/regex below.
- [ ] Enqueue pipeline on `Visited`: resolve against `page.url` → requestable filter → scope filter → `normalize` → seen-set. Requestable (http/https + host present) is unconditional mechanics, scope is policy — under `AllowAll` nothing else drops `mailto:`/`javascript:`. Seeds skip the scope check at `Start`, their links don't.
- [ ] Delete `same_host`, `resolve`, `protocol_http`. `default_on_page` shrinks to `status_ok`; `on_page` callback becomes `fn(Page) -> #(item, Candidates)`. Candidates may be relative until enqueue.
- [ ] `allow_all_hosts` waits for 1c politeness + 1d robots: an open-web crawl with no rate limit and no robots.txt hammers strangers' servers.

Remaining middleware (`log`, `status_ok`, `redirect`, `content_type`, `anchors`):

- [ ] Is the `guard`/`extract` split still worth it for five functions? Either way, give guards a real outcome type instead of overloading `Result`.
- [ ] `extract.content_type(resp) -> List(String)` segments (like `wisp.path_segments`); then decide if the reject-gate form survives.
- [ ] Path include/exclude (glob/regex allow/deny) as `prefetch`-stage guards.
- [ ] `rel="nofollow"` / `noindex` and canonical-link preference as `next`-stage guards.
- [ ] Sitemap ingestion via `extract.sitemap_locs` from `next`; `grip.sitemaps(policy)` needs the robots cache (1d).

Worker-local fetching:

- [ ] Fetch builder instead of a bare fetch fn: config holds `options: fetch.Options(timeout_ms, max_body_size)` + `make_fetch: fn(fetch.Options) -> fetch.Fetch`; `spoon.fetch` takes the builder, flat setters (`spoon.fetch_timeout`, `spoon.max_body_size`) update options, shell resolves once in `fold`. Options flow into custom transports too, so setters and a swapped fetch compose in any pipe order — no precedence rules. Default is the same shape, httpc client built once outside the inner fn (size cap = `httpc.max_body_size`).
- [ ] `fetch.Fetch = fn(Request(String)) -> Result(Response(BitArray), FetchError)`: bytes out, charset decode from `Content-Type` with lossy fallback happens worker-side so every transport gets it (plain `dispatch` fails on non-UTF-8 pages); default uses `dispatch_bits`. Breaking after 1.0 — decide first.
- [ ] Two config layers: request-level (`user_agent`, `spoon.headers`) set on the `Request` before fetch, reaches every impl; transport-level lives in `fetch.Options` — only transport-advisory fields, never headers or crawl policy. `fetch_timeout` keeps its prefix: plain `timeout` is the crawl timeout (section 2).
- [ ] Documented contract on `spoon.fetch`: never follow redirects (section 2 owns them), don't strip spoon's headers, honor options where the transport can. `Options` plain record vs opaque + accessors: settle at build time (Gleam opacity is module-scoped).

Standalone filters:

- [ ] Maximum URL length; second half of the spider-trap bounds from section 2.

Housekeeping:

- [ ] Tests for pure helpers (`normalize`, `resolve_url`, guard predicates). Zero coverage now.
- [ ] Remove demo from docs/codebase

## Later / maybe

- [ ] Resumable crawl state via a swappable visited-set store; convert monotonic to wall time only here.
- [ ] Conditional GETs with ETags — only matter for recrawls, so they belong with persistence.
- [ ] Multi-node distribution; the OTP architecture would support it.
- [ ] Dry-run mode: an interpreter that prints `StartFetch` instead of fetching — preview what a crawl would touch before running it.
- [ ] JS target: the pure core is runtime-agnostic; only the OTP shell would need a promise-based counterpart.
