import gleam/bool
import gleam/erlang/process
import gleam/http/request
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/otp/factory_supervisor
import gleam/result
import gleam/set
import gleam/uri
import spoon/internal/config
import spoon/internal/fetcher
import spoon/page

pub type Crawl(item, acc) {
  Crawl(
    frontier: List(uri.Uri),
    seen: set.Set(uri.Uri),
    requests: Int,
    name: process.Name(Message),
    in_flight: Int,
    self: process.Subject(Message),
    fetchers: process.Name(fetcher.Factory),
    reply: process.Subject(acc),
    accumulator: acc,
    combine: fn(acc, item) -> acc,
    config: config.Config(item),
  )
}

pub type Message {
  Start
  Visited(page.Page)
  Errored
}

pub fn start(
  name: process.Name(Message),
  config: config.Config(item),
  initial: acc,
  combine: fn(acc, item) -> acc,
  reply: process.Subject(acc),
  fetchers: process.Name(fetcher.Factory),
) -> Result(actor.Started(process.Subject(Message)), actor.StartError) {
  actor.new_with_initialiser(100, fn(self: process.Subject(Message)) {
    process.send(self, Start)
    Crawl(
      name:,
      frontier: [],
      seen: set.new(),
      requests: 0,
      in_flight: 0,
      self:,
      fetchers:,
      reply:,
      accumulator: initial,
      config:,
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
  crawl: Crawl(item, acc),
  message: Message,
) -> actor.Next(Crawl(item, acc), Message) {
  case message {
    Start ->
      crawl
      |> enqueue([crawl.config.base_url, ..crawl.config.start_urls])
      |> dispatch()
      |> finish_or_continue()

    Errored ->
      Crawl(..crawl, in_flight: crawl.in_flight - 1)
      |> dispatch()
      |> finish_or_continue()

    Visited(page) -> {
      let crawl =
        Crawl(
          ..crawl,
          in_flight: crawl.in_flight - 1,
          requests: crawl.requests + 1,
        )
      let #(item, page.Candidates(links)) = crawl.config.on_page(page)
      crawl
      |> combine(item)
      |> enqueue(links)
      |> dispatch()
      |> finish_or_continue()
    }
  }
}

fn combine(crawl: Crawl(item, acc), item: item) -> Crawl(item, acc) {
  let accumulator = crawl.combine(crawl.accumulator, item)
  Crawl(..crawl, accumulator:)
}

fn finish_or_continue(
  crawl: Crawl(item, acc),
) -> actor.Next(Crawl(item, acc), a) {
  case crawl.in_flight {
    0 -> {
      process.send(crawl.reply, crawl.accumulator)
      actor.stop()
    }
    _ -> actor.continue(crawl)
  }
}

fn dispatch(crawl: Crawl(item, acc)) -> Crawl(item, acc) {
  use <- bool.guard(when: capacity_reached(crawl), return: crawl)

  case crawl.frontier {
    [] -> crawl
    [link, ..frontier] -> {
      let crawl = Crawl(..crawl, frontier:)
      let crawl = case crawl.config.prefetch(link) {
        Ok(link) ->
          case build_request(crawl.config, link) {
            Ok(request) -> start_fetcher(crawl, request)
            Error(_) -> crawl
          }
        Error(_) -> crawl
      }
      dispatch(crawl)
    }
  }
}

fn build_request(
  config: config.Config(item),
  link: uri.Uri,
) -> Result(request.Request(String), Nil) {
  use request <- result.try(request.from_uri(link))
  Ok(request.set_header(request, "user-agent", config.user_agent))
}

fn capacity_reached(crawl: Crawl(item, acc)) -> Bool {
  crawl.in_flight >= crawl.config.max_concurrency
  || crawl.requests + crawl.in_flight >= crawl.config.max_pages
}

fn start_fetcher(
  crawl: Crawl(item, acc),
  request: request.Request(String),
) -> Crawl(item, acc) {
  let visit =
    fetcher.Visit(
      request:,
      fetch: crawl.config.fetch,
      next: crawl.config.next,
      report: fn(report) {
        case report {
          Ok(page) -> process.send(crawl.self, Visited(page))
          Error(_) -> process.send(crawl.self, Errored)
        }
      },
    )
  case
    factory_supervisor.start_child(
      factory_supervisor.get_by_name(crawl.fetchers),
      visit,
    )
  {
    Ok(_) -> Crawl(..crawl, in_flight: crawl.in_flight + 1)
    Error(_) -> crawl
  }
}

fn enqueue(crawl: Crawl(item, acc), links: List(uri.Uri)) -> Crawl(item, acc) {
  links
  |> list.map(normalize)
  |> list.fold(crawl, fn(crawl, link) {
    case set.contains(crawl.seen, link) {
      True -> crawl
      False ->
        Crawl(
          ..crawl,
          frontier: list.append(crawl.frontier, [link]),
          seen: set.insert(crawl.seen, link),
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
