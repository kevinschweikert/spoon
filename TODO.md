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

- [x] Supervisor starts children in dependency order, fetchers before coordinator. Today the coordinator's `Start` races the factory's name registration.
- [x] Frontier drops `policy` and `grip`. The cooldown moves to the caller: `settle`, `requeue`, and `penalize` take `delay_ms`, and the slot stops storing it.

Checkpoint: no behaviour change.

#### Worker guard

- [x] Before the request, the worker calls the robots actor. Disallowed: report `Skipped`, make no request.
- [x] Page results carry the origin's crawl delay, so the core spaces the next request.
- [ ] The call's timeout exceeds the robots fetch timeout. A timeout reports `Skipped(RobotsUnavailable)` instead of crashing the worker.

#### Core

- [x] Fetch results are `Fetched(outcome, crawl_delay_ms)`, `Skipped`, or failed. Fetched: settle with the reported delay, or `spoon.rate_limit` when absent. Skipped: release the origin with no cooldown and no request counted.
- [ ] Links are `seen` and queued on discovery, as today. The core filters nothing.
- [ ] `user_agent` leaves `crawl.Settings`; the core never imports `grip`.

Checkpoint: core tests use literal ints; cover a reported delay setting the cooldown, the default when absent, and a skipped scoop releasing its origin without cooldown.

#### Robots actor

- [ ] Holds `Dict(Origin, #(Policy, fetched_at))`, expires after ~24h via `config.clock`. A hit answers at once; a miss parks the caller and starts one fetch per origin. No I/O in the actor.
- [x] Owns the agent string, passed at start. Answers `#(allowed, crawl_delay_ms)` per call, using `grip.is_allowed` and `grip.rate`; never hands out policies.
- [ ] Robots fetch on its own `Temporary` factory, sharing the user's `fetch` and request builder. `Visit` is page-shaped, and a robots crash has no scoop to requeue. ~500 KiB cap (RFC 9309), up to 5 redirects.
- [ ] `grip.from_response` covers 4xx/5xx; transport errors and worker crashes become `disallow_all`.
- [ ] `spoon.respect_robots(config, Bool)`, default `True`; `False`: the worker skips the call and reports no delay.
- [ ] `rest_for_one` with the robots actor first: a crash restarts workers and the coordinator.

#### Shared worker

- [ ] `spoon/internal/worker`: one actor per `factory_supervisor`. Owns `running: Dict(Pid, Subject(Result(output, Crashed)))`.
  - Messages: `Start(job, reply_to)`, `Done(pid, output)`, `Down(process.Down)`.
  - `Start`: `factory.start_child(job)`, `process.monitor(pid)`, insert `pid → reply_to`. On factory error, reply `Crashed` at once.
  - `Done(pid, output)`: pop `pid`; if present, reply `Ok(output)`. Worker sends `Done` before it exits, so the message reaches the actor before its `Down`.
  - `Down(pid)`: pop `pid`; if present, reply `Crashed`. If absent, the `Done` already replied, so ignore.
  - One reply path: only the actor replies, and whoever removes the pid owns the reply. No double replies.
  - Page and robots factories each get one actor, so monitoring and replies live once. The coordinator sends `Start` instead of calling `start_child`.
- [ ] Worker actor restart: `running` and its reply subjects are lost, so the actor can't answer them. `Start` carries a deadline; the caller's wait times out and it treats that as `Crashed`. No caller monitors. Same timeout covers a hung child. Children of the old factory must not send into the new actor: put the factory under the actor so it restarts with it, or have children exit when the actor goes down.
- [ ] No pool or queue: robots lookups run inside page workers, so `max_concurrency` already caps them. Revisit if a caller outside the crawl ever reaches the robots actor.
- [ ] Robots `spawn_fetch` moves onto it; a crash becomes `disallow_all` for the parked callers (1d) instead of a silent hang.

### 1e. Backoff

- [ ] One path through `settle` with `Throttled`: a 429/503 page and grip's rate-limited robots error both push the origin's `next_at` back — `Retry-After` when present, else exponential via `failures`.
- [ ] Robots 429: the actor answers with the `Retry-After` delay, and the worker reports `Throttled` so the core penalizes the origin.
- [ ] Retry `Timeout`, `Network`, 429, and 5xx up to `max_attempts` through `requeue`. A crash reports `Failed(Crashed)` once, no requeue.

Checkpoint: a 429-ing origin slows exponentially while others continue, tested with the stepped clock.

