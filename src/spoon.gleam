import gleam/http/request
import gleam/http/response
import gleam/httpc
import gleam/list
import gleam/otp/supervision
import gleam/result
import gleam/uri
import internal/coordinator
import middleware
import page

import gleam/erlang/process
import gleam/otp/actor.{type StartResult}
import gleam/otp/factory_supervisor as factory
import gleam/otp/static_supervisor as supervisor
import internal/fetcher

pub type Page =
  page.Page

pub type Next =
  page.Candidates

pub opaque type Config(item) {
  Config(
    base_url: uri.Uri,
    start_urls: List(uri.Uri),
    fetch: fn(uri.Uri) -> Result(response.Response(String), page.FetchError),
    on_page: fn(page.Page) -> #(item, page.Candidates),
    prefetch: fn(uri.Uri) -> Result(uri.Uri, page.FetchError),
    next: fn(response.Response(String)) -> List(uri.Uri),
    max_pages: Int,
    max_concurrency: Int,
  )
}

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
pub fn new(url url: String) -> Config(Nil) {
  let assert Ok(uri) = uri.parse(url)
  Config(
    base_url: uri,
    start_urls: [],
    fetch: default_fetch,
    on_page: default_on_page(uri, _),
    prefetch: Ok,
    next: default_next,
    max_pages: 10,
    max_concurrency: 10,
  )
}

/// Adds starting urls to the crawl list
///
/// These urls don't have to be on the same host like the starting
/// url. This is especially useful when you want to give the crawler
/// some hints where to search for links.
///
/// If no seed is given, the only starting url is the one given in
/// `new`
pub fn seed(config: Config(item), url: String) -> Config(item) {
  let assert Ok(uri) = uri.parse(url)
  Config(..config, start_urls: [uri, ..config.start_urls])
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
  config: Config(a),
  on: fn(uri.Uri, page.Page) -> #(b, page.Candidates),
) -> Config(b) {
  Config(
    base_url: config.base_url,
    start_urls: config.start_urls,
    fetch: config.fetch,
    on_page: fn(page) { on(config.base_url, page) },
    prefetch: config.prefetch,
    next: config.next,
    max_pages: config.max_pages,
    max_concurrency: config.max_concurrency,
  )
}

/// Callback before a page gets visited
///
/// Depending on the result the page will be visisted or
/// not.
pub fn prefetch(
  config: Config(a),
  prefetch: fn(uri.Uri) -> Result(uri.Uri, page.FetchError),
) -> Config(a) {
  Config(..config, prefetch:)
}

/// Callback after a page got visited to get the next potential
/// candidates to visit next.
///
/// By default it will look for all html `<a>` tags and extract
/// their `href` attributes.
pub fn next(
  config: Config(item),
  next: fn(response.Response(String)) -> List(uri.Uri),
) -> Config(item) {
  Config(..config, next: next)
}

/// Sets the maximum number of pages after the crawl will be
/// aborted
pub fn max_pages(config: Config(item), max: Int) -> Config(item) {
  Config(..config, max_pages: max)
}

/// Sets the maximum number of in flight HTTP requests at a given time
pub fn max_concurrency(config: Config(item), max: Int) -> Config(item) {
  Config(..config, max_concurrency: max)
}

/// Just runs the crawl and call `on_page` for each page
pub fn run(config: Config(Nil)) -> Nil {
  fold(config, Nil, fn(_acc, _item) { Nil })
}

/// Same as `run` but can collect data from a crawl
///
/// Same as `list.fold` that it accepts an inital value
/// and an accumulator.
pub fn fold(
  config: Config(item),
  initial: acc,
  combine: fn(acc, item) -> acc,
) -> acc {
  let coordinator_name = process.new_name("coordinator")
  let fetchers_name = process.new_name("fetchers")
  let reply = process.new_subject()
  let assert Ok(_) =
    start_supervision_tree(
      fetchers_name,
      coordinator_name,
      config,
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
  url: uri.Uri,
) -> Result(response.Response(String), page.FetchError) {
  use req <- result.try(
    request.from_uri(url)
    |> result.replace_error(page.FetchError),
  )
  let client = httpc.configure() |> httpc.follow_redirects(False)
  httpc.dispatch(client, req) |> result.replace_error(page.FetchError)
}

fn start_supervision_tree(
  fetchers_name: process.Name(_),
  coordinator_name: process.Name(_),
  config: Config(item),
  reply: process.Subject(acc),
  initial: acc,
  combine: fn(acc, item) -> acc,
) -> StartResult(_) {
  let fetchers_supervisor =
    factory.worker_child(fetcher.start)
    |> factory.named(fetchers_name)
    |> factory.supervised()

  supervisor.new(supervisor.RestForOne)
  |> supervisor.add(
    supervision.worker(fn() {
      coordinator.start(
        coordinator_name,
        coordinator.Options(
          start_urls: [config.base_url, ..config.start_urls] |> list.unique(),
          on_page: config.on_page,
          prefetch: config.prefetch,
          fetch: config.fetch,
          next: config.next,
          fetchers: fetchers_name,
          max_pages: config.max_pages,
          max_in_flight: config.max_concurrency,
          initial:,
          combine:,
        ),
        reply,
      )
    })
    |> supervision.restart(supervision.Transient),
  )
  |> supervisor.add(fetchers_supervisor)
  |> supervisor.start()
}
