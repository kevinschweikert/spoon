import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/httpc
import gleam/list
import gleam/otp/actor.{type StartResult}
import gleam/otp/factory_supervisor as factory
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision
import gleam/result
import gleam/uri
import grip/origin

import spoon/internal/config
import spoon/internal/coordinator
import spoon/internal/fetcher
import spoon/middleware
import spoon/page

pub opaque type Builder(item) {
  Builder(config: config.Config(item))
}

@external(erlang, "spoon_ffi", "monotonic_time")
fn monotonic_time() -> Int

/// Create a new crawl config
///
/// Run it with either `run` for a simple case or `fold` if you
/// need an accumulator
///
/// ## Examples
///
/// ```gleam
/// "https://example.com"
/// |> spoon.new()
/// |> spoon.run()
/// ```
pub fn new(url url: uri.Uri) -> Builder(Nil) {
  Builder(config.Config(
    base_url: url,
    start_urls: [],
    fetch: default_fetch,
    on_page: default_on_page(url, _),
    prefetch: Ok,
    next: default_next,
    max_pages: 10,
    max_concurrency: 10,
    user_agent: "spoon/1.0",
    clock: monotonic_time,
    delay_ms: 1000,
    max_attempts: 3,
  ))
}

/// Adds starting urls to the crawl list
///
/// These urls don't have to be on the same host like the starting
/// url. This is especially useful when you want to give the crawler
/// some hints where to search for links.
///
/// If no seed is given, the only starting url is the one given in
/// `new`
pub fn seed(builder: Builder(item), url: uri.Uri) -> Builder(item) {
  Builder(
    config.Config(..builder.config, start_urls: [
      url,
      ..builder.config.start_urls
    ]),
  )
}

/// Callback when a new link was visited
///
/// Override this if you want to use change the middleware or 
/// how candidates get extracted from the page.
///
/// Default is using the following middlewares:
///
/// - `middleware.status_ok`
/// - `middleware.same_host`
/// - `middleware.resolve`
/// - `middleware.protocol_http`
pub fn on_page(
  builder: Builder(a),
  on: fn(uri.Uri, page.Page) -> #(b, page.Candidates),
) -> Builder(b) {
  let base_url = builder.config.base_url
  Builder(
    config.Config(..builder.config, on_page: fn(page) { on(base_url, page) }),
  )
}

/// Callback before a page gets visited
///
/// Depending on the result the page will be visisted or
/// not.
pub fn prefetch(
  builder: Builder(a),
  prefetch: fn(uri.Uri) -> Result(uri.Uri, page.FetchError),
) -> Builder(a) {
  Builder(config.Config(..builder.config, prefetch:))
}

/// Callback after a page got visited to get the next potential
/// candidates to visit next.
///
/// By default it will look for all html `<a>` tags and extract
/// their `href` attributes.
pub fn next(
  builder: Builder(item),
  next: fn(response.Response(String)) -> List(uri.Uri),
) -> Builder(item) {
  Builder(config.Config(..builder.config, next:))
}

/// Sets the maximum number of pages after the crawl will be
/// aborted
pub fn max_pages(builder: Builder(item), max_pages: Int) -> Builder(item) {
  Builder(config.Config(..builder.config, max_pages:))
}

/// Sets the maximum number of in flight HTTP requests at a given time
pub fn max_concurrency(
  builder: Builder(item),
  max_concurrency: Int,
) -> Builder(item) {
  Builder(config.Config(..builder.config, max_concurrency:))
}

/// Sets the minimum delay in milliseconds between two requests to
/// the same origin
pub fn rate_limit(builder: Builder(item), delay_ms: Int) -> Builder(item) {
  Builder(config.Config(..builder.config, delay_ms:))
}

/// Sets how often a URL is retried after an unsuccesful fetch before
/// it gets dropped
pub fn max_attempts(
  builder: Builder(item),
  max_attempts: Int,
) -> Builder(item) {
  Builder(config.Config(..builder.config, max_attempts:))
}

/// Sets the user agent for identifying HTTP requests and matching
/// the `robots.txt` rules.
pub fn user_agent(builder: Builder(item), user_agent: String) -> Builder(item) {
  Builder(config.Config(..builder.config, user_agent:))
}

/// Just runs the crawl and call `on_page` for each page
pub fn run(builder: Builder(Nil)) -> Nil {
  fold(builder, Nil, fn(_acc, _item) { Nil })
}

/// Same as `run` but can collect data from a crawl
///
/// Same as `list.fold` that it accepts an inital value
/// and an accumulator.
pub fn fold(
  builder: Builder(item),
  initial: acc,
  combine: fn(acc, item) -> acc,
) -> acc {
  list.each([builder.config.base_url, ..builder.config.start_urls], fn(seed) {
    let assert Ok(_) = origin.from_uri(seed)
      as "seeds need an http(s) scheme and a host"
  })
  let coordinator_name = process.new_name("coordinator")
  let fetchers_name = process.new_name("fetchers")
  let reply = process.new_subject()
  let assert Ok(_) =
    start_supervision_tree(
      fetchers_name,
      coordinator_name,
      builder.config,
      reply,
      initial,
      combine,
    )
  process.receive_forever(reply)
}

fn default_on_page(
  base_url: uri.Uri,
  page: page.Page,
) -> #(Nil, page.Candidates) {
  use page <- middleware.status_ok(Nil, page)
  use page <- middleware.same_host(base_url, page)
  use page <- middleware.resolve(page)
  use page <- middleware.protocol_http(page)
  #(Nil, page.Candidates(page.candidates))
}

fn default_next(resp: response.Response(String)) -> List(uri.Uri) {
  use resp <- middleware.redirect(resp)
  use resp <- middleware.content_type(
    ["text/html", "text/plain", "application/xml"],
    resp,
  )
  middleware.anchors(resp.body)
}

fn default_fetch(
  request: request.Request(String),
) -> Result(response.Response(String), page.FetchError) {
  // TODO: make the max size and redirect behaviour configurable by the user
  httpc.configure()
  |> httpc.follow_redirects(False)
  |> httpc.timeout(5000)
  |> httpc.max_body_size(httpc.Bytes(10 * 1024 * 1024))
  |> httpc.dispatch(request)
  |> result.replace_error(page.FetchError)
}

fn start_supervision_tree(
  fetchers_name: process.Name(_),
  coordinator_name: process.Name(_),
  config: config.Config(item),
  reply: process.Subject(acc),
  initial: acc,
  combine: fn(acc, item) -> acc,
) -> StartResult(_) {
  let fetchers_supervisor =
    factory.worker_child(fetcher.start)
    |> factory.named(fetchers_name)
    |> factory.restart_strategy(supervision.Temporary)
    |> factory.supervised()

  supervisor.new(supervisor.RestForOne)
  |> supervisor.add(
    supervision.worker(fn() {
      coordinator.start(
        coordinator_name,
        config,
        initial,
        combine,
        reply,
        fetchers_name,
      )
    })
    |> supervision.restart(supervision.Transient),
  )
  |> supervisor.add(fetchers_supervisor)
  |> supervisor.start()
}
