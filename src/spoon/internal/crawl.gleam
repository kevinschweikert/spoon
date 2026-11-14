import gleam/bool
import gleam/list
import gleam/option
import gleam/set
import gleam/uri
import grip/origin.{type Origin}
import spoon/internal/frontier
import spoon/page

pub type Settings {
  Settings(
    seeds: List(uri.Uri),
    delay_ms: Int,
    max_concurrency: Int,
    max_pages: Int,
    max_attempts: Int,
  )
}

pub type Crawl {
  Crawl(
    settings: Settings,
    seen: set.Set(uri.Uri),
    frontier: frontier.Frontier,
    requests: Int,
  )
}

pub type Message {
  Fetched(origin: Origin, result: Result(List(uri.Uri), page.FetchError))
  Crashed(origin: Origin)
  AfterWake
}

pub type Effect {
  Fetch(frontier.Scoop)
  Wake(at: Int)
  Done
}

pub fn new(settings: Settings, now: Int) -> #(Crawl, List(Effect)) {
  let crawl =
    Crawl(
      settings:,
      seen: set.new(),
      frontier: frontier.new(settings.delay_ms),
      requests: 0,
    )

  crawl
  |> push_links(settings.seeds, now)
  |> next(now)
}

pub fn update(crawl: Crawl, msg: Message, now: Int) -> #(Crawl, List(Effect)) {
  case msg {
    Fetched(origin:, result:) ->
      case frontier.in_flight_for(crawl.frontier, origin) {
        option.None -> #(crawl, [])
        option.Some(_) -> {
          let crawl = crawl |> settle(origin, now) |> increment_request()
          case result {
            Ok(candidates) ->
              crawl
              |> push_links(candidates, now)
              |> next(now)
            Error(_) -> next(crawl, now)
          }
        }
      }
    Crashed(origin:) ->
      case frontier.in_flight_for(crawl.frontier, origin) {
        option.Some(scoop) if scoop.attempts + 1 < crawl.settings.max_attempts -> {
          crawl
          |> requeue(origin, now)
        }
        option.Some(_) -> crawl |> penalize(origin, now)
        option.None -> crawl
      }
      |> next(now)

    AfterWake -> next(crawl, now)
  }
}

fn increment_request(crawl: Crawl) -> Crawl {
  Crawl(..crawl, requests: crawl.requests + 1)
}

fn push_links(crawl: Crawl, links: List(uri.Uri), now: Int) -> Crawl {
  list.fold(links, crawl, fn(crawl, url) {
    let url = normalize(url)
    case set.contains(crawl.seen, url), origin.from_uri(url) {
      False, Ok(site) ->
        Crawl(
          ..crawl,
          seen: set.insert(crawl.seen, url),
          frontier: frontier.push(
            crawl.frontier,
            frontier.new_scoop(site, url),
            now,
          ),
        )
      _, _ -> crawl
    }
  })
}

fn settle(crawl: Crawl, origin: Origin, now: Int) {
  Crawl(..crawl, frontier: crawl.frontier |> frontier.settle(origin, now))
}

fn requeue(crawl: Crawl, origin: Origin, now: Int) {
  Crawl(..crawl, frontier: frontier.requeue(crawl.frontier, origin, now))
}

fn penalize(crawl: Crawl, origin: Origin, now: Int) -> Crawl {
  Crawl(
    ..crawl,
    frontier: frontier.penalize(crawl.frontier, origin, now, option.None),
  )
}

fn next(crawl: Crawl, now: Int) -> #(Crawl, List(Effect)) {
  dispatch(crawl, now, [])
}

fn dispatch(
  crawl: Crawl,
  now: Int,
  effects: List(Effect),
) -> #(Crawl, List(Effect)) {
  use <- bool.guard(capacity_reached(crawl), finish(crawl, effects))
  let #(frontier, popped) = frontier.pop(crawl.frontier, now)
  {
    let crawl = Crawl(..crawl, frontier:)
    case popped {
      frontier.Took(scoop) -> dispatch(crawl, now, [Fetch(scoop), ..effects])
      frontier.Cooling(until:) -> #(
        crawl,
        list.reverse([Wake(at: until), ..effects]),
      )
      frontier.Empty -> finish(crawl, effects)
    }
  }
}

fn finish(crawl: Crawl, effects: List(Effect)) -> #(Crawl, List(Effect)) {
  case frontier.in_flight(crawl.frontier) == 0 {
    True -> #(crawl, list.reverse([Done, ..effects]))
    False -> #(crawl, list.reverse(effects))
  }
}

fn capacity_reached(crawl: Crawl) -> Bool {
  let in_flight = frontier.in_flight(crawl.frontier)
  in_flight >= crawl.settings.max_concurrency
  || crawl.requests + in_flight >= crawl.settings.max_pages
}

fn normalize(url: uri.Uri) -> uri.Uri {
  let path = case url.path {
    "" -> "/"
    path -> path
  }

  uri.Uri(..url, path:, fragment: option.None)
}
