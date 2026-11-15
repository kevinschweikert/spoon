import gleam/uri
import spoon
import spoon/middleware
import spoon/page

pub fn main() {
  let assert Ok(url) = uri.parse("https://kevinschweikert.de")

  spoon.new(url)
  |> spoon.max_pages(10)
  |> spoon.rate_limit(1000)
  |> spoon.allow_all_domains()
  |> spoon.on_page(on_site)
  |> spoon.fold([], fn(acc, _visited_url) { acc })
}

fn on_site(page: page.Page) -> page.Outcome(String) {
  use _outcome <- middleware.log(page)
  use page <- middleware.status_ok("", page)
  page.Outcome(item: uri.to_string(page.url), candidates: page.candidates)
}
