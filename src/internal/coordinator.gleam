import gleam/bool
import gleam/erlang/process
import gleam/http/response
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/otp/factory_supervisor
import gleam/set
import gleam/uri
import internal/fetcher
import page

pub type State(item, acc) {
  State(
    frontier: List(uri.Uri),
    visited: set.Set(uri.Uri),
    requests: Int,
    start_urls: List(uri.Uri),
    name: process.Name(Message),
    on_page: fn(page.Page) -> #(item, page.Candidates),
    in_flight: Int,
    max_in_flight: Int,
    max_pages: Int,
    self: process.Subject(Message),
    prefetch: fn(uri.Uri) -> Result(uri.Uri, page.FetchError),
    fetch: fn(uri.Uri) -> Result(response.Response(String), page.FetchError),
    next: fn(response.Response(String)) -> List(uri.Uri),
    fetchers: process.Name(fetcher.Factory),
    reply: process.Subject(acc),
    accumulator: acc,
    combine: fn(acc, item) -> acc,
  )
}

pub type Message {
  Start
  Fetched(page.Page)
  Errored
}

pub type Options(item, acc) {
  Options(
    start_urls: List(uri.Uri),
    on_page: fn(page.Page) -> #(item, page.Candidates),
    prefetch: fn(uri.Uri) -> Result(uri.Uri, page.FetchError),
    fetch: fn(uri.Uri) -> Result(response.Response(String), page.FetchError),
    next: fn(response.Response(String)) -> List(uri.Uri),
    fetchers: process.Name(fetcher.Factory),
    max_pages: Int,
    max_in_flight: Int,
    initial: acc,
    combine: fn(acc, item) -> acc,
  )
}

pub fn start(
  name: process.Name(Message),
  options: Options(item, acc),
  reply: process.Subject(acc),
) -> Result(actor.Started(process.Subject(Message)), actor.StartError) {
  actor.new_with_initialiser(100, fn(self: process.Subject(Message)) {
    process.send(self, Start)
    State(
      frontier: [],
      visited: set.new(),
      requests: 0,
      start_urls: options.start_urls,
      name:,
      on_page: options.on_page,
      in_flight: 0,
      max_in_flight: options.max_in_flight,
      max_pages: options.max_pages,
      self:,
      prefetch: options.prefetch,
      fetch: options.fetch,
      next: options.next,
      fetchers: options.fetchers,
      reply:,
      accumulator: options.initial,
      combine: options.combine,
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
  state: State(item, acc),
  message: Message,
) -> actor.Next(State(item, acc), Message) {
  case message {
    Start ->
      state
      |> enqueue(state.start_urls)
      |> dispatch()
      |> finish_or_continue()

    Errored ->
      State(..state, in_flight: state.in_flight - 1)
      |> dispatch()
      |> finish_or_continue()

    Fetched(page) -> {
      let state =
        State(
          ..state,
          in_flight: state.in_flight - 1,
          requests: state.requests + 1,
        )
      let #(item, page.Candidates(links)) = state.on_page(page)
      state
      |> combine(item)
      |> enqueue(links)
      |> dispatch()
      |> finish_or_continue()
    }
  }
}

fn combine(state: State(item, acc), item: item) -> State(item, acc) {
  let accumulator = state.combine(state.accumulator, item)
  State(..state, accumulator:)
}

fn finish_or_continue(
  state: State(item, acc),
) -> actor.Next(State(item, acc), a) {
  case state.in_flight {
    0 -> {
      process.send(state.reply, state.accumulator)
      actor.stop()
    }
    _ -> actor.continue(state)
  }
}

fn dispatch(state: State(item, acc)) -> State(item, acc) {
  use <- bool.guard(when: capacity_reached(state), return: state)

  case state.frontier {
    [] -> state
    [link, ..frontier] -> {
      let state = State(..state, frontier:)
      let state = case state.prefetch(link) {
        Error(_) -> state
        Ok(link) -> start_fetcher(state, link)
      }
      dispatch(state)
    }
  }
}

fn capacity_reached(state: State(item, acc)) -> Bool {
  state.in_flight >= state.max_in_flight
  || state.requests + state.in_flight >= state.max_pages
}

fn start_fetcher(state: State(item, acc), link: uri.Uri) -> State(item, acc) {
  let job =
    fetcher.Job(
      link:,
      fetch: state.fetch,
      next: state.next,
      report: fn(report) {
        case report {
          Ok(page) -> process.send(state.self, Fetched(page))
          Error(_) -> process.send(state.self, Errored)
        }
      },
    )
  case
    factory_supervisor.start_child(
      factory_supervisor.get_by_name(state.fetchers),
      job,
    )
  {
    Ok(_) -> State(..state, in_flight: state.in_flight + 1)
    Error(_) -> state
  }
}

fn enqueue(state: State(item, acc), links: List(uri.Uri)) -> State(item, acc) {
  links
  |> list.map(normalize)
  |> list.fold(state, fn(state, link) {
    case set.contains(state.visited, link) {
      True -> state
      False ->
        State(
          ..state,
          frontier: list.append(state.frontier, [link]),
          visited: set.insert(state.visited, link),
        )
    }
  })
}

fn normalize(url: uri.Uri) -> uri.Uri {
  let path = case url.path {
    "" -> "/"
    path -> path
  }

  uri.Uri(..url, path:, fragment: option.None)
}
