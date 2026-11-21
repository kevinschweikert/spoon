import gleam/dict
import gleam/erlang/process
import gleam/float
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option
import gleam/order
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import gleam/time/duration
import gleam/time/timestamp
import gleam/uri
import grip
import grip/origin
import logging
import spoon/internal/config
import spoon/internal/frontier
import spoon/internal/requestable
import spoon/internal/worker
import spoon/visit

type Waiting {
  Waiting(
    scoop: frontier.Scoop,
    reply: process.Subject(Result(PolicyAnswer, visit.Failure)),
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
    reply: process.Subject(Result(PolicyAnswer, visit.Failure)),
  )
  Policy(origin: origin.Origin, policy: Result(grip.Policy, visit.Failure))
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
          policy
          |> apply_scoop(scoop, cache.config.user_agent)
          |> Ok
          |> process.send(reply, _)
          actor.continue(cache)
        }
        Pending -> cache |> add_pending(waiting) |> actor.continue
        Stale -> {
          // TODO: remove logging dependency before release
          logging.log(
            logging.Debug,
            "[POLICY] Fetching "
              <> origin.robots_url(scoop.requestable.origin) |> uri.to_string(),
          )
          spawn_fetch(
            cache.name,
            cache.workers,
            cache.config.fetch,
            scoop.requestable.origin,
            cache.config.user_agent,
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
      |> list.each(fn(waiting) {
        policy
        |> result.map(apply_scoop(_, waiting.scoop, user_agent))
        |> process.send(waiting.reply, _)
      })

      let policies = case policy {
        Ok(policy) -> {
          dict.insert(
            cache.policies,
            origin,
            Entry(policy:, fetched_at: timestamp.system_time()),
          )
        }
        Error(_) -> cache.policies
      }
      Cache(..cache, policies:, pending: dict.delete(cache.pending, origin))
      |> actor.continue
    }
  }
}

fn lookup(cache: Cache(item), scoop: frontier.Scoop) -> Lookup {
  let pending = dict.has_key(cache.pending, scoop.requestable.origin)
  case dict.get(cache.policies, scoop.requestable.origin) {
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
  name: process.Name(Message),
  worker_name: process.Name(worker.Message),
  fetch: fn(request.Request(String)) ->
    Result(response.Response(String), visit.Failure),
  origin: origin.Origin,
  user_agent: String,
) -> Nil {
  let subject = process.named_subject(name)

  worker.start_job(
    worker_name,
    worker.Job(
      run: fn() {
        fetch_robots(fetch, origin, user_agent)
        |> Policy(origin:, policy: _)
        |> process.send(subject, _)
      },
      on_error: fn(_reason) {
        Error(visit.BadResponse)
        |> Policy(origin:, policy: _)
        |> process.send(subject, _)
      },
    ),
  )
}

fn add_pending(cache: Cache(item), waiting: Waiting) -> Cache(item) {
  let origin = waiting.scoop.requestable.origin
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
    Result(response.Response(String), visit.Failure),
  origin: origin.Origin,
  user_agent: String,
) -> Result(grip.Policy, visit.Failure) {
  let request =
    origin.robots_request(origin)
    |> request.set_header("user-agent", user_agent)
  use response <- result.try(
    fetch(request) |> result.replace_error(visit.BadResponse),
  )
  grip.from_response(response)
  |> result.map_error(from_grip)
}

fn from_grip(grip_err: grip.Error) -> visit.Failure {
  case grip_err {
    grip.RateLimited(retry_after:) -> {
      retry_after
      |> option.map(fn(kind) {
        case kind {
          grip.Delay(seconds:) -> seconds * 1000
          grip.At(timestamp:) ->
            timestamp.system_time()
            |> timestamp.difference(timestamp)
            |> duration.to_milliseconds()
            |> int.max(0)
        }
      })
      |> visit.Throttled
    }
    grip.UnexpectedHttpStatusCode(_) -> visit.BadResponse
  }
}

fn apply_scoop(
  policy: grip.Policy,
  scoop: frontier.Scoop,
  user_agent: String,
) -> PolicyAnswer {
  let url = requestable.to_uri(scoop.requestable)
  let allowed = grip.is_allowed(policy, user_agent, url)
  let delay_ms =
    grip.rate(policy, user_agent)
    |> result.map(fn(rate) { float.round(grip.interval(rate) *. 1000.0) })
    |> option.from_result

  PolicyAnswer(allowed, delay_ms)
}
