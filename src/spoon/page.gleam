import gleam/option
import gleam/uri

pub type Page {
  Page(url: uri.Uri, status: Int, body: String, candidates: List(uri.Uri))
}

pub type Outcome(item) {
  Outcome(item: item, candidates: List(uri.Uri))
}

pub type Report(item) {
  Fetched(outcome: Outcome(item), crawl_delay_ms: option.Option(Int))
  Skipped
}

pub type HttpError {
  Throttled(retry_after_ms: option.Option(Int))
  BadRequest
  BadResponse
  Network
}
