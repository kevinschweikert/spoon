import gleam/option
import gleam/uri

pub type Visit(item) {
  Visit(url: uri.Uri, depth: Int, outcome: Outcome(item))
}

pub type Outcome(item) {
  Responded(status: Int, links: List(uri.Uri), item: option.Option(item))
  Skipped(reason: SkipReason)
  Failed(reason: Failure)
}

pub type SkipReason {
  Disallowed
}

pub type Failure {
  Timeout
  Network
  Crashed(String)
}
