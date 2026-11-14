# TODO

I know this is LLM generated but this is my way of brainstorming and keeping track of tasks. The code will still be hand written, because that's the fun part and why i'm doing it.

## 1. Coordinator rework: origin-keyed scheduling

Robots policies, rate limits, and backoff are all scoped per origin (scheme + host + port, RFC 9309), matching grip's `Origin`, so the coordinator schedules origins, not URLs. Implemented in stages; every stage ends with a working crawler.

### 1a. Groundwork

- [x] Configurable `User-Agent` (`spoon.user_agent`), sent on every fetch and passed to `grip.rate`/`grip.is_allowed` in 1d.

Checkpoint: the crawler identifies itself.

### 1b. Crash safety on the current coordinator

- [x] Fetchers become `Temporary` children; the coordinator runs `process.monitor` on each pid after `factory.start_child`.
- [x] `WorkerDown(process.Down)` message, handled like `Errored` until 1c adds requeueing.

Checkpoint: a crash in user handler code kills one fetch, not the crawl, and frees the slot.

### 1c. Origin-keyed frontier

Functional core, imperative shell — it's the Elm architecture (as in Lustre), so we keep its naming: `update(crawl, msg, now) -> #(Crawl, List(Effect))` in `spoon/internal/crawl`, `Effect = Fetch(Scoop) | Wake(at: Int) | Done(acc)` (data only, never callbacks). The coordinator stays as the shell: a one-pass interpreter (`factory.start_child`, `send_after`, reply). The frontier is a pure data structure in `spoon/internal/frontier`. Tests drive the core like a [captured continuation](https://crowdhailer.me/2026-07-30/a-universal-approach-to-mocking/): feed messages with literal `now` ints, assert full effect lists (order _and_ absence), interleave `Visited`/`WorkerDown` to cover concurrency — no fakes in core tests; stepped clock + recording `fetch` survive only as integration smoke over the shell. No test-only frontier dump; `spoon.stats` (section 2) if introspection is ever needed.

- [x] Injectable clock: `clock: fn() -> Int` on internal `config.Config`, default monotonic ms via FFI (can be negative, only differences matter). No public setter — tests build `config.Config` directly; the 1d robots cache reads the same clock for expiry.
- [x] `Scoop(url, depth, attempts)`. `attempts` gives up on one URL (e.g. 3); the host's `failures` drives origin backoff (1e) and resets on success.
- [x] One request in flight per origin; `next_at = now + delay` set on completion, so slow servers get crawled slower.
- [x] No busy-looping: `process.send_after` a wake-up for the earliest `next_at`.
- [x] `WorkerDown`: crawl owns the attempt cap. Under `max_attempts`: `requeue` — free the origin, `in_flight` scoop back at the front with `attempts + 1`. At the cap: `penalize`, scoop dropped.

Checkpoint: two origins crawl in parallel, a slow one doesn't block the other, and the default delay spaces requests per origin.

### 1d. Robots (grip)

Robots is a guard inside the fetch worker. Each worker asks the robots actor `(origin, url)` before requesting. The actor owns policy and parks the call on a miss. The core never sees a policy.

#### Groundwork

- [ ] Supervisor starts children in dependency order, fetchers before coordinator. Today the coordinator's `Start` races the factory's name registration.
- [ ] Frontier drops `policy` and `grip`. The cooldown moves to the caller: `settle`, `requeue`, and `penalize` take `delay_ms`, and the slot stops storing it.

Checkpoint: no behaviour change.

#### Worker guard

- [ ] Before the request, the worker calls the robots actor. Disallowed: report `Skipped`, make no request.
- [ ] Page results carry the origin's crawl delay, so the core spaces the next request.
- [ ] The call's timeout exceeds the robots fetch timeout. A timeout crashes the worker, and the crash requeues the scoop.

#### Core

- [ ] Fetch results are `Fetched(outcome, crawl_delay_ms)`, `Skipped`, or failed. Fetched: settle with the reported delay, or `spoon.rate_limit` when absent. Skipped: release the origin with no cooldown and no request counted.
- [ ] Links are `seen` and queued on discovery, as today. The core filters nothing.
- [ ] `user_agent` leaves `crawl.Settings`; the core never imports `grip`.

Checkpoint: core tests use literal ints; cover a reported delay setting the cooldown, the default when absent, and a skipped scoop releasing its origin without cooldown.

#### Robots actor

- [ ] Holds `Dict(Origin, #(Policy, fetched_at))`, expires after ~24h via `config.clock`. A hit answers at once; a miss parks the caller and starts one fetch per origin. No I/O in the actor.
- [ ] Owns the agent string, passed at start. Answers `#(allowed, crawl_delay_ms)` per call, using `grip.is_allowed` and `grip.rate`; never hands out policies.
- [ ] Robots fetch on its own `Temporary` factory, sharing the user's `fetch` and request builder. `Visit` is page-shaped, and a robots crash has no scoop to requeue. ~500 KiB cap (RFC 9309), up to 5 redirects.
- [ ] `grip.from_response` covers 4xx/5xx; transport errors and worker crashes become `disallow_all`.
- [ ] `spoon.respect_robots(config, Bool)`, default `True`; `False`: the worker skips the call and reports no delay.
- [ ] `rest_for_one` with the robots actor first: a crash restarts workers and the coordinator.

### 1e. Backoff

- [ ] One path through `settle` with `Throttled`: a 429/503 page and grip's rate-limited robots error both push the origin's `next_at` back — `Retry-After` when present, else exponential via `failures`.
- [ ] Robots 429: the actor answers with the `Retry-After` delay, and the worker reports `Throttled` so the core penalizes the origin.

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

- [x] `Scope` in config: `AllowedHosts(List(String))`, default `AllowedHosts([base_url.host])`, or `AllowAll`. `spoon.allowed_domains` _replaces_ the list (Colly-style), `spoon.allow_all_hosts` opts out explicitly — no empty-list sentinel, no Bool toggle. Exact match; glob/regex below.
- [x] Enqueue pipeline on `Visited`: resolve against `page.url` → requestable filter → scope filter → `normalize` → seen-set. Requestable (http/https + host present) is unconditional mechanics, scope is policy — under `AllowAll` nothing else drops `mailto:`/`javascript:`. Seeds skip the scope check at `Start`, their links don't.
- [x] Delete `same_host`, `resolve`, `protocol_http`. `default_on_page` shrinks to `status_ok`; `on_page` callback becomes `fn(Page) -> #(item, Candidates)`. Candidates may be relative until enqueue.
- [x] `allow_all_hosts` waits for 1c politeness + 1d robots: an open-web crawl with no rate limit and no robots.txt hammers strangers' servers.

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
