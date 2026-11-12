import gleam/http/request
import gleam/http/response
import gleam/uri
import spoon/page

pub type Config(item) {
  Config(
    base_url: uri.Uri,
    start_urls: List(uri.Uri),
    fetch: fn(request.Request(String)) ->
      Result(response.Response(String), page.FetchError),
    on_page: fn(page.Page) -> #(item, page.Candidates),
    prefetch: fn(uri.Uri) -> Result(uri.Uri, page.FetchError),
    next: fn(response.Response(String)) -> List(uri.Uri),
    max_pages: Int,
    max_concurrency: Int,
    user_agent: String,
    clock: fn() -> Int,
    delay_ms: Int,
    max_attempts: Int,
  )
}
