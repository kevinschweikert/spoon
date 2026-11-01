import gleam/erlang/process
import gleam/http/response
import gleam/otp/actor
import gleam/otp/factory_supervisor
import gleam/uri
import page

pub type Factory =
  factory_supervisor.Message(Job, process.Subject(Message))

pub type Job {
  Job(
    link: uri.Uri,
    fetch: fn(uri.Uri) -> Result(response.Response(String), page.FetchError),
    next: fn(response.Response(String)) -> List(uri.Uri),
    report: fn(Result(page.Page, page.FetchError)) -> Nil,
  )
}

pub opaque type Message {
  Fetch
}

pub fn start(
  job: Job,
) -> Result(actor.Started(process.Subject(Message)), actor.StartError) {
  actor.new_with_initialiser(100, fn(self) {
    process.send(self, Fetch)

    actor.initialised(job)
    |> actor.returning(self)
    |> Ok
  })
  |> actor.on_message(handle_message)
  |> actor.start
}

fn handle_message(job: Job, message: Message) -> actor.Next(Job, Message) {
  case message {
    Fetch -> {
      case job.fetch(job.link) {
        Ok(resp) -> {
          page.Page(
            url: job.link,
            status: resp.status,
            body: resp.body,
            candidates: job.next(resp),
          )
          |> Ok()
          |> job.report()
          actor.stop()
        }
        Error(_) -> {
          job.report(Error(page.FetchError))
          actor.stop()
        }
      }
    }
  }
}
