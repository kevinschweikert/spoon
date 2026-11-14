import gleam/list
import gleam/result
import gleam/string
import gleam/uri
import spoon
import spoon/middleware
import spoon/page

pub fn main() {
  let assert Ok(url) = uri.parse("https://kevinschweikert.de")

  spoon.new(url)
  |> spoon.max_pages(20)
  |> spoon.rate_limit(1000)
  |> spoon.allowed_domains(["kevinschweikert.de", "github.com"])
  |> spoon.on_page(on_site)
  |> spoon.fold([], fn(acc, visited_url) { [visited_url, ..acc] })
  |> result.map(list.sort(_, string.compare))
  |> echo
}

fn on_site(page: page.Page) -> page.Outcome(String) {
  use _outcome <- middleware.log(page)
  use page <- middleware.status_ok("", page)
  page.Outcome(item: uri.to_string(page.url), candidates: page.candidates)
}
