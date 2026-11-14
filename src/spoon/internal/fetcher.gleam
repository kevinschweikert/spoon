import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/otp/actor
import gleam/otp/factory_supervisor
import gleam/result
import gleam/uri
import spoon/internal/frontier
import spoon/page

pub type Factory(item) =
  factory_supervisor.Message(Visit(item), process.Subject(Message))

pub type Visit(item) {
  Visit(
    scoop: frontier.Scoop,
    build_request: fn(uri.Uri) ->
      Result(request.Request(String), page.FetchError),
    fetch: fn(request.Request(String)) ->
      Result(response.Response(String), page.FetchError),
    next: fn(response.Response(String)) -> List(uri.Uri),
    on_page: fn(page.Page) -> page.Outcome(item),
    report: fn(Result(page.Outcome(item), page.FetchError)) -> Nil,
  )
}

pub opaque type Message {
  Fetch
}

pub fn start(
  visit: Visit(item),
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
  visit: Visit(item),
  message: Message,
) -> actor.Next(Visit(item), Message) {
  let answer = case message {
    Fetch -> {
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
  }
  visit.report(answer)
  actor.stop()
}
