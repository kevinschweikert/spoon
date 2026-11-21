import gleam/http/request
import gleam/http/response
import gleam/option
import spoon/internal/crawl
import spoon/internal/requestable
import spoon/page
import spoon/visit

pub type Config(item) {
  Config(
    base_url: requestable.Requestable,
    seeds: List(requestable.Requestable),
    fetch: fn(request.Request(String)) ->
      Result(response.Response(String), visit.Failure),
    scrape: fn(page.Page(item), response.Response(String)) -> page.Page(item),
    max_pages: option.Option(Int),
    max_concurrency: Int,
    user_agent: String,
    clock: fn() -> Int,
    delay_ms: Int,
    max_attempts: Int,
    max_depth: option.Option(Int),
    respect_robots: Bool,
    scope: crawl.Scope,
  )
}
