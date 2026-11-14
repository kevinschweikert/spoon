import gleam/http/request
import gleam/http/response
import gleam/uri
import spoon/page

pub type Scope {
  AllowAll
  AllowedHosts(List(String))
}

pub type Config(item) {
  Config(
    base_url: uri.Uri,
    seeds: List(uri.Uri),
    fetch: fn(request.Request(String)) ->
      Result(response.Response(String), page.FetchError),
    on_page: fn(page.Page) -> page.Outcome(item),
    prefetch: fn(uri.Uri) -> Result(uri.Uri, page.FetchError),
    next: fn(response.Response(String)) -> List(uri.Uri),
    max_pages: Int,
    max_concurrency: Int,
    user_agent: String,
    clock: fn() -> Int,
    delay_ms: Int,
    max_attempts: Int,
    scope: Scope,
  )
}
