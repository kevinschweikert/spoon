import gleam/bool
import gleam/list
import gleam/option
import gleam/set
import grip/origin.{type Origin}
import spoon/internal/frontier
import spoon/internal/requestable

pub type Settings {
  Settings(
    seeds: List(requestable.Requestable),
    delay_ms: Int,
    max_concurrency: Int,
    max_pages: option.Option(Int),
    max_depth: option.Option(Int),
    max_attempts: Int,
  )
}

pub type Crawl {
  Crawl(
    settings: Settings,
    // NOTE: maybe a bloom filter or ETS table will be necessary
    // Also before doing that, think about doing `requestable.to_uri |> uri.to_string`
    // to have a binary lookup instead of this nested data structure
    seen: set.Set(requestable.Requestable),
    frontier: frontier.Frontier,
    requests: Int,
  )
}

pub type Message {
  Fetched(
    scoop: frontier.Scoop,
    crawl_delay_ms: option.Option(Int),
    links: List(requestable.Requestable),
  )
  Failed(origin: Origin, retry_after: option.Option(Int))
  Skipped(origin: Origin)
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
      frontier: frontier.new(settings.max_depth),
      requests: 0,
    )

  crawl
  |> push_links(option.None, settings.seeds, now)
  |> next(now)
}

pub fn update(crawl: Crawl, msg: Message, now: Int) -> #(Crawl, List(Effect)) {
  case msg {
    Fetched(scoop:, crawl_delay_ms:, links:) ->
      case frontier.in_flight_for(crawl.frontier, scoop.requestable.origin) {
        option.None -> #(crawl, [])
        option.Some(_) -> {
          let crawl =
            crawl
            |> settle(scoop.requestable.origin, crawl_delay_ms, now)
            |> increment_request()
          crawl
          |> push_links(option.Some(scoop), links, now)
          |> next(now)
        }
      }
    Skipped(origin:) ->
      crawl |> settle(origin, option.Some(0), now) |> next(now)
    Failed(origin:, retry_after:) ->
      case frontier.in_flight_for(crawl.frontier, origin) {
        option.Some(scoop) if scoop.attempts + 1 < crawl.settings.max_attempts -> {
          crawl
          |> requeue(origin, retry_after, now)
        }
        option.Some(_) -> crawl |> penalize(origin, retry_after, now)
        option.None -> crawl
      }
      |> next(now)

    AfterWake -> next(crawl, now)
  }
}

fn increment_request(crawl: Crawl) -> Crawl {
  Crawl(..crawl, requests: crawl.requests + 1)
}

fn push_links(
  crawl: Crawl,
  parent: option.Option(frontier.Scoop),
  links: List(requestable.Requestable),
  now: Int,
) -> Crawl {
  list.fold(links, crawl, fn(crawl, requestable) {
    case set.contains(crawl.seen, requestable) {
      False ->
        Crawl(
          ..crawl,
          seen: set.insert(crawl.seen, requestable),
          frontier: frontier.push(
            crawl.frontier,
            frontier.new_scoop(parent, requestable),
            now,
          ),
        )
      _ -> crawl
    }
  })
}

fn settle(
  crawl: Crawl,
  origin: Origin,
  delay_ms: option.Option(Int),
  now: Int,
) -> Crawl {
  Crawl(
    ..crawl,
    frontier: crawl.frontier
      |> frontier.settle(
        origin,
        option.unwrap(delay_ms, crawl.settings.delay_ms),
        now,
      ),
  )
}

fn requeue(
  crawl: Crawl,
  origin: Origin,
  delay_ms: option.Option(Int),
  now: Int,
) -> Crawl {
  Crawl(
    ..crawl,
    frontier: frontier.requeue(
      crawl.frontier,
      origin,
      option.unwrap(delay_ms, crawl.settings.delay_ms),
      now,
    ),
  )
}

fn penalize(
  crawl: Crawl,
  origin: Origin,
  delay_ms: option.Option(Int),
  now: Int,
) -> Crawl {
  Crawl(
    ..crawl,
    frontier: frontier.penalize(
      crawl.frontier,
      origin,
      crawl.settings.delay_ms,
      now,
      delay_ms,
    ),
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
  || max_pages_reached(crawl, in_flight)
}

fn max_pages_reached(crawl: Crawl, in_flight: Int) -> Bool {
  case crawl.settings.max_pages {
    option.None -> False
    option.Some(max_pages) -> crawl.requests + in_flight >= max_pages
  }
}
