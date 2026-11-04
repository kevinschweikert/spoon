import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/otp/actor
import gleam/otp/factory_supervisor
import gleam/uri
import spoon/page

pub type Factory =
  factory_supervisor.Message(Visit, process.Subject(Message))

pub type Visit {
  Visit(
    request: request.Request(String),
    fetch: fn(request.Request(String)) ->
      Result(response.Response(String), page.FetchError),
    next: fn(response.Response(String)) -> List(uri.Uri),
    report: fn(Result(page.Page, page.FetchError)) -> Nil,
  )
}

pub opaque type Message {
  Fetch
}

pub fn start(
  visit: Visit,
) -> Result(actor.Started(process.Subject(Message)), actor.StartError) {
  actor.new_with_initialiser(100, fn(self) {
    process.send(self, Fetch)

    actor.initialised(visit)
    |> actor.returning(self)
    |> Ok
  })
  |> actor.on_message(handle_message)
  |> actor.start
}

fn handle_message(
  visit: Visit,
  message: Message,
) -> actor.Next(Visit, Message) {
  case message {
    Fetch -> {
      case visit.fetch(visit.request) {
        Ok(resp) -> {
          page.Page(
            url: visit.request |> request.to_uri(),
            status: resp.status,
            body: resp.body,
            candidates: visit.next(resp),
          )
          |> Ok()
          |> visit.report()
          actor.stop()
        }
        Error(_) -> {
          visit.report(Error(page.FetchError))
          actor.stop()
        }
      }
    }
  }
}
