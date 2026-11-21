import gleam/http/response
import gleam/int
import gleam/io
import gleam/uri
import spoon
import spoon/page

pub fn main() {
  let assert Ok(url) = spoon.request("https://kevinschweikert.de")

  spoon.new(url)
  |> spoon.max_pages(100)
  |> spoon.max_depth(1)
  |> spoon.allow_all_hosts
  |> spoon.delay(1000)
  |> spoon.scrape(on_site)
  |> spoon.fold([], fn(acc, _visited_url) { acc })
}

fn on_site(
  current: page.Page(String),
  resp: response.Response(String),
) -> page.Page(String) {
  let url = uri.to_string(page.url(current))
  io.println(int.to_string(resp.status) <> " " <> url)
  page.set_item(current, url)
}