## 2. Builds on the new `Scoop`/`Host` (after 1c)

- [ ] `max_depth`, separate from `max_pages`. `Scoop.depth` is hardcoded to 0 today, so set it from the parent in `push_links`.
- [ ] Redirect hop limit on the scoop; redirects don't increment depth. Targets still pass dedup, robots, and the origin's clock.
- [ ] Cap queued scoops per origin — with the max URL length below, bounds the frontier against spider traps (calendars, faceted search, session IDs).
- [ ] Global `max_frontier` cap on queued scoops: `push_links` drops new links when full and counts the drops, so the core never blocks.
- [ ] Progress stats: queued, in flight, done, failed, rejected via `spoon.stats` on the `start` handle (section 4). Can be an observer over the effect stream in the shell, not core logic.
- [ ] Dead links: a `fold` over `Failed` visits (section 4). The coordinator drops fetch errors today.
- [ ] Crawl timeout and graceful cancellation: `spoon.stop` on the `start` handle sends `Stop`.

## 3. Independent, any order

Crawl scope in the coordinator — a boundary an `on_page` override can't lose. Not the Origin's job: `Origin` is scheduling identity, scope is the crawl boundary; lands before 1c.

- [x] `Scope` in config: `AllowedHosts(List(String))`, default `AllowedHosts([base_url.host])`, or `AllowAll`. `spoon.allowed_domains` _replaces_ the list (Colly-style), `spoon.allow_all_hosts` opts out explicitly — no empty-list sentinel, no Bool toggle. Exact match; glob/regex below.
- [x] Enqueue pipeline on `Visited`: resolve against `page.url` → requestable filter → scope filter → `normalize` → seen-set. Requestable (http/https + host present) is unconditional mechanics, scope is policy — under `AllowAll` nothing else drops `mailto:`/`javascript:`. Seeds skip the scope check at `Start`, their links don't.
- [x] Delete `same_host`, `resolve`, `protocol_http`. `default_on_page` shrinks to `status_ok`; `on_page` callback becomes `fn(Page) -> #(item, Candidates)`. Candidates may be relative until enqueue.
- [x] `allow_all_hosts` waits for 1c politeness + 1d robots: an open-web crawl with no rate limit and no robots.txt hammers strangers' servers.

Extraction helpers and scope knobs:

