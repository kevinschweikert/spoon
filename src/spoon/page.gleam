import gleam/list
import gleam/option
import gleam/result
import gleam/uri
import spoon/internal/frontier
import spoon/internal/requestable

@internal
pub type Link {
  Link(url: uri.Uri, nofollow: Bool)
}

@internal
pub fn is_crawlable(link: Link) -> Bool {
  !link.nofollow
}

pub opaque type Page(item) {
  Page(
    url: requestable.Requestable,
    depth: Int,
    links: List(requestable.Requestable),
    item: option.Option(item),
  )
}

@internal
pub fn from_scoop(scoop: frontier.Scoop) -> Page(item) {
  Page(url: scoop.requestable, depth: scoop.depth, links: [], item: option.None)
}

pub fn url(page: Page(item)) -> uri.Uri {
  page.url |> requestable.to_uri
}

pub fn links(page: Page(item)) -> List(uri.Uri) {
  page.links |> list.map(requestable.to_uri)
}

pub fn item(page: Page(item)) -> option.Option(item) {
  page.item
}

@internal
pub fn requestable_links(page: Page(item)) -> List(requestable.Requestable) {
  page.links
}

pub fn add_link(page: Page(item), link: uri.Uri) -> Result(Page(item), Nil) {
  use requestable <- result.try(requestable.resolve(page.url, link))
  Ok(Page(..page, links: [requestable, ..page.links]))
}

pub fn set_item(page: Page(item), item: item) -> Page(item) {
  Page(..page, item: option.Some(item))
}
