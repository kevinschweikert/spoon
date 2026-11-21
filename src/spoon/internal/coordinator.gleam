import gleam/erlang/process
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/otp/supervision
import gleam/string
import grip/origin
import spoon/internal/config
import spoon/internal/crawl
import spoon/internal/fetcher
import spoon/internal/frontier
import spoon/internal/policy_cache
import spoon/internal/requestable
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
  FetcherDone(
    scoop: frontier.Scoop,
    crawl_delay_ms: option.Option(Int),
    attempt: fetcher.Attempt(item),
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
        max_depth: config.max_depth,
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

    FetcherDone(scoop:, crawl_delay_ms:, attempt:) -> {
      case attempt {
        fetcher.Responded(links:, item:, ..) -> {
          let accumulator = case item {
            option.Some(item) ->
              coordinator.combine(coordinator.accumulator, item)
            option.None -> coordinator.accumulator
          }
          Coordinator(..coordinator, accumulator:)
          |> advance(scoop, links, crawl_delay_ms, now)
        }
        fetcher.Skipped(_) -> {
          let #(crawl, effects) =
            crawl.update(
              coordinator.crawl,
              crawl.Skipped(scoop.requestable.origin),
              now,
            )
          Coordinator(..coordinator, crawl:)
          |> execute(effects, now)
        }
        fetcher.Errored(http_err) -> {
          let delay_ms = case http_err {
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

fn advance(
  coordinator: Coordinator(item, acc),
  scoop: frontier.Scoop,
  links: List(requestable.Requestable),
  crawl_delay_ms: option.Option(Int),
  now: Int,
) -> actor.Next(Coordinator(item, acc), Message(item)) {
  let links = filter_by_scope(links, coordinator.config.scope)

  let #(crawl, effects) =
    crawl.update(
      coordinator.crawl,
      crawl.Fetched(
        scoop: scoop,
        crawl_delay_ms: option.or(
          crawl_delay_ms,
          option.Some(coordinator.config.delay_ms),
        ),
        links:,
      ),
      now,
    )
  Coordinator(..coordinator, crawl:)
  |> execute(effects, now)
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
      let Coordinator(self:, config:, policy_cache:, ..) = coordinator
      let job =
        worker.Job(
          run: fn() {
            let #(crawl_delay_ms, attempt) =
              fetcher.run(scoop, config, policy_cache)
            process.send(self, FetcherDone(scoop:, crawl_delay_ms:, attempt:))
          },
          on_error: fn(_reason) {
            process.send(self, FetcherDown(origin: scoop.requestable.origin))
          },
        )

      worker.start_job(coordinator.workers, job)
      execute(coordinator, rest, now)
    }
  }
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
