import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/httpc
import gleam/list
import gleam/option
import gleam/otp/actor.{type StartResult}
import gleam/otp/static_supervisor as supervisor
import gleam/result
import gleam/string
import gleam/uri
import logging
import spoon/internal/crawl
import spoon/internal/policy_cache
import spoon/internal/requestable
import spoon/internal/worker
import spoon/visit

import spoon/internal/config
import spoon/internal/coordinator
import spoon/page

pub opaque type Requestable {
  Requestable(requestable.Requestable)
}

pub opaque type Builder(item) {
  Builder(config: config.Config(item))
}

/// This converts a string representing a string to an internal
/// representation. This checks if the link contains a requestable
/// scheme, if a host is set and removes fragments from the link itself.
///
/// This is to ensure that the given links are conforming to the needs of
/// the crawl.
pub fn request(input: String) -> Result(Requestable, Nil) {
  use url <- result.try(uri.parse(input))
  request_from_uri(url)
}

/// Same as `request` but you already pass a `uri.Uri` instead of a string.
pub fn request_from_uri(input: uri.Uri) -> Result(Requestable, Nil) {
  use requestable <- result.try(requestable.from_uri(input))
  Ok(Requestable(requestable))
}

@external(erlang, "spoon_ffi", "monotonic_time")
@internal
pub fn monotonic_time() -> Int

