import gleam/dict
import gleam/http/response
import gleam/int
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import gleam/time/calendar
import gleam/time/timestamp
import gleam/uri
import presentable_soup as soup
import spoon/page

pub fn log(
  page: page.Page,
  handle: fn(page.Page) -> page.Outcome(item),
) -> page.Outcome(item) {
  let url = page.url |> uri.to_string
  let now = timestamp.system_time() |> timestamp.to_rfc3339(calendar.utc_offset)
  io.println(now <> " " <> int.to_string(page.status) <> " " <> url)
  handle(page)
}

pub fn status_ok(
  if_not: item,
  page: page.Page,
  handle: fn(page.Page) -> page.Outcome(item),
) -> page.Outcome(item) {
  case page.status >= 200 && page.status < 400 {
    True -> handle(page)
    False -> page.Outcome(item: if_not, candidates: [])
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
