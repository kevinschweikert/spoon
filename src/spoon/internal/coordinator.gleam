import gleam/erlang/process
import gleam/option
import gleam/otp/actor
import gleam/otp/supervision
import spoon/internal/config
import spoon/internal/crawl
import spoon/internal/fetcher
import spoon/internal/policy_cache
import spoon/internal/worker
import spoon/visit

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
    combine: fn(acc, visit.Visit(item)) -> acc,
  )
}

pub type Message(item) {
  Start(List(crawl.Effect(item)))
  Crawl(crawl.Event(item))
  Wake
}

pub fn supervised(
  name: process.Name(Message(item)),
  config: config.Config(item),
  initial: acc,
  combine: fn(acc, visit.Visit(item)) -> acc,
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
  combine: fn(acc, visit.Visit(item)) -> acc,
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
        scope: config.scope,
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
    Crawl(event) -> {
      let #(crawl, effects) = crawl.update(coordinator.crawl, event, now)
      Coordinator(..coordinator, crawl:)
      |> execute(effects, now)
    }

    Wake -> {
      let #(crawl, effects) = crawl.update(coordinator.crawl, crawl.Woke, now)
      Coordinator(..coordinator, crawl:)
      |> execute(effects, now)
    }
  }
}

fn execute(
  coordinator: Coordinator(item, acc),
  effects: List(crawl.Effect(item)),
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
    [crawl.Emit(visit), ..rest] -> {
      let accumulator = coordinator.combine(coordinator.accumulator, visit)
      Coordinator(..coordinator, accumulator:)
      |> execute(rest, now)
    }

    [crawl.Fetch(scoop), ..rest] -> {
      let Coordinator(self:, config:, policy_cache:, ..) = coordinator
      let job =
        worker.Job(
          run: fn() {
            let attempted = fetcher.run(scoop, config, policy_cache)
            process.send(self, Crawl(attempted))
          },
          on_error: fn(_reason) {
            process.send(
              self,
              Crawl(crawl.Attempted(
                scoop:,
                attempt: crawl.Failed(visit.Crashed),
                crawl_delay_ms: option.None,
              )),
            )
          },
        )

      worker.start_job(coordinator.workers, job)
      execute(coordinator, rest, now)
    }
  }
}