/// Create a new crawl config
///
/// Run it with either `run` for a simple case or `fold` if you
/// need an accumulator
///
/// By default it stops after 10 found pages. Use `max_pages` or
/// `unlimited_pages` to control long the crawler should go on.
///
/// ## Examples
///
/// ```gleam
/// "https://example.com"
/// |> spoon.new()
/// |> spoon.run()
/// ```
pub fn new(url url: Requestable) -> Builder(Nil) {
  let Requestable(requestable) = url
  Builder(
    config.Config(
      base_url: requestable,
      seeds: [],
      fetch: default_fetch,
      scrape: fn(page, _response) { page },
      max_pages: option.Some(10),
      max_depth: option.None,
      max_concurrency: 10,
      user_agent: "spoon/1.0",
      clock: monotonic_time,
      delay_ms: 1000,
      max_attempts: 3,
      respect_robots: True,
      scope: case requestable.to_uri(requestable).host {
        option.Some(host) -> crawl.AllowedHosts([host])
        option.None -> crawl.AllowedHosts([])
      },
    ),
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
pub fn seed(builder: Builder(item), url: Requestable) -> Builder(item) {
  let Requestable(requestable) = url
  Builder(
    config.Config(..builder.config, seeds: [requestable, ..builder.config.seeds]),
  )
}

pub fn fetch(
  builder: Builder(item),
  fetch: fn(request.Request(String)) ->
    Result(response.Response(String), visit.Failure),
) {
  Builder(config.Config(..builder.config, fetch:))
}

/// Callback when a new link was visited
///
/// Override this if you want to use change the middleware or 
/// how candidates get extracted from the page.
///
/// Default is using the following middlewares:
///
/// - `middleware.status_ok`
pub fn scrape(
  builder: Builder(a),
  scrape: fn(page.Page(item), response.Response(String)) -> page.Page(item),
) -> Builder(item) {
  Builder(config.Config(..builder.config, scrape:))
}

/// Sets the maximum number of pages after the crawl will be
/// aborted
pub fn max_pages(builder: Builder(item), max_pages: Int) -> Builder(item) {
  Builder(config.Config(..builder.config, max_pages: option.Some(max_pages)))
}

/// Disables the page limit and will crawl unless no links are found.
/// This will result in an unbounded crawl and should we used with care!
pub fn unlimited_pages(builder: Builder(item)) {
  Builder(config.Config(..builder.config, max_pages: option.None))
}

/// Sets the maximum depths the links get crawled. Each link on a page increases
/// the depth
///
/// Start URL: depth == 1
/// Eeach child URL: depth == 2
/// Each child of child URL: depth == 3
/// ...
pub fn max_depth(builder: Builder(item), max_depth: Int) -> Builder(item) {
  Builder(config.Config(..builder.config, max_depth: option.Some(max_depth)))
}

/// Sets the maximum number of in flight HTTP requests at a given time
pub fn max_concurrency(
  builder: Builder(item),
  max_concurrency: Int,
) -> Builder(item) {
  Builder(config.Config(..builder.config, max_concurrency:))
}

/// Sets the minimum delay in milliseconds between two requests to
/// the same host.
pub fn delay(builder: Builder(item), delay_ms: Int) -> Builder(item) {
  Builder(config.Config(..builder.config, delay_ms:))
}

/// Configures the crawler to consult a `/robots.txt` beforehand and respect
/// it's rules. It is recommended to keep this set to `True` so the crawl is
/// not overloading servers and requesting unwanted resources.
pub fn respect_robots(
  builder: Builder(item),
  respect_robots: Bool,
) -> Builder(item) {
  Builder(config.Config(..builder.config, respect_robots:))
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

/// Each found link is compared with this list and only if they match the
/// specified host, we continue crawling. The matching is case  insensitive.
///
/// By default the initial url is used  as the only host, so we crawl only
/// on a single host if not further specified.
pub fn allowed_hosts(builder: Builder(item), allowed: List(String)) {
  Builder(
    config.Config(
      ..builder.config,
      scope: crawl.AllowedHosts(list.map(allowed, string.lowercase)),
    ),
  )
}

/// Disables host matching and basically crawls the whole web.
/// Use with caution!
pub fn allow_all_hosts(builder: Builder(item)) {
  Builder(config.Config(..builder.config, scope: crawl.AllowAll))
}

/// Just runs the crawl and calls `on_page` for each page without any
/// accumulator
///
/// This can be useful if you only need side effects to fill something
/// like ETS. This avoids storing the intermediate state in the accumulator.
pub fn run(builder: Builder(Nil)) -> Result(Nil, actor.StartError) {
  fold(builder, Nil, fn(_acc, _item) { Nil })
}

/// Same as `run` but can collect data from a crawl
///
/// Same as `list.fold` that it accepts an inital value
/// and an accumulator.
pub fn fold(
  builder: Builder(item),
  initial: acc,
  combine: fn(acc, visit.Visit(item)) -> acc,
) -> Result(acc, actor.StartError) {
  let coordinator_name = process.new_name("coordinator")
  let workers_name = process.new_name("workers")
  let policy_cache_name = process.new_name("policy_cache")
  let reply = process.new_subject()
  use _ <- result.try(start_supervision_tree(
    workers_name,
    coordinator_name,
    policy_cache_name,
    builder.config,
    reply,
    initial,
    combine,
  ))
  Ok(process.receive_forever(reply))
}

fn default_fetch(
  request: request.Request(String),
) -> Result(response.Response(String), visit.Failure) {
  // TODO: make the max size and redirect behaviour configurable by the user
  httpc.configure()
  |> httpc.follow_redirects(False)
  |> httpc.timeout(5000)
  |> httpc.max_body_size(httpc.Bytes(10 * 1024 * 1024))
  |> httpc.dispatch(request)
  |> result.map_error(fn(err) {
    case err {
      httpc.InvalidUtf8Response -> visit.BadResponse
      httpc.FailedToConnect(..) -> visit.Network
      httpc.ResponseTimeout -> visit.Network
      httpc.ResponseHeaderTooLarge -> visit.BadResponse
      httpc.ResponseBodyTooLarge -> visit.BadResponse
    }
  })
}

fn start_supervision_tree(
  worker_name: process.Name(worker.Message),
  policy_cache_name: process.Name(_),
  coordinator_name: process.Name(_),
  config: config.Config(item),
  reply: process.Subject(acc),
  initial: acc,
  combine: fn(acc, visit.Visit(item)) -> acc,
) -> StartResult(_) {
  logging.configure()

  supervisor.new(supervisor.RestForOne)
  |> supervisor.add(worker.supervised(worker_name))
  |> supervisor.add(policy_cache.supervised(
    policy_cache_name,
    config,
    worker_name,
  ))
  |> supervisor.add(coordinator.supervised(
    coordinator_name,
    config,
    initial,
    combine,
    reply,
    worker_name,
    policy_cache_name,
  ))
  |> supervisor.start()
}
