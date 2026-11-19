import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import gleam/string
import gleam/time/duration
import gleam/time/timestamp
import gleam/uri
import grip/origin
import spoon/internal/config
import spoon/internal/crawl
import spoon/internal/frontier
import spoon/internal/policy_cache
import spoon/internal/requestable

// import spoon/internal/policy_cache
import spoon/internal/worker
import spoon/page

pub type Coordinator(item, acc) {
  Coordinator(
    self: process.Subject(Message(item)),
    name: process.Name(Message(item)),
    workers: process.Name(worker.Message),
    policy_cache: process.Name(policy_cache.Message),
    reply: process.Subject(acc),
    crawl: crawl.Crawl,
    config: config.Config(item),
    accumulator: acc,
    combine: fn(acc, item) -> acc,
  )
}

pub type Message(item) {
  Start(List(crawl.Effect))
  Reported(
    scoop: frontier.Scoop,
    report: Result(page.Report(item), page.HttpError),
  )
  FetcherDown(origin: origin.Origin)
  Wake
}

pub fn supervised(
  name: process.Name(Message(item)),
  config: config.Config(item),
  initial: acc,
  combine: fn(acc, item) -> acc,
  reply: process.Subject(acc),
  workers: process.Name(worker.Message),
  policy_cache: process.Name(policy_cache.Message),
) -> supervision.ChildSpecification(process.Subject(Message(item))) {
  supervision.worker(fn() {
    start(name, config, initial, combine, reply, workers, policy_cache)
  })
  |> supervision.restart(supervision.Transient)
}

pub fn start(
  name: process.Name(Message(item)),
  config: config.Config(item),
  initial: acc,
  combine: fn(acc, item) -> acc,
  reply: process.Subject(acc),
  workers: process.Name(worker.Message),
  policy_cache: process.Name(policy_cache.Message),
) -> Result(actor.Started(process.Subject(Message(item))), actor.StartError) {
  actor.new_with_initialiser(100, fn(self: process.Subject(Message(item))) {
    let now = config.clock()

    let crawl_settings =
      crawl.Settings(
        seeds: [config.base_url, ..config.seeds],
        delay_ms: config.delay_ms,
        max_concurrency: config.max_concurrency,
        max_pages: config.max_pages,
        max_attempts: config.max_attempts,
      )
    let #(crawl, effects) = crawl.new(crawl_settings, now)

    process.send(self, Start(effects))
    Coordinator(
      name:,
      self:,
      workers:,
      policy_cache:,
      reply:,
      crawl:,
      config:,
      accumulator: initial,
      combine:,
    )
    |> actor.initialised()
    |> actor.returning(self)
    |> Ok
  })
  |> actor.on_message(handle_message)
  |> actor.named(name)
  |> actor.start()
}

fn handle_message(
  coordinator: Coordinator(item, acc),
  message: Message(item),
) -> actor.Next(Coordinator(item, acc), Message(item)) {
  let now = coordinator.config.clock()
  case message {
    Start(effects) -> execute(coordinator, effects, now)

    FetcherDown(origin) -> {
      let #(crawl, effects) =
        crawl.update(coordinator.crawl, crawl.Failed(origin, option.None), now)
      Coordinator(..coordinator, crawl:)
      |> execute(effects, now)
    }

    Reported(scoop:, report:) -> {
      case report {
        Ok(report) ->
          case report {
            page.Fetched(outcome:, crawl_delay_ms:) -> {
              let accumulator =
                coordinator.combine(coordinator.accumulator, outcome.item)
              let links =
                outcome.candidates
                |> list.filter_map(requestable.resolve(scoop.requestable, _))
                |> filter_by_scope(coordinator.config.scope)

              let #(crawl, effects) =
                crawl.update(
                  coordinator.crawl,
                  crawl.Fetched(
                    origin: scoop.requestable.origin,
                    crawl_delay_ms: option.or(
                      crawl_delay_ms,
                      option.Some(coordinator.config.delay_ms),
                    ),
                    links:,
                  ),
                  now,
                )
              Coordinator(..coordinator, crawl:, accumulator:)
              |> execute(effects, now)
            }
            page.Skipped -> {
              let #(crawl, effects) =
                crawl.update(
                  coordinator.crawl,
                  crawl.Skipped(scoop.requestable.origin),
                  now,
                )
              Coordinator(..coordinator, crawl:)
              |> execute(effects, now)
            }
          }
        Error(fetch_err) -> {
          let delay_ms = case fetch_err {
            page.Throttled(retry_after) -> retry_after
            _ -> option.None
          }

          let #(crawl, effects) =
            crawl.update(
              coordinator.crawl,
              crawl.Failed(scoop.requestable.origin, delay_ms),
              now,
            )
          Coordinator(..coordinator, crawl:)
          |> execute(effects, now)
        }
      }
    }
    Wake -> {
      let #(crawl, effects) =
        crawl.update(coordinator.crawl, crawl.AfterWake, now)
      Coordinator(..coordinator, crawl:)
      |> execute(effects, now)
    }
  }
}

