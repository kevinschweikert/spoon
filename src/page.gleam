import gleam/uri

pub type Page {
  Page(url: uri.Uri, status: Int, body: String, candidates: List(uri.Uri))
}

pub type Candidates {
  Candidates(links: List(uri.Uri))
}

pub type FetchError {
  PrefetchRefused
  FetchError
}
