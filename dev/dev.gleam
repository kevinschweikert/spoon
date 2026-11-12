import gleam/uri
import spoon
import spoon/middleware
import spoon/page

pub fn main() {
  let assert Ok(url) = uri.parse("https://kevinschweikert.de")

  spoon.new(url)
  |> spoon.max_pages(20)
  |> spoon.rate_limit(100)
  |> spoon.on_page(on_site)
  |> spoon.fold([], fn(acc, visited_url) { [visited_url, ..acc] })
  |> echo
}

fn on_site(base_url: uri.Uri, page: page.Page) -> #(String, page.Candidates) {
  use page <- middleware.log(page)
  use page <- middleware.status_ok("", page)
  use page <- middleware.same_host(base_url, page)
  use page <- middleware.resolve(page)
  use page <- middleware.protocol_http(page)
  #(uri.to_string(page.url), page.Candidates(page.candidates))
}