- [ ] `extract.content_type(resp) -> List(String)` segments (like `wisp.path_segments`).
- [ ] Path include/exclude (glob/regex allow/deny) as scope knobs, enforced by the shell like hosts.
- [ ] Subdomain matching as an explicit scope option (Crawlee's `same-domain`), never implied by a name.
- [ ] `rel="nofollow"`: extractors return `Link(url: Uri, nofollow: Bool)` (like Scrapy's `Link`), plus a `Uri -> Link` helper so custom extractors stay one-liners. Nofollow links stay in `page.links` but out of the crawl. `spoon.respect_nofollow(Bool)`, default `True`.
- [ ] `noindex` and canonical-link preference.
- [ ] Sitemap ingestion via `extract.sitemap_locs` in `extract_links`; `grip.sitemaps(policy)` needs the robots cache (1d).

Worker-local fetching:

- [ ] Fetch builder instead of a bare fetch fn: config holds `options: fetch.Options(timeout_ms, max_body_size)` + `make_fetch: fn(fetch.Options) -> fetch.Fetch`; `spoon.fetch` takes the builder, flat setters (`spoon.fetch_timeout`, `spoon.max_body_size`) update options, shell resolves once in `fold`. Options flow into custom transports too, so setters and a swapped fetch compose in any pipe order — no precedence rules. Default is the same shape, httpc client built once outside the inner fn (size cap = `httpc.max_body_size`).
- [ ] `fetch.Fetch = fn(Request(String)) -> Result(Response(BitArray), FetchError)`: bytes out, charset decode from `Content-Type` with lossy fallback happens worker-side so every transport gets it (plain `dispatch` fails on non-UTF-8 pages); default uses `dispatch_bits`. Breaking after 1.0 — decide first.
- [ ] Two config layers: request-level (`user_agent`, `spoon.headers`) set on the `Request` before fetch, reaches every impl; transport-level lives in `fetch.Options` — only transport-advisory fields, never headers or crawl policy. `fetch_timeout` keeps its prefix: plain `timeout` is the crawl timeout (section 2).
- [ ] Documented contract on `spoon.fetch`: never follow redirects (section 2 owns them), don't strip spoon's headers, honor options where the transport can. `Options` plain record vs opaque + accessors: settle at build time (Gleam opacity is module-scoped).
- [ ] Skip unwanted bodies by `Content-Type`/`Content-Length` before downloading, where the transport can (Colly's `OnResponseHeaders`, Hop's HEAD prefetch).

Standalone filters:

- [ ] Maximum URL length; second half of the spider-trap bounds from section 2.

Housekeeping:

- [ ] Tests for pure helpers (`normalize`, `resolve_url`, `extract`). Zero coverage now.
- [ ] Remove demo from docs/codebase
- [ ] README example passes a String to `spoon.new`, which takes a `Uri`.

## 4. Page API: `extract_links`, `on_page`, `fold`

Breaking change to `spoon@1`, done while the repo is young. Per URL: fetch → `extract_links` → resolve, keep http(s), `normalize` → `Page(Nil)` → `on_page` (fetchers, parallel) → scope filter → enqueue. `fold` (coordinator, serial) gets one `Visit` per attempted URL, after retries.

- [ ] Opaque `Page(item)`. Accessors `url`, `status`, `depth`, `links`, `item`; setters `with_item(p, b) -> Page(b)` and `nofollow(p, fn(Uri) -> Bool)`. Fields can grow without breaking; `page.new(url)` for users' tests.
- [ ] `links`: every link on the page, out-of-scope ones included. `nofollow` keeps a link in `links` but out of the crawl; a predicate can't add URLs.
- [ ] `extract_links(b, fn(Response(String)) -> List(Link))`, default `extract.anchors` on HTML. Replaces `next`, and is the only way to add URLs. `Link` in section 3.
- [ ] `on_page(b, fn(Page(Nil), Response(String)) -> Page(item))`, called for 2xx only. Body and headers stay in the `Response`, decoded worker-side (section 3).
- [ ] `fold(b, init, fn(acc, Visit(item)) -> acc)`, `Visit = Fetched(Page(item)) | Redirected(url, to, status) | Skipped(url, Skip) | Failed(url, Failure)`. Redirects and robots skips aren't errors.
- [ ] `Skip = Disallowed | RobotsUnavailable`; `Failure = Status(Int) | Timeout | Network | Crashed(String) | InvalidUrl`. `Crashed` carries the exit reason.
- [ ] 3xx: `fold` gets `Redirected`, the shell enqueues `to`; the section 2 hop limit applies.
- [ ] `max_pages` counts responses (`Fetched`, `Redirected`, `Failed(Status)`), not skips or transport failures.
- [ ] No parent field. A URL is fetched once, so a parent is a tree; referrers come from inverting `links` after the crawl.
- [ ] Delete `prefetch`, `next`, `Outcome`, and `Report` from the public API. `middleware` becomes pure helpers in `extract` (`anchors`, `content_type`, `sitemap_locs`); `status_ok` and `redirect` go; `log` wraps a fold function.
- [ ] `spoon.Error` (`InvalidSeed(Uri)`, start failure) instead of `actor.StartError`.
- [ ] `start(b, init, fold) -> Result(Crawl(acc), Error)` with `await`, `stop`, `stats`. `fold` is `start` + `await`; `run` is `fold` over `Nil`.
- [ ] Renames: `allowed_hosts`/`allow_all_hosts` (matching is exact-host; "domain" suggests subdomains), `delay` for `rate_limit`.

Checkpoint: a link graph and a dead-link report are each one `fold` with the default `on_page`.

## Later / maybe

- [ ] Resumable crawl state via a swappable visited-set store; convert monotonic to wall time only here.
- [ ] Conditional GETs with ETags — only matter for recrawls, so they belong with persistence.
- [ ] Multi-node distribution; the OTP architecture would support it.
- [ ] Dry-run mode: an interpreter that prints `StartFetch` instead of fetching — preview what a crawl would touch before running it.
- [ ] JS target: the pure core is runtime-agnostic; only the OTP shell would need a promise-based counterpart.
- [ ] Check external links without crawling them: out-of-scope links fetched once, never expanded, via `expand: Bool` on the scoop (Heritrix hop paths).
- [ ] Parent-to-child context during the crawl (Colly `Ctx`, Crawlee `userData`). The post-crawl join over `links` covers it until then.
- [ ] Make the frontier `Slot` lifecycle explicit (idle, in flight, cooling, penalized) as a union type with `update`, instead of `in_flight`/`next_at`/`failures` combinations. Plain Gleam, no state machine dependency.
