# spoon

Ladle your (presentable) soup! Spoon is a Gleam crawler framework.

[![Package Version](https://img.shields.io/hexpm/v/spoon)](https://hex.pm/packages/spoon)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://spoon.hexdocs.pm/)

```sh
gleam add spoon@1
```

`spoon` is a Gleam web crawler framework. It currently only runs on the Erlang target
because it makes heavy use of OTP framework to parallelize the work as best as possible.

By default it tries to be as polite as possible. That means:

- respecting `robots.txt`
- respecting HTTP status code 429 and their `Retry-After` header
- respecting links with `rel="nofollow"`
- respecting meta tags with `"noindex"`
- abort after a configurable amount of retries
- defaults to a 1s request interval per host
- defaults to stay on the configured host

```gleam
import spoon

pub fn main() -> Nil {
      let assert Ok(example_com) = spoon.request("https://example.com")

      example_com
      |> spoon.new()
      |> spoon.run()
}
```

Further documentation can be found at <https://spoon.hexdocs.pm/>.

## Development

```sh
gleam run   # Run the project
gleam test  # Run the tests
```

## Non-goals

- JavaScript rendering (no Chromium/Puppeteer/etc).

## Prior art

- [Scrapy](https://scrapy.org/) (Python)
- [Colly](https://go-colly.org/) (Go)
- [Apache Nutch](https://nutch.apache.org/) (Java)
- [Heritrix](https://github.com/internetarchive/heritrix3) (Java)
- [StormCrawler](https://stormcrawler.net/) (Java)
- [Crawly](https://github.com/elixir-crawly/crawly) (Elixir)
- [Hop](https://github.com/seanmor5/hop) (Elixir)
