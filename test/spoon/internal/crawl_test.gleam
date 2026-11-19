import gleam/list
import gleam/option
import gleam/string
import gleam/uri
import grip/origin
import spoon/internal/crawl
import spoon/internal/frontier
import spoon/internal/requestable

const delay = 1000

fn url(text: String) -> uri.Uri {
  let assert Ok(parsed) = uri.parse(text)
  parsed
}

fn origin_of(text: String) -> origin.Origin {
  let assert Ok(found) = origin.from_uri(url(text))
  found
}

fn req(text: String) -> requestable.Requestable {
  let assert Ok(found) = requestable.from_uri(url(text))
  found
}

fn scoop(text: String) -> frontier.Scoop {
  frontier.new_scoop(req(text))
}

fn fetch(text: String) -> crawl.Effect {
  crawl.Fetch(scoop(text))
}

fn fetched_urls(effects: List(crawl.Effect)) -> List(String) {
  list.filter_map(effects, fn(effect) {
    case effect {
      crawl.Fetch(fetched) ->
        Ok(fetched.requestable |> requestable.to_uri |> uri.to_string)
      _ -> Error(Nil)
    }
  })
}

fn settings_with(seeds: List(String)) -> crawl.Settings {
  crawl.Settings(
    seeds: list.map(seeds, req),
    delay_ms: delay,
    max_concurrency: 10,
    max_pages: 100,
    max_attempts: 3,
  )
}

fn succeeded(
  text: String,
  links: List(String),
  crawl_delay_ms: option.Option(Int),
) -> crawl.Message {
  crawl.Fetched(origin_of(text), crawl_delay_ms, list.map(links, req))
}

fn failed(text: String) -> crawl.Message {
  crawl.Failed(origin_of(text), option.None)
}

fn throttled(text: String, delay_ms: Int) -> crawl.Message {
  crawl.Failed(origin_of(text), option.Some(delay_ms))
}

fn skipped(text: String) -> crawl.Message {
  crawl.Skipped(origin_of(text))
}

pub fn start_fetches_each_origin_once_test() {
  let #(_, effects) =
    crawl.new(settings_with(["https://a.example/", "https://b.example/"]), 0)
  let urls = fetched_urls(effects) |> list.sort(string.compare)

  assert urls == ["https://a.example/", "https://b.example/"]
}

pub fn a_busy_origin_waits_without_a_wake_test() {
  let #(_, effects) =
    crawl.new(
      settings_with(["https://a.example/", "https://a.example/second"]),
      0,
    )

  assert effects == [fetch("https://a.example/")]
}

pub fn max_concurrency_limits_the_first_dispatch_test() {
  let settings =
    crawl.Settings(
      ..settings_with([
        "https://a.example/",
        "https://b.example/",
        "https://c.example/",
      ]),
      max_concurrency: 2,
    )
  let #(_, effects) = crawl.new(settings, 0)

  assert list.length(effects) == 2
  assert list.length(fetched_urls(effects)) == 2
}

pub fn max_pages_zero_finishes_without_fetching_test() {
  let settings =
    crawl.Settings(..settings_with(["https://a.example/"]), max_pages: 0)
  let #(_, effects) = crawl.new(settings, 0)

  assert effects == [crawl.Done]
}

pub fn a_lone_page_finishes_the_crawl_test() {
  let #(state, started) = crawl.new(settings_with(["https://a.example/"]), 0)
  let #(_, finished) =
    state
    |> crawl.update(succeeded("https://a.example/", [], option.None), 100)

  assert started == [fetch("https://a.example/")]
  assert finished == [crawl.Done]
}

pub fn links_on_other_origins_are_fetched_while_this_one_cools_test() {
  let #(state, _) = crawl.new(settings_with(["https://a.example/"]), 0)
  let links = ["https://b.example/1", "https://a.example/2"]
  let #(_, effects) =
    state
    |> crawl.update(succeeded("https://a.example/", links, option.None), 100)

  assert list.length(effects) == 2
  assert fetched_urls(effects) == ["https://b.example/1"]
  assert list.contains(effects, crawl.Wake(at: 100 + delay))
}

pub fn a_link_already_seen_is_not_fetched_again_test() {
  let #(state, _) = crawl.new(settings_with(["https://a.example/"]), 0)
  let #(_, effects) =
    state
    |> crawl.update(
      succeeded("https://a.example/", ["https://a.example/"], option.None),
      100,
    )

  assert effects == [crawl.Done]
}

