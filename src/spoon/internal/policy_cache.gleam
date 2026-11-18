import gleam/dict
import gleam/erlang/process
import gleam/float
import gleam/http/request
import gleam/http/response
import gleam/list
import gleam/option
import gleam/order
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import gleam/time/duration
import gleam/time/timestamp
import grip
import grip/origin
import spoon/internal/config
import spoon/internal/frontier
import spoon/internal/worker
import spoon/page

type Waiting {
  Waiting(
    scoop: frontier.Scoop,
    reply: process.Subject(Result(PolicyAnswer, Nil)),
  )
}

type Cache(item) {
  Cache(
    name: process.Name(Message),
    config: config.Config(item),
    policies: dict.Dict(origin.Origin, Entry),
    pending: dict.Dict(origin.Origin, List(Waiting)),
    workers: process.Name(worker.Message),
  )
}

type Entry {
  Entry(policy: grip.Policy, fetched_at: timestamp.Timestamp)
}

type Lookup {
  Fresh(policy: grip.Policy)
  Pending
  Stale
}

pub type Message {
  Check(
    scoop: frontier.Scoop,
    reply: process.Subject(Result(PolicyAnswer, Nil)),
  )
  Policy(origin: origin.Origin, policy: Result(grip.Policy, Nil))
}

pub type PolicyAnswer {
  PolicyAnswer(allowed: Bool, delay_ms: option.Option(Int))
}

pub fn supervised(
  name: process.Name(Message),
  config: config.Config(item),
  workers: process.Name(worker.Message),
) -> supervision.ChildSpecification(process.Subject(Message)) {
  supervision.worker(fn() { start(name, config, workers) })
  |> supervision.restart(supervision.Permanent)
}

pub fn start(
  name: process.Name(Message),
  config: config.Config(item),
  workers: process.Name(worker.Message),
) -> Result(actor.Started(process.Subject(Message)), actor.StartError) {
  actor.new(Cache(
    name:,
    config:,
    policies: dict.new(),
    pending: dict.new(),
    workers:,
  ))
  |> actor.on_message(handle_message)
  |> actor.named(name)
  |> actor.start
}

fn handle_message(
  cache: Cache(item),
  message: Message,
) -> actor.Next(Cache(item), Message) {
  case message {
    Check(scoop:, reply:) -> {
      let waiting = Waiting(scoop:, reply:)
      case lookup(cache, scoop) {
        Fresh(policy) -> {
          answer(waiting, Ok(policy), cache.config.user_agent)
          actor.continue(cache)
        }
        Pending -> cache |> add_pending(waiting) |> actor.continue
        Stale -> {
          spawn_fetch(
            cache.name,
            cache.workers,
            cache.config.fetch,
            scoop.origin,
          )
          cache |> add_pending(waiting) |> actor.continue
        }
      }
    }
    Policy(origin:, policy:) -> {
      let user_agent = cache.config.user_agent
      cache.pending
      |> dict.get(origin)
      |> result.unwrap([])
      |> list.each(answer(_, policy, user_agent))

      let policies = case policy {
        Ok(policy) ->
          dict.insert(
            cache.policies,
            origin,
            Entry(policy:, fetched_at: timestamp.system_time()),
          )
        Error(_) -> cache.policies
      }
      Cache(..cache, policies:, pending: dict.delete(cache.pending, origin))
      |> actor.continue
    }
  }
}

fn answer(
  waiting: Waiting,
  policy: Result(grip.Policy, Nil),
  user_agent: String,
) -> Nil {
  case policy {
    Ok(policy) -> resolve(policy, user_agent, waiting.scoop, waiting.reply)
    Error(_) -> process.send(waiting.reply, Error(Nil))
  }
}

fn lookup(cache: Cache(item), scoop: frontier.Scoop) -> Lookup {
  let pending = dict.has_key(cache.pending, scoop.origin)
  case dict.get(cache.policies, scoop.origin) {
    Ok(Entry(policy:, fetched_at:)) ->
      case is_fresh(fetched_at), pending {
        True, _ -> Fresh(policy)
        False, True -> Pending
        False, False -> Stale
      }
    Error(_) ->
      case pending {
        True -> Pending
        False -> Stale
      }
  }
}

fn spawn_fetch(
  name: _,
  worker_name: _,
  fetch: fn(request.Request(String)) ->
    Result(response.Response(String), page.FetchError),
  origin: origin.Origin,
) -> Nil {
  let subject = process.named_subject(name)

  worker.start_job(
    worker_name,
    worker.Job(
      run: fn() {
        fetch_robots(fetch, origin)
        |> Policy(origin:, policy: _)
        |> process.send(subject, _)
      },
      on_error: fn(_reason) {
        Policy(origin:, policy: Error(Nil))
        |> process.send(subject, _)
      },
    ),
  )
}

fn add_pending(cache: Cache(item), waiting: Waiting) -> Cache(item) {
  let origin = waiting.scoop.origin
  let waitings = dict.get(cache.pending, origin) |> result.unwrap([])
  Cache(
    ..cache,
    pending: dict.insert(cache.pending, origin, [waiting, ..waitings]),
  )
}

fn is_fresh(fetched_at: timestamp.Timestamp) -> Bool {
  let valid_until = timestamp.add(fetched_at, duration.hours(24))
  order.Gt == timestamp.compare(valid_until, timestamp.system_time())
}

fn fetch_robots(
  fetch: fn(request.Request(String)) ->
    Result(response.Response(String), page.FetchError),
  origin: origin.Origin,
) -> Result(grip.Policy, Nil) {
  use request <- result.try(origin.robots_url(origin) |> request.from_uri)
  use response <- result.try(fetch(request) |> result.replace_error(Nil))
  grip.from_response(response) |> result.replace_error(Nil)
}

fn resolve(
  policy: grip.Policy,
  user_agent: String,
  scoop: frontier.Scoop,
  reply: process.Subject(Result(PolicyAnswer, Nil)),
) -> Nil {
  let allowed = grip.is_allowed(policy, user_agent, scoop.url)
  let delay_ms =
    grip.rate(policy, user_agent)
    |> result.map(fn(rate) { float.round(grip.interval(rate) *. 1000.0) })
    |> option.from_result

  process.send(reply, Ok(PolicyAnswer(allowed, delay_ms)))
}
