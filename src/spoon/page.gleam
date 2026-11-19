import gleam/option
import gleam/uri

pub type Link {
  Link(url: uri.Uri, nofollow: Bool)
}

pub fn is_crawlable(link: Link) -> Bool {
  !link.nofollow
}

pub type Page {
  Page(url: uri.Uri, status: Int, body: String, candidates: List(Link))
}

pub type Outcome(item) {
  Outcome(item: item, candidates: List(Link))
}

@internal
pub type Report(item) {
  Fetched(outcome: Outcome(item), crawl_delay_ms: option.Option(Int))
  Noindex(candidates: List(Link), crawl_delay_ms: option.Option(Int))
  Skipped
}

pub type HttpError {
  Throttled(retry_after_ms: option.Option(Int))
  BadResponse
  Network
}
