# TODO

I know this is LLM generated but this is my way of brainstorming and keeping track of tasks. The code will still be hand written, because that's the fun part and why i'm doing it.

## Next: Page API (breaking)

fetch → prefill `links` → `on_page` → normalize → scope → enqueue.
`fold` gets one `Visit` per URL, after retries.

- [ ] Plain record `spoon/visit.Visit(item)`: `url`, `depth`, `outcome`, `links: List(Uri)`, `items: List(item)`
- [ ] `Outcome = Responded(status) | Skipped(Skip) | Failed(Failure)`
- [ ] `Skip = Disallowed | RobotsUnavailable`
- [ ] `Failure = Timeout | Network | Crashed(String) | InvalidUrl`
- [ ] `HttpError` moves from `page` to `spoon/fetch`
- [ ] `crawl` emits `GaveUp(scoop)` when retries run out, so `fold` sees each `Failed` once
- [ ] Internal `prefill(Response) -> List(Uri)`: anchors minus `rel=nofollow`, `Location` on redirects, none on meta nofollow
- [ ] `on_page(fn(Visit(item), Response(String)) -> Visit(item))` is the only hook; 2xx, not noindex
- [ ] Builder generic in `item`; default `on_page` returns the visit unchanged
- [ ] `max_pages` counts responses, not skips
- [ ] No parent field; referrers come from inverting `links`
- [ ] No `fold_until`; early stop is knobs, `links: []` or `spoon.stop`
- [ ] Delete `middleware`; `redirect`/`content_type`/`anchors` move into `prefill`, `status_ok`/`log` go
- [ ] Delete `next`, `Page`, `Link`, `Report`, old `Outcome`
- [ ] `start` with `await`/`stop`/`stats`; `fold` = start + await, `run` = fold over Nil
- [ ] `spoon.Error` instead of `actor.StartError`

Checkpoint: `smoke_test` folds every URL, `/forbidden` and `/noindex` included; a link graph and a dead-link report are each one `fold`.

## Then: scope and bounds

- [ ] Redirect hop limit; redirects don't increment depth
- [ ] Per-origin queued cap, global `max_frontier` (drop and count, never block)
- [ ] Maximum URL length
- [ ] Path include/exclude as a scope knob
- [ ] Subdomain matching as an explicit option
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

- [ ] Tests for `requestable.resolve` and `prefill`
- [ ] Remove the demo

## Later / maybe

- [ ] Resumable crawls: swappable visited-set store, ETags, wall time only there
- [ ] Frontier `Slot` lifecycle as an explicit union with `update`
- [ ] JS target; only the OTP shell needs a counterpart
