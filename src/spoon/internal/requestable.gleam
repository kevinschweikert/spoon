import gleam/http/request
import gleam/list
import gleam/option
import gleam/result
import gleam/uri
import grip/origin

pub type Requestable {
  Requestable(
    origin: origin.Origin,
    path: String,
    query: List(#(String, String)),
  )
}

pub fn from_uri(url: uri.Uri) -> Result(Requestable, Nil) {
  let url = normalize(url)
  use origin <- result.try(origin.from_uri(url))
  use query <- result.try(url.query |> option.unwrap("") |> uri.parse_query)
  Ok(Requestable(origin:, path: url.path, query:))
}

pub fn to_uri(requestable: Requestable) -> uri.Uri {
  let base = requestable.origin |> origin.to_uri
  let query_string = uri.query_to_string(requestable.query)
  uri.Uri(
    ..base,
    path: requestable.path,
    query: case list.is_empty(requestable.query) {
      True -> option.None
      False -> option.Some(query_string)
    },
  )
}

pub fn to_request(
  requestable: Requestable,
  user_agent: String,
) -> request.Request(String) {
  requestable.origin
  |> origin.to_request
  |> request.set_path(requestable.path)
  |> request.set_query(requestable.query)
  |> request.set_header("user-agent", user_agent)
}

pub fn resolve(base: Requestable, link: uri.Uri) -> Result(Requestable, Nil) {
  use merged <- result.try(base |> to_uri |> uri.merge(link))
  from_uri(merged)
}

fn normalize(url: uri.Uri) -> uri.Uri {
  let path = case url.path {
    "" -> "/"
    path -> path
  }

  uri.Uri(..url, path:, fragment: option.None)
}
