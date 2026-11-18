import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import gleam/string
import gleam/uri
import grip/origin
import spoon/internal/config
import spoon/internal/crawl
import spoon/internal/frontier
import spoon/internal/policy_cache

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
    report: Result(page.Report(item), page.FetchError),
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
        crawl.update(coordinator.crawl, crawl.Crashed(origin), now)
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
              let outcome =
                outcome
                |> resolve_candidates(scoop)
                |> keep_requestable
                |> filter_by_prefetch(coordinator.config.prefetch)
                |> filter_by_scope(coordinator.config.scope)

              let #(crawl, effects) =
                crawl.update(
                  coordinator.crawl,
                  crawl.Fetched(
                    origin: scoop.origin,
                    crawl_delay_ms: option.or(
                      crawl_delay_ms,
                      option.Some(coordinator.config.delay_ms),
                    ),
                    links: outcome.candidates,
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
                  crawl.Skipped(scoop.origin),
                  now,
                )
              Coordinator(..coordinator, crawl:)
              |> execute(effects, now)
            }
          }
        Error(_) -> {
          let #(crawl, effects) =
            crawl.update(coordinator.crawl, crawl.Failed(scoop.origin), now)
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
      let config.Config(fetch:, next:, on_page:, user_agent:, ..) = config
      let fetcher = fn() {
        let policy_answer =
          process.call(process.named_subject(policy_cache), 10_000, fn(reply) {
            policy_cache.Check(scoop:, reply:)
          })
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
          Error(_) -> {
            Error(page.PolicyUnavailable)
            |> Reported(scoop:, report: _)
            |> process.send(coordinator_subject, _)
          }
        }
      }
      let job =
        worker.Job(run: fetcher, on_error: fn(_reason) {
          process.send(coordinator_subject, FetcherDown(origin: scoop.origin))
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
    Result(response.Response(String), page.FetchError),
  next: fn(response.Response(String)) -> List(uri.Uri),
  on_page: fn(page.Page) -> page.Outcome(item),
) -> Result(page.Outcome(item), page.FetchError) {
  use request <- result.try(build_request(scoop.url, user_agent))
  use response <- result.try(fetch(request))
  page.Page(
    url: scoop.url,
    status: response.status,
    body: response.body,
    candidates: next(response),
  )
  |> on_page()
  |> Ok
}

fn build_request(
  url: uri.Uri,
  user_agent: String,
) -> Result(request.Request(String), page.FetchError) {
  use request <- result.try(
    request.from_uri(url)
    |> result.replace_error(page.InvalidUrl(url)),
  )
  Ok(request.set_header(request, "user-agent", user_agent))
}

fn resolve_candidates(
  outcome: page.Outcome(item),
  scoop: frontier.Scoop,
) -> page.Outcome(item) {
  let candidates =
    outcome.candidates
    |> list.filter_map(resolve_url(scoop.url, _))
  page.Outcome(..outcome, candidates:)
}

fn resolve_url(from: uri.Uri, link: uri.Uri) -> Result(uri.Uri, Nil) {
  use resolved <- result.map(uri.merge(from, link))
  case string.ends_with(link.path, "/"), string.ends_with(resolved.path, "/") {
    True, False -> uri.Uri(..resolved, path: resolved.path <> "/")
    _, _ -> resolved
  }
}

fn filter_by_prefetch(
  outcome: page.Outcome(item),
  prefetch: fn(uri.Uri) -> Result(uri.Uri, page.FetchError),
) -> page.Outcome(item) {
  let candidates =
    outcome.candidates
    |> list.filter_map(prefetch)
  page.Outcome(..outcome, candidates:)
}

fn filter_by_scope(
  outcome: page.Outcome(item),
  scope: config.Scope,
) -> page.Outcome(item) {
  let candidates =
    outcome.candidates
    |> list.filter(fn(link) {
      case scope {
        config.AllowAll -> True
        config.AllowedHosts(hosts) -> {
          host_match(link.host, hosts)
        }
      }
    })
  page.Outcome(..outcome, candidates:)
}

fn host_match(host: option.Option(String), hosts: List(String)) -> Bool {
  case host {
    option.None -> False
    option.Some(host) -> {
      // host strings are lowercased in the builder public API
      hosts
      |> list.contains(string.lowercase(host))
    }
  }
}

fn keep_requestable(outcome: page.Outcome(item)) -> page.Outcome(item) {
  let candidates =
    outcome.candidates
    |> list.filter(fn(link) {
      case link.scheme, link.host {
        option.Some("http"), option.Some(_)
        | option.Some("https"), option.Some(_)
        -> True
        _, _ -> False
      }
    })
  page.Outcome(..outcome, candidates:)
}