pub fn a_failed_fetch_is_retried_before_other_queued_urls_test() {
  let retry = frontier.Scoop(..scoop("https://a.example/"), attempts: 1)
  let #(state, started) =
    crawl.new(
      settings_with(["https://a.example/", "https://a.example/second"]),
      0,
    )
  let #(state, failed_effects) =
    state
    |> crawl.update(failed("https://a.example/"), 100)
  let #(_, woken) =
    state
    |> crawl.update(crawl.AfterWake, 1100)

  assert started == [fetch("https://a.example/")]
  assert failed_effects == [crawl.Wake(at: 1100)]
  assert woken == [crawl.Fetch(retry)]
}

pub fn a_failed_fetch_with_throttle_overrides_default_test() {
  let retry = frontier.Scoop(..scoop("https://a.example/"), attempts: 1)
  let #(state, started) =
    crawl.new(
      settings_with(["https://a.example/", "https://a.example/second"]),
      0,
    )
  let #(state, failed_effects) =
    state
    |> crawl.update(throttled("https://a.example/", 2000), 100)
  let #(_, woken) =
    state
    |> crawl.update(crawl.AfterWake, 2100)

  assert started == [fetch("https://a.example/")]
  assert failed_effects == [crawl.Wake(at: 2100)]
  assert woken == [crawl.Fetch(retry)]
}

pub fn a_reported_crawl_delay_sets_the_cooldown_test() {
  let #(state, _) =
    crawl.new(
      settings_with(["https://a.example/", "https://a.example/second"]),
      0,
    )
  let #(_, effects) =
    state
    |> crawl.update(succeeded("https://a.example/", [], option.Some(3000)), 100)

  assert effects == [crawl.Wake(at: 3100)]
}

pub fn the_settings_delay_applies_without_a_crawl_delay_test() {
  let settings =
    crawl.Settings(
      ..settings_with(["https://a.example/", "https://a.example/second"]),
      delay_ms: 250,
    )
  let #(state, _) = crawl.new(settings, 0)
  let #(_, effects) =
    state
    |> crawl.update(succeeded("https://a.example/", [], option.None), 100)

  assert effects == [crawl.Wake(at: 350)]
}

pub fn a_skipped_page_releases_its_origin_without_a_cooldown_test() {
  let #(state, started) =
    crawl.new(
      settings_with([
        "https://a.example/private/x",
        "https://a.example/public/y",
      ]),
      0,
    )
  let #(_, effects) =
    state
    |> crawl.update(skipped("https://a.example/private/x"), 100)

  assert started == [fetch("https://a.example/private/x")]
  assert effects == [fetch("https://a.example/public/y")]
}

pub fn a_skipped_page_is_not_counted_as_a_request_test() {
  let settings =
    crawl.Settings(
      ..settings_with([
        "https://a.example/private/x",
        "https://a.example/public/y",
      ]),
      max_pages: 1,
    )
  let #(state, _) = crawl.new(settings, 0)
  let #(_, effects) =
    state
    |> crawl.update(skipped("https://a.example/private/x"), 100)

  assert effects == [fetch("https://a.example/public/y")]
}

pub fn a_skip_on_one_origin_does_not_block_another_test() {
  let #(state, started) =
    crawl.new(
      settings_with([
        "https://a.example/private/x",
        "https://b.example/private/x",
      ]),
      0,
    )
  let #(state, after_skip) =
    state
    |> crawl.update(skipped("https://a.example/private/x"), 0)
  let #(_, finished) =
    state
    |> crawl.update(
      succeeded("https://b.example/private/x", [], option.None),
      0,
    )

  assert list.length(started) == 2
  assert after_skip == []
  assert finished == [crawl.Done]
}

pub fn done_waits_until_every_in_flight_fetch_has_reported_test() {
  let #(state, _) =
    crawl.new(settings_with(["https://a.example/", "https://b.example/"]), 0)
  let #(state, waiting) =
    state
    |> crawl.update(succeeded("https://a.example/", [], option.None), 100)
  let #(_, finished) =
    state
    |> crawl.update(succeeded("https://b.example/", [], option.None), 100)

  assert waiting == []
  assert finished == [crawl.Done]
}

