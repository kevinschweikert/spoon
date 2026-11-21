import gleam/option
import gleam/uri

pub type Visit(item) {
  Visit(
    url: uri.Uri,
    depth: Int,
    outcome: Outcome(item),
    parent: option.Option(uri.Uri),
  )
}

pub type Outcome(item) {
  Responded(status: Int, links: List(uri.Uri), item: option.Option(item))
  Skipped(reason: Skip)
  Failed(reason: Failure)
}

pub type Skip {
  Disallowed
  RobotsUnavailable
}

pub type Failure {
  Timeout
  BadResponse
  Throttled(retry_after_ms: option.Option(Int))
  Network
  Crashed
}
