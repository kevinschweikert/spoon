import gleam/uri

pub type Page {
  Page(url: uri.Uri, status: Int, body: String, candidates: List(uri.Uri))
}

pub type Outcome(item) {
  Outcome(item: item, candidates: List(uri.Uri))
}

pub type FetchError {
  PrefetchRefused
  FetchError
  InvalidUrl(uri.Uri)
}
