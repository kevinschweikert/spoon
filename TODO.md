# TODO

I know this is LLM generated but this is my way of brainstorming and keeping track of tasks. The code will still be hand written, because that's the fun part and why i'm doing it.

## Now: finish origin-keyed scheduling

- [x] `spoon.respect_robots(Bool)`, default `True`

Checkpoint: a 429-ing origin slows exponentially while others continue, on the stepped clock.

## Next: Page API (breaking)

fetch → `extract_links` → normalize → `on_page` → scope → enqueue.
`fold` gets one `Visit` per URL, after retries.

- [ ] Opaque `Page(item)` and `Link(url, nofollow)`; `page.new` for tests
- [ ] Accessors `url`/`status`/`depth`/`links`/`item`, setters `with_item`/`nofollow`
- [ ] `links` keeps every link; scope and nofollow filter the crawl
- [ ] `extract_links` replaces `next`, default `extract.anchors`; only way to add URLs
- [ ] `on_page` for 2xx only, gets `Page(Nil)` + `Response`
- [ ] `fold` over `Visit = Fetched | Redirected | Skipped | Failed`
- [ ] `Skip = Disallowed | RobotsUnavailable`
- [ ] `Failure = Status | Timeout | Network | Crashed(String) | InvalidUrl`
- [ ] `max_pages` counts responses, not skips
- [ ] No parent field; referrers come from inverting `links`
- [ ] `start` with `await`/`stop`/`stats`; `fold` = start + await, `run` = fold over Nil
- [ ] `spoon.Error` instead of `actor.StartError`
- [ ] Delete `prefetch`, `next`, `Outcome`, `Report`
- [ ] `middleware` → pure `extract` helpers; `log` wraps a fold fn
- [ ] Rename to `allowed_hosts`/`allow_all_hosts`, `rate_limit` → `delay`

Checkpoint: a link graph and a dead-link report are each one `fold`.

## Then: scope and bounds

- [ ] `max_depth`, set from the parent in `push_links`
- [ ] Redirect hop limit; redirects don't increment depth
- [ ] Per-origin queued cap, global `max_frontier` (drop and count, never block)
- [ ] Maximum URL length
- [ ] Path include/exclude as a scope knob
- [ ] Subdomain matching as an explicit option
- [ ] `spoon.respect_nofollow(Bool)`, default `True`
- [ ] `noindex` and canonical-link preference
- [ ] Sitemap ingestion via `extract.sitemap_locs`; needs `grip.sitemaps`

## Fetch rework (breaking, decide before 1.0)

- [ ] `options: fetch.Options(timeout_ms, max_body_size)` + `make_fetch: fn(Options) -> Fetch`
- [ ] Resolved once at start, so setters and a swapped transport compose in any pipe order
- [ ] Flat setters `spoon.fetch_timeout`, `spoon.max_body_size`
- [ ] `user_agent` and `spoon.headers` go on the `Request`; `Options` stays transport-advisory
- [ ] `Fetch` returns `Response(BitArray)`; charset decode worker-side
- [ ] Contract: never follow redirects, don't strip spoon's headers
- [ ] Skip bodies by `Content-Type`/`Content-Length` where the transport can

## Housekeeping

- [ ] Tests for `normalize`, `resolve_url`, `extract`
- [ ] Remove the demo

## Later / maybe

- [ ] Resumable crawls: swappable visited-set store, ETags, wall time only there
- [ ] Frontier `Slot` lifecycle as an explicit union with `update`
- [ ] JS target; only the OTP shell needs a counterpart
