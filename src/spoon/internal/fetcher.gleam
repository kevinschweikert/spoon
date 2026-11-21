import gleam/bool
import gleam/dict
import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import gleam/time/duration
import gleam/time/timestamp
import gleam/uri
import presentable_soup as soup
import spoon/internal/config
import spoon/internal/frontier
import spoon/internal/policy_cache
import spoon/internal/requestable
import spoon/page
import spoon/visit

pub type Attempt(item) {
  Responded(
    status: Int,
    links: List(requestable.Requestable),
    item: option.Option(item),
  )
  Skipped(reason: visit.SkipReason)
  Errored(error: page.HttpError)
}

pub fn run(
  scoop: frontier.Scoop,
  config: config.Config(item),
  policy_cache: process.Name(policy_cache.Message),
) -> #(option.Option(Int), Attempt(item)) {
  let config.Config(fetch:, scrape:, user_agent:, respect_robots:, ..) = config
  let policy_answer = case respect_robots {
    True ->
      process.call(process.named_subject(policy_cache), 10_000, fn(reply) {
        policy_cache.Check(scoop:, reply:)
      })
    False -> Ok(policy_cache.PolicyAnswer(True, option.None))
  }
  case policy_answer {
    Ok(policy_cache.PolicyAnswer(allowed:, delay_ms:)) -> {
      case allowed {
        False -> #(delay_ms, Skipped(visit.Disallowed))
        True ->
          case do_fetch(scoop, user_agent, fetch) {
            Ok(response) -> #(delay_ms, responded(scoop, response, scrape))
            Error(err) -> #(delay_ms, Errored(err))
          }
      }
    }
    Error(err) -> #(option.None, Errored(err))
  }
}

fn responded(
  scoop: frontier.Scoop,
  response: response.Response(String),
  scrape: fn(page.Page(item), response.Response(String)) -> page.Page(item),
) -> Attempt(item) {
  let prefilled =
    page.from_scoop(scoop)
    |> prefill_anchors(response.body)
    |> prefill_location_header(response.headers)
  let scraped = case http_ok(response.status) && is_noindex(response.body) {
    True -> prefilled
    False -> scrape(prefilled, response)
  }
  Responded(
    status: response.status,
    links: page.requestable_links(scraped),
    item: page.item(scraped),
  )
}

fn prefill_location_header(
  page: page.Page(item),
  headers: List(#(String, String)),
) -> page.Page(item) {
  case headers |> dict.from_list() |> dict.get("location") {
    Ok(location) ->
      case uri.parse(location) {
        Ok(link) ->
          case page.add_link(page, link) {
            Ok(new_page) -> new_page
            Error(_) -> page
          }
        Error(_) -> page
      }
    Error(_) -> page
  }
}

fn prefill_anchors(page: page.Page(item), body: String) -> page.Page(item) {
  [soup.with_tag("a")]
  |> soup.elements()
  |> soup.return(soup.attributes())
  |> soup.scrape(body)
  |> result.unwrap([])
  |> list.map(dict.from_list)
  |> list.filter(allowed_to_follow)
  |> list.filter_map(has_href)
  |> list.filter_map(uri.parse)
  |> list.fold(page, fn(page, link) {
    case page.add_link(page, link) {
      Ok(new_page) -> new_page
      Error(_) -> page
    }
  })
}

fn has_href(attributes: dict.Dict(String, String)) -> Result(String, Nil) {
  dict.get(attributes, "href")
}

fn allowed_to_follow(attributes: dict.Dict(String, String)) -> Bool {
  dict.get(attributes, "rel")
  |> result.map(fn(rel) {
    rel
    |> string.lowercase
    |> string.split(" ")
    |> list.contains("nofollow")
    |> bool.negate
  })
  |> result.unwrap(True)
}

fn http_ok(status: Int) -> Bool {
  status >= 200 && status <= 299
}

fn do_fetch(
  scoop: frontier.Scoop,
  user_agent: String,
  fetch: fn(request.Request(String)) ->
    Result(response.Response(String), page.HttpError),
) -> Result(response.Response(String), page.HttpError) {
  let request = requestable.to_request(scoop.requestable, user_agent)
  use response <- result.try(fetch(request))
  case response.status {
    429 | 503 -> {
      response.get_header(response, "retry-after")
      |> result.try(parse_retry_after)
      |> option.from_result()
      |> page.Throttled
      |> Error
    }
    _ -> Ok(response)
  }
}

fn is_noindex(body: String) -> Bool {
  let metas =
    [soup.with_tag("meta")]
    |> soup.elements()
    |> soup.return(soup.attributes())
    |> soup.scrape(body)
    |> result.unwrap([])

  use meta <- list.any(metas)
  let attrs = dict.from_list(meta)
  case dict.get(attrs, "name"), dict.get(attrs, "content") {
    Ok(name), Ok(content) ->
      string.trim(string.lowercase(name)) == "robots"
      && string.contains(string.lowercase(content), "noindex")
    _, _ -> False
  }
}

fn parse_retry_after(value: String) -> Result(Int, Nil) {
  let value = string.trim(value)
  parse_delay(value)
  |> result.lazy_or(fn() { parse_http_date(value) })
}

fn parse_delay(value: String) -> Result(Int, Nil) {
  case int.parse(value) {
    Ok(delay) if delay >= 0 -> Ok(delay)
    _ -> Error(Nil)
  }
}

fn parse_http_date(value: String) -> Result(Int, Nil) {
  use at <- result.map(timestamp.parse_http_date(value))
  timestamp.system_time()
  |> timestamp.difference(at)
  |> duration.to_milliseconds()
  |> int.max(0)
}
