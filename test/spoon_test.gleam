import gleam/dict
import gleam/http/request
import gleam/http/response
import gleam/list
import gleam/uri
import gleeunit
import spoon
import spoon/page

pub fn main() -> Nil {
  gleeunit.main()
}

fn mock_fetch(
  request: request.Request(String),
) -> Result(response.Response(String), page.HttpError) {
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
  <a href=\"mailto:test@example.com\">Mail</a>"
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
  let assert Ok(collected) =
    spoon.new(start)
    |> spoon.delay(0)
    |> spoon.fetch(mock_fetch)
    |> spoon.on_page(fn(page) { page.Outcome(page, page.candidates) })
    |> spoon.fold([], fn(acc, page) { [page, ..acc] })

  assert list.length(collected) == 7
  let collected =
    collected |> list.map(fn(p) { #(p.url, p) }) |> dict.from_list()

  let assert Ok(index) = dict.get(collected, path("/index"))
  assert list.length(index.candidates) == 9

  let assert Ok(blog) = dict.get(collected, path("/blog"))
  assert blog.candidates == []

  let assert Ok(about) = dict.get(collected, path("/about"))
  assert list.length(about.candidates) == 1

  let assert Ok(old) = dict.get(collected, path("/old"))
  assert list.length(old.candidates) == 1
  assert old.status == 301

  let assert Ok(new) = dict.get(collected, path("/new"))
  assert new.candidates == []

  let assert Ok(missing) = dict.get(collected, path("/missing"))
  assert missing.status == 404

  let assert Ok(server_error) = dict.get(collected, path("/server_error"))
  assert server_error.status == 500

  assert !dict.has_key(collected, path("/forbidden"))
  assert !dict.has_key(collected, path("/secrets"))
  assert !dict.has_key(collected, path("/robots.txt"))
}
