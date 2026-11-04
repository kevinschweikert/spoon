import gleam/dict
import gleam/http/response
import gleam/int
import gleam/io
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import gleam/uri
import presentable_soup as soup
import spoon/page

pub fn log(
  page: page.Page,
  handle: fn(page.Page) -> #(item, page.Candidates),
) -> #(item, page.Candidates) {
  let url = page.url |> uri.to_string
  io.println("HTTP " <> int.to_string(page.status) <> " " <> url)
  handle(page)
}

pub fn status_ok(
  if_not: item,
  page: page.Page,
  handle: fn(page.Page) -> #(item, page.Candidates),
) -> #(item, page.Candidates) {
  case page.status >= 200 && page.status < 400 {
    True -> handle(page)
    False -> #(if_not, page.Candidates([]))
  }
}

pub fn protocol_http(
  page: page.Page,
  handle: fn(page.Page) -> #(item, page.Candidates),
) -> #(item, page.Candidates) {
  let #(item, page.Candidates(links)) = handle(page)

  #(
    item,
    links
      |> list.filter_map(fn(link) {
        case link.scheme {
          option.None | option.Some("http") | option.Some("https") -> Ok(link)
          _ -> Error(Nil)
        }
      })
      |> page.Candidates,
  )
}

pub fn same_host(
  base_url: uri.Uri,
  page: page.Page,
  handle: fn(page.Page) -> #(item, page.Candidates),
) -> #(item, page.Candidates) {
  let #(item, page.Candidates(links)) = handle(page)

  #(
    item,
    links
      |> list.filter_map(fn(link) {
        case base_url.host == link.host && base_url.scheme == link.scheme {
          True -> Ok(link)
          False -> Error(Nil)
        }
      })
      |> page.Candidates,
  )
}

pub fn resolve(
  page: page.Page,
  handle: fn(page.Page) -> #(item, page.Candidates),
) -> #(item, page.Candidates) {
  let #(item, page.Candidates(links)) = handle(page)

  #(
    item,
    links
      |> list.filter_map(resolve_url(page.url, _))
      |> page.Candidates,
  )
}

fn resolve_url(from: uri.Uri, link: uri.Uri) -> Result(uri.Uri, Nil) {
  use resolved <- result.map(uri.merge(from, link))
  case string.ends_with(link.path, "/"), string.ends_with(resolved.path, "/") {
    True, False -> uri.Uri(..resolved, path: resolved.path <> "/")
    _, _ -> resolved
  }
}

pub fn redirect(
  resp: response.Response(String),
  handle: fn(response.Response(String)) -> List(uri.Uri),
) -> List(uri.Uri) {
  case resp.status >= 300 && resp.status < 400 {
    True -> redirect_links(resp)
    False -> handle(resp)
  }
}

fn redirect_links(resp: response.Response(String)) -> List(uri.Uri) {
  response.get_header(resp, "location")
  |> result.try(uri.parse)
  |> result.map(fn(target) { [target] })
  |> result.unwrap([])
}

pub fn content_type(
  mime_types: List(String),
  resp: response.Response(String),
  handle: fn(response.Response(String)) -> List(uri.Uri),
) -> List(uri.Uri) {
  case response.get_header(resp, "content-type") {
    Ok(content_type) ->
      case list.any(mime_types, string.starts_with(content_type, _)) {
        True -> handle(resp)
        False -> []
      }
    Error(_) -> []
  }
}

pub fn anchors(body: String) -> List(uri.Uri) {
  let anchors =
    [soup.with_tag("a")]
    |> soup.elements()
    |> soup.return(soup.attributes())
    |> soup.scrape(body)
    |> result.unwrap([])

  use anchor <- list.filter_map(anchors)
  anchor
  |> dict.from_list()
  |> dict.get("href")
  |> result.try(uri.parse)
}
