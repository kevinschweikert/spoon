import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/otp/actor
import gleam/otp/factory_supervisor
import gleam/result
import gleam/uri
import spoon/internal/frontier
import spoon/internal/policy_cache
import spoon/page

pub type Factory(item) =
  factory_supervisor.Message(Visit(item), process.Subject(Message))

type State(item) {
  State(visit: Visit(item), self: process.Subject(Message))
}

pub type Visit(item) {
  Visit(
    policy_cache: process.Name(policy_cache.Message),
    scoop: frontier.Scoop,
    build_request: fn(uri.Uri) ->
      Result(request.Request(String), page.FetchError),
    fetch: fn(request.Request(String)) ->
      Result(response.Response(String), page.FetchError),
    next: fn(response.Response(String)) -> List(uri.Uri),
    on_page: fn(page.Page) -> page.Outcome(item),
    report: fn(Result(page.Report(item), page.FetchError)) -> Nil,
  )
}

pub opaque type Message {
  Fetch
  PolicyResponse(Result(policy_cache.PolicyAnswer, Nil))
}

pub fn start(
  visit: Visit(item),
) -> Result(actor.Started(process.Subject(Message)), actor.StartError) {
  actor.new_with_initialiser(100, fn(self) {
    process.send(self, Fetch)

    actor.initialised(State(visit:, self:))
    |> actor.returning(self)
    |> Ok
  })
  |> actor.on_message(handle_message)
  |> actor.start
}

fn handle_message(
  state: State(item),
  message: Message,
) -> actor.Next(State(item), Message) {
  case message {
    Fetch -> {
      let subject = process.named_subject(state.visit.policy_cache)
      let self = state.self
      process.send(
        subject,
        policy_cache.Check(scoop: state.visit.scoop, reply: fn(answer) {
          process.send(self, PolicyResponse(answer))
        }),
      )
      actor.continue(state)
    }

    PolicyResponse(answer) -> {
      case answer {
        Ok(policy_cache.PolicyAnswer(allowed:, delay_ms:)) -> {
          case allowed {
            False -> {
              state.visit.report(Ok(page.Skipped))
              actor.stop()
            }
            True -> {
              fetch(state.visit)
              |> result.map(page.Fetched(_, delay_ms))
              |> state.visit.report()
              actor.stop()
            }
          }
        }
        Error(_) -> {
          state.visit.report(Error(page.PolicyUnavailable))
          actor.stop()
        }
      }
    }
  }
}

fn fetch(visit: Visit(item)) -> Result(page.Outcome(item), page.FetchError) {
  use request <- result.try(visit.build_request(visit.scoop.url))
  use response <- result.try(visit.fetch(request))
  page.Page(
    url: visit.scoop.url,
    status: response.status,
    body: response.body,
    candidates: visit.next(response),
  )
  |> visit.on_page()
  |> Ok
}
