import gleam/bool
import gleam/list
import gleam/option
import gleam/set
import gleam/string
import grip/origin.{type Origin}
import spoon/internal/frontier
import spoon/internal/requestable
import spoon/visit

pub type Settings {
  Settings(
    seeds: List(requestable.Requestable),
    delay_ms: Int,
    max_concurrency: Int,
    max_pages: option.Option(Int),
    max_depth: option.Option(Int),
    max_attempts: Int,
    scope: Scope,
  )
}

pub type Scope {
  AllowAll
  AllowedHosts(List(String))
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

pub type Attempt(item) {
  Responded(
    status: Int,
    item: option.Option(item),
    links: List(requestable.Requestable),
  )
  Skipped(visit.Skip)
  Failed(visit.Failure)
}

pub type Event(item) {
  Attempted(
    scoop: frontier.Scoop,
    // this is the request rate from robots.txt
    // only because theres only one message for policy response
    // and fetched in the core.
    // if core owns robots they can be split
    crawl_delay_ms: option.Option(Int),
    attempt: Attempt(item),
  )
  Woke
}

pub type Effect(item) {
  Fetch(frontier.Scoop)
  Wake(at: Int)
  Emit(visit.Visit(item))
  Done
}

pub fn new(settings: Settings, now: Int) -> #(Crawl, List(Effect(item))) {
  let crawl =
    Crawl(
      settings:,
      seen: set.new(),
      frontier: frontier.new(settings.max_depth),
      requests: 0,
    )

  crawl
  |> push_links(option.None, settings.seeds, now)
  |> dispatch(now, [])
}

pub fn update(
  crawl: Crawl,
  event: Event(item),
  now: Int,
) -> #(Crawl, List(Effect(item))) {
  case event {
    Woke -> dispatch(crawl, now, [])
    Attempted(attempt:, scoop:, crawl_delay_ms:) -> {
      case frontier.in_flight_for(crawl.frontier, scoop.requestable.origin) {
        option.Some(in_flight) if in_flight == scoop ->
          case attempt {
            Responded(links:, status:, item:) -> {
              crawl
              |> settle(scoop.requestable.origin, crawl_delay_ms, now)
              |> increment_request()
              |> push_links(
                option.Some(scoop),
                list.filter(links, in_scope(crawl.settings.scope, _)),
                now,
              )
              |> dispatch(now, [
                Emit(visit.Visit(
                  parent: option.map(scoop.parent, requestable.to_uri),
                  url: requestable.to_uri(scoop.requestable),
                  depth: scoop.depth,
                  outcome: visit.Responded(
                    status:,
                    item:,
                    links: list.map(links, requestable.to_uri),
                  ),
                )),
              ])
            }

            Skipped(skip) ->
              crawl
              |> settle(scoop.requestable.origin, option.Some(0), now)
              |> dispatch(now, [
                Emit(visit.Visit(
                  parent: option.map(scoop.parent, requestable.to_uri),
                  url: requestable.to_uri(scoop.requestable),
                  depth: scoop.depth,
                  outcome: visit.Skipped(skip),
                )),
              ])
            Failed(failure) -> {
              let retry_after = case failure {
                visit.Throttled(retry_after_ms:) -> retry_after_ms
                _ -> option.None
              }
              case scoop.attempts + 1 < crawl.settings.max_attempts {
                True ->
                  crawl
                  |> requeue(scoop.requestable.origin, retry_after, now)
                  |> dispatch(now, [])
                False ->
                  crawl
                  |> penalize(scoop.requestable.origin, retry_after, now)
                  |> dispatch(now, [
                    Emit(visit.Visit(
                      parent: option.map(scoop.parent, requestable.to_uri),
                      url: requestable.to_uri(scoop.requestable),
                      depth: scoop.depth,
                      outcome: visit.Failed(failure),
                    )),
                  ])
              }
            }
          }
        option.None | option.Some(_) -> #(crawl, [])
      }
    }
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

fn in_scope(scope: Scope, link: requestable.Requestable) -> Bool {
  case scope {
    AllowAll -> True
    AllowedHosts(hosts) -> {
      requestable.to_uri(link).host
      |> option.map(fn(host) {
        hosts
        |> list.contains(string.lowercase(host))
      })
      |> option.unwrap(False)
    }
  }
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

// fn next(crawl: Crawl, now: Int) -> #(Crawl, List(Effect(item))) {
//   dispatch(crawl, now, [])
// }

fn dispatch(
  crawl: Crawl,
  now: Int,
  effects: List(Effect(item)),
) -> #(Crawl, List(Effect(item))) {
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

fn finish(
  crawl: Crawl,
  effects: List(Effect(item)),
) -> #(Crawl, List(Effect(item))) {
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
