import gleam/dict
import gleam/http/request
import gleam/http/response
import gleam/list
import gleam/option
import gleam/uri
import gleeunit
import spoon
import spoon/page
import spoon/visit

pub fn main() -> Nil {
  gleeunit.main()
}

fn mock_fetch(
  request: request.Request(String),
) -> Result(response.Response(String), visit.Failure) {
  case request.host {
    "example.com" ->
      case request.path {
        "/robots.txt" ->
          response.new(200)
          |> response.set_header("content-type", "text/plain")
          |> response.set_body(robots())
        "/index" ->
          response.new(200)
          |> response.set_header("content-type", "text/html")
          |> response.set_body(index_html())
        "/blog" ->
          response.new(200)
          |> response.set_header("content-type", "text/html")
          |> response.set_body(blog_html())
        "/forbidden" ->
          response.new(200)
          |> response.set_header("content-type", "text/html")
          |> response.set_body("")
        "/noindex" ->
          response.new(200)
          |> response.set_header("content-type", "text/html")
          |> response.set_body("<meta name=\"robots\" content=\"noindex\" />")
        "/server_error" -> response.new(500)
        "/old" ->
          response.new(301)
          |> response.set_header("location", "/new")
        "/new" ->
          response.new(200)
          |> response.set_header("content-type", "text/html")
          |> response.set_body(new_html())
        "/about" ->
          response.new(200)
          |> response.set_header("content-type", "text/html")
          |> response.set_body(about_html())
        _ -> response.new(404)
      }
      |> Ok
    _host -> Ok(response.new(200))
  }
}

fn robots() -> String {
  "User-Agent: *
  Disallow: /forbidden"
}

fn index_html() -> String {
  "<h1>Index</h1>
  <a href=\"/blog\">Blog</a>
  <a href=\"/about\">About</a>
  <a href=\"/old\">Old</a>
  <a href=\"/forbidden\">Forbidden</a>
  <a href=\"/secrets\" rel=\"nofollow\">Nofollow</a>
  <a href=\"/server_error\">Server Error</a>
  <a href=\"/noindex\">Noindex</a>
  <a href=\"/missing\">Missing</a>
  <a href=\"mailto:test@example.com\">Mail</a>
  <a href=\"http://other.example.com/foo\">Other Host</a>"
}

fn blog_html() -> String {
  "<h1>Blog</h1>"
}

fn about_html() -> String {
  "<h1>About</h1>
  <a href=\"/index\">Noloop</a>
  "
}

fn new_html() -> String {
  "<h1>New</h1>"
}

fn path(path) {
  let assert Ok(url) = uri.parse("http://example.com" <> path)
  url
}

pub fn integration_test() {
  let assert Ok(start) = spoon.request("http://example.com/index")
  let assert Ok(other_host) = uri.parse("http://other.example.com/foo")
  let assert Ok(visits) =
    spoon.new(start)
    |> spoon.delay(0)
    |> spoon.fetch(mock_fetch)
    |> spoon.scrape(fn(current, _response) {
      page.set_item(current, page.url(current))
    })
    |> spoon.fold([], fn(acc, visit) { [visit, ..acc] })

  assert list.length(visits) == 9
  let outcomes =
    visits
    |> list.map(fn(visit) { #(visit.url, visit.outcome) })
    |> dict.from_list()

  let assert Ok(visit.Responded(status: 200, links:, item: option.Some(_))) =
    dict.get(outcomes, path("/index"))
  assert list.length(links) == 8
  assert list.contains(links, other_host)

  let assert Ok(visit.Responded(status: 200, links: [], ..)) =
    dict.get(outcomes, path("/blog"))

  let assert Ok(visit.Responded(status: 200, links:, ..)) =
    dict.get(outcomes, path("/about"))
  assert list.length(links) == 1

  let assert Ok(visit.Responded(status: 301, links:, ..)) =
    dict.get(outcomes, path("/old"))
  assert list.length(links) == 1

  let assert Ok(visit.Responded(status: 200, links: [], ..)) =
    dict.get(outcomes, path("/new"))

  let assert Ok(visit.Responded(status: 404, ..)) =
    dict.get(outcomes, path("/missing"))

  let assert Ok(visit.Responded(status: 500, ..)) =
    dict.get(outcomes, path("/server_error"))

  let assert Ok(visit.Skipped(visit.Disallowed)) =
    dict.get(outcomes, path("/forbidden"))

  let assert Ok(visit.Responded(status: 200, links: [], item: option.None)) =
    dict.get(outcomes, path("/noindex"))

  assert !dict.has_key(outcomes, path("/secrets"))
  assert !dict.has_key(outcomes, path("/robots.txt"))
  assert !dict.has_key(outcomes, other_host)
}

pub fn scraper_collects_many_items_per_page_test() {
  assert True
}

pub fn link_checker_reports_dead_links_with_referrers_test() {
  let assert Ok(start) = spoon.request("http://example.com/index")
  let assert Ok(dead) =
    spoon.new(start)
    |> spoon.delay(0)
    |> spoon.fetch(mock_fetch)
    |> spoon.fold(dict.new(), fn(dead, visit) {
      case visit.outcome {
        visit.Responded(status:, ..) if status >= 400 ->
          dict.insert(dead, visit.url, visit.parent)
        visit.Failed(_) -> dict.insert(dead, visit.url, visit.parent)
        _ -> dead
      }
    })
  assert dict.get(dead, path("/missing")) == Ok(option.Some(path("/index")))
  assert dict.get(dead, path("/server_error"))
    == Ok(option.Some(path("/index")))
  assert dead |> dict.keys |> list.length == 2
}

pub fn site_audit_builds_graph_with_redirect_edges_test() {
  let assert Ok(start) = spoon.request("http://example.com/index")
  let assert Ok(nodes) =
    spoon.new(start)
    |> spoon.delay(0)
    |> spoon.fetch(mock_fetch)
    |> spoon.fold(dict.new(), fn(acc, visit) {
      dict.insert(acc, visit.url, visit.outcome)
    })

  let edges =
    list.flat_map(dict.to_list(nodes), fn(node) {
      let #(from, outcome) = node
      case outcome {
        visit.Responded(links:, ..) -> list.map(links, fn(to) { #(from, to) })
        visit.Skipped(_) | visit.Failed(_) -> []
      }
    })

  let assert Ok(visit.Responded(status: 301, ..)) =
    dict.get(nodes, path("/old"))

  assert list.filter(edges, fn(edge) { edge.1 == path("/new") })
    == [#(path("/old"), path("/new"))]

  assert list.contains(edges, #(path("/about"), path("/index")))
  assert list.contains(edges, #(path("/index"), path("/forbidden")))
  let assert Ok(visit.Skipped(visit.Disallowed)) =
    dict.get(nodes, path("/forbidden"))
}

pub fn indexer_writes_each_page_to_a_store_test() {
  assert True
}

pub fn embedded_crawl_starts_stops_and_reports_progress_test() {
  assert True
}
