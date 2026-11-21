import gleam/http/response
import gleam/list
import gleam/result
import gleam/string
import gleam/uri
import spoon/page

pub fn redirect(
  resp: response.Response(String),
  handle: fn(response.Response(String)) -> List(page.Link),
) -> List(page.Link) {
  case resp.status >= 300 && resp.status < 400 {
    True -> redirect_links(resp)
    False -> handle(resp)
  }
}

fn redirect_links(resp: response.Response(String)) -> List(page.Link) {
  response.get_header(resp, "location")
  |> result.try(uri.parse)
  |> result.map(fn(target) { [page.Link(url: target, nofollow: False)] })
  |> result.unwrap([])
}

pub fn content_type(
  mime_types: List(String),
  resp: response.Response(String),
  handle: fn(response.Response(String)) -> List(page.Link),
) -> List(page.Link) {
  case response.get_header(resp, "content-type") {
    Ok(content_type) ->
      case list.any(mime_types, string.starts_with(content_type, _)) {
        True -> handle(resp)
        False -> []
      }
    Error(_) -> []
  }
}