pub fn a_fetched_for_an_idle_origin_is_ignored_test() {
  let #(state, _) = crawl.new(settings_with(["https://a.example/"]), 0)
  let #(_, effects) =
    state
    |> crawl.update(
      succeeded("https://c.example/", ["https://b.example/"], option.None),
      100,
    )

  assert effects == []
}

pub fn a_skipped_for_an_idle_origin_is_ignored_test() {
  let #(state, _) = crawl.new(settings_with(["https://a.example/"]), 0)
  let #(_, effects) =
    state
    |> crawl.update(skipped("https://c.example/"), 100)

  assert effects == []
}

pub fn a_crash_report_after_a_clean_exit_changes_nothing_test() {
  let a_origin = origin_of("https://a.example/")
  let #(state, _) =
    crawl.new(settings_with(["https://a.example/", "https://b.example/"]), 0)
  let #(state, reported) =
    state
    |> crawl.update(succeeded("https://a.example/", [], option.None), 100)
  let #(_, down) =
    state
    |> crawl.update(crawl.Failed(a_origin, option.None), 100)

  assert reported == []
  assert down == []
}

pub fn a_crashed_fetch_is_retried_after_the_cooldown_test() {
  let a_origin = origin_of("https://a.example/")
  let retry = frontier.Scoop(..scoop("https://a.example/"), attempts: 1)
  let #(state, _) = crawl.new(settings_with(["https://a.example/"]), 0)
  let #(state, crashed) =
    state
    |> crawl.update(crawl.Failed(a_origin, option.None), 100)
  let #(_, retried) =
    state
    |> crawl.update(crawl.AfterWake, 1100)

  assert crashed == [crawl.Wake(at: 1100)]
  assert retried == [crawl.Fetch(retry)]
}

pub fn an_early_wake_repeats_the_wake_without_fetching_test() {
  let #(state, _) =
    crawl.new(
      settings_with(["https://a.example/", "https://a.example/second"]),
      0,
    )
  let #(state, cooling) =
    state
    |> crawl.update(succeeded("https://a.example/", [], option.None), 100)
  let #(_, early) =
    state
    |> crawl.update(crawl.AfterWake, 500)

  assert cooling == [crawl.Wake(at: 1100)]
  assert early == [crawl.Wake(at: 1100)]
}

pub fn max_pages_stops_dispatch_and_finishes_when_in_flight_drains_test() {
  let settings =
    crawl.Settings(
      ..settings_with([
        "https://a.example/",
        "https://b.example/",
        "https://c.example/",
      ]),
      max_pages: 2,
    )
  let #(state, started) = crawl.new(settings, 0)
  let assert [first_url, second_url] = fetched_urls(started)
  let #(state, after_first) =
    state
    |> crawl.update(succeeded(first_url, [], option.None), 100)
  let #(_, finished) =
    state
    |> crawl.update(succeeded(second_url, [], option.None), 100)

  assert after_first == []
  assert finished == [crawl.Done]
}

pub fn a_page_that_crashes_three_times_is_dropped_test() {
  let a_origin = origin_of("https://a.example/")
  let first_retry = frontier.Scoop(..scoop("https://a.example/"), attempts: 1)
  let second_retry = frontier.Scoop(..scoop("https://a.example/"), attempts: 2)
  let #(state, _) = crawl.new(settings_with(["https://a.example/"]), 0)
  let #(state, after_first_crash) =
    state
    |> crawl.update(crawl.Failed(a_origin, option.None), 100)
  let #(state, first_attempt_again) =
    state
    |> crawl.update(crawl.AfterWake, 1100)
  let #(state, after_second_crash) =
    state
    |> crawl.update(crawl.Failed(a_origin, option.None), 1100)
  let #(state, second_attempt_again) =
    state
    |> crawl.update(crawl.AfterWake, 2100)
  let #(_, after_third_crash) =
    state
    |> crawl.update(crawl.Failed(a_origin, option.None), 2100)

  assert after_first_crash == [crawl.Wake(at: 1100)]
  assert first_attempt_again == [crawl.Fetch(first_retry)]
  assert after_second_crash == [crawl.Wake(at: 2100)]
  assert second_attempt_again == [crawl.Fetch(second_retry)]
  assert after_third_crash == [crawl.Done]
}
