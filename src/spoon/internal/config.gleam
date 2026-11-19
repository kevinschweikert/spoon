import gleam/http/request
import gleam/http/response
import gleam/uri
import spoon/internal/requestable
import spoon/page

pub type Scope {
  AllowAll
  AllowedHosts(List(String))
}

pub type Config(item) {
  Config(
    base_url: requestable.Requestable,
    seeds: List(requestable.Requestable),
    fetch: fn(request.Request(String)) ->
      Result(response.Response(String), page.HttpError),
    on_page: fn(page.Page) -> page.Outcome(item),
    next: fn(response.Response(String)) -> List(uri.Uri),
    max_pages: Int,
    max_concurrency: Int,
    user_agent: String,
    clock: fn() -> Int,
    delay_ms: Int,
    max_attempts: Int,
    respect_robots: Bool,
    scope: Scope,
  )
}