fn execute(
  coordinator: Coordinator(item, acc),
  effects: List(crawl.Effect),
  now: Int,
) -> actor.Next(Coordinator(item, acc), a) {
  case effects {
    [] -> actor.continue(coordinator)
    [crawl.Done, ..] -> {
      process.send(coordinator.reply, coordinator.accumulator)
      actor.stop()
    }
    [crawl.Wake(at:), ..rest] -> {
      process.send_after(coordinator.self, at - now, Wake)
      execute(coordinator, rest, now)
    }
    [crawl.Fetch(scoop), ..rest] -> {
      let Coordinator(self: coordinator_subject, config:, policy_cache:, ..) =
        coordinator
      let config.Config(
        fetch:,
        next:,
        on_page:,
        user_agent:,
        respect_robots:,
        ..,
      ) = config
      let fetcher = fn() {
        let policy_answer = case respect_robots {
          True ->
            process.call(process.named_subject(policy_cache), 10_000, fn(reply) {
              policy_cache.Check(scoop:, reply:)
            })
          False -> Ok(policy_cache.PolicyAnswer(True, option.None))
        }
        case policy_answer {
          Ok(policy_cache.PolicyAnswer(allowed:, delay_ms:)) -> {
            case allowed {
              False -> {
                Ok(page.Skipped)
                |> Reported(scoop:, report: _)
                |> process.send(coordinator_subject, _)
              }
              True -> {
                do_fetch(scoop, user_agent, fetch, next, on_page)
                |> result.map(page.Fetched(_, delay_ms))
                |> Reported(scoop:, report: _)
                |> process.send(coordinator_subject, _)
              }
            }
          }
          Error(err) -> {
            Error(err)
            |> Reported(scoop:, report: _)
            |> process.send(coordinator_subject, _)
          }
        }
      }
      let job =
        worker.Job(run: fetcher, on_error: fn(_reason) {
          process.send(
            coordinator_subject,
            FetcherDown(origin: scoop.requestable.origin),
          )
        })

      worker.start_job(coordinator.workers, job)
      execute(coordinator, rest, now)
    }
  }
}

fn do_fetch(
  scoop: frontier.Scoop,
  user_agent: String,
  fetch: fn(request.Request(String)) ->
    Result(response.Response(String), page.HttpError),
  next: fn(response.Response(String)) -> List(uri.Uri),
  on_page: fn(page.Page) -> page.Outcome(item),
) -> Result(page.Outcome(item), page.HttpError) {
  let request = requestable.to_request(scoop.requestable, user_agent)
  use response <- result.try(fetch(request))
  case response.status {
    429 | 503 -> {
      response.get_header(response, "retry-after")
      |> result.try(parse_retry_after)
      |> option.from_result()
      |> page.Throttled
      |> Error
    }
    _ ->
      page.Page(
        url: requestable.to_uri(scoop.requestable),
        status: response.status,
        body: response.body,
        candidates: next(response),
      )
      |> on_page()
      |> Ok
  }
}

fn parse_retry_after(value: String) -> Result(Int, Nil) {
  let value = string.trim(value)
  parse_delay(value)
  |> result.lazy_or(fn() { parse_http_date(value) })
}

fn parse_delay(value: String) -> Result(Int, Nil) {
  case int.parse(value) {
    Ok(delay) if delay >= 0 -> Ok(delay)
    _ -> Error(Nil)
  }
}

fn parse_http_date(value: String) -> Result(Int, Nil) {
  use at <- result.map(timestamp.parse_http_date(value))
  timestamp.system_time()
  |> timestamp.difference(at)
  |> duration.to_milliseconds()
  |> int.max(0)
}

fn filter_by_scope(
  links: List(requestable.Requestable),
  scope: config.Scope,
) -> List(requestable.Requestable) {
  list.filter(links, fn(link) {
    case scope {
      config.AllowAll -> True
      config.AllowedHosts(hosts) -> {
        requestable.to_uri(link).host
        |> option.map(fn(host) {
          hosts
          |> list.contains(string.lowercase(host))
        })
        |> option.unwrap(False)
      }
    }
  })
}
