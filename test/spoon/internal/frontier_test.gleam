import gleam/option
import gleam/uri
import grip/origin
import spoon/internal/frontier

const delay = 1000

fn scoop(url: String) -> frontier.Scoop {
  let assert Ok(parsed_url) = uri.parse(url)
  let assert Ok(scoop_origin) = origin.from_uri(parsed_url)
  frontier.Scoop(url: parsed_url, depth: 0, attempts: 0, origin: scoop_origin)
}

pub fn pop_on_an_empty_frontier_is_empty_test() {
  let #(_, popped) = frontier.new(delay) |> frontier.pop(0)

  assert popped == frontier.Empty
}

pub fn pop_returns_a_pushed_scoop_test() {
  let a_first = scoop("https://a.example/1")

  let #(_, popped) =
    frontier.new(delay)
    |> frontier.push(a_first, 0)
    |> frontier.pop(0)

  assert popped == frontier.Took(a_first)
}

pub fn pop_puts_the_scoop_in_flight_test() {
  let queue =
    frontier.new(delay)
    |> frontier.push(scoop("https://a.example/1"), 0)
  assert frontier.in_flight(queue) == 0

  let #(queue, _) = frontier.pop(queue, 0)

  assert frontier.in_flight(queue) == 1
}

pub fn one_request_in_flight_per_origin_test() {
  let queue =
    frontier.new(delay)
    |> frontier.push(scoop("https://a.example/1"), 0)
    |> frontier.push(scoop("https://a.example/2"), 0)

  let #(queue, _) = frontier.pop(queue, 0)
  let #(queue, popped) = frontier.pop(queue, 0)

  assert popped == frontier.Empty
  assert frontier.in_flight(queue) == 1
}

pub fn different_origins_run_in_parallel_test() {
  let a_first = scoop("https://a.example/1")
  let b_first = scoop("https://b.example/1")
  let queue =
    frontier.new(delay)
    |> frontier.push(a_first, 0)
    |> frontier.push(b_first, 100)

  let #(queue, first_pop) = frontier.pop(queue, 100)
  let #(queue, second_pop) = frontier.pop(queue, 100)

  assert first_pop == frontier.Took(a_first)
  assert second_pop == frontier.Took(b_first)
  assert frontier.in_flight(queue) == 2
}

pub fn settle_cools_the_origin_test() {
  let a_first = scoop("https://a.example/1")
  let queue =
    frontier.new(delay)
    |> frontier.push(a_first, 0)
    |> frontier.push(scoop("https://a.example/2"), 0)

  let #(queue, _) = frontier.pop(queue, 0)
  let #(queue, popped) =
    queue
    |> frontier.settle(a_first.origin, 0)
    |> frontier.pop(0)

  assert popped == frontier.Cooling(until: delay)
  assert frontier.in_flight(queue) == 0
}

pub fn cooling_ends_at_next_at_test() {
  let a_first = scoop("https://a.example/1")
  let queue =
    frontier.new(delay)
    |> frontier.push(a_first, 0)
    |> frontier.push(scoop("https://a.example/2"), 0)

  let #(queue, _) = frontier.pop(queue, 0)
  let #(queue, early_pop) =
    queue
    |> frontier.settle(a_first.origin, 0)
    |> frontier.pop(delay - 1)
  let #(_, on_time_pop) = frontier.pop(queue, delay)

  assert early_pop == frontier.Cooling(until: delay)
  let assert frontier.Took(_) = on_time_pop
}

pub fn scoops_are_served_in_order_within_an_origin_test() {
  let a_first = scoop("https://a.example/1")
  let a_second = scoop("https://a.example/2")
  let queue =
    frontier.new(delay)
    |> frontier.push(a_first, 0)
    |> frontier.push(a_second, 0)

  let #(queue, first_pop) = frontier.pop(queue, 0)
  let #(_, second_pop) =
    queue
    |> frontier.settle(a_first.origin, 0)
    |> frontier.pop(delay)

  assert first_pop == frontier.Took(a_first)
  assert second_pop == frontier.Took(a_second)
}

pub fn cooling_reports_the_earliest_origin_test() {
  let queue =
    frontier.new(delay)
    |> frontier.push(scoop("https://a.example/1"), 0)
    |> frontier.push(scoop("https://a.example/2"), 0)
    |> frontier.push(scoop("https://b.example/1"), 0)
    |> frontier.push(scoop("https://b.example/2"), 0)

  let assert #(queue, frontier.Took(first_scoop)) = frontier.pop(queue, 0)
  let assert #(queue, frontier.Took(second_scoop)) = frontier.pop(queue, 0)
  let queue =
    queue
    |> frontier.settle(first_scoop.origin, 500)
    |> frontier.settle(second_scoop.origin, 0)
  let #(_, popped) = frontier.pop(queue, 0)

  assert popped == frontier.Cooling(until: delay)
}

pub fn draining_an_origin_ends_empty_test() {
  let a_first = scoop("https://a.example/1")
  let queue =
    frontier.new(delay)
    |> frontier.push(a_first, 0)
    |> frontier.push(scoop("https://a.example/2"), 0)

  let #(queue, _) = frontier.pop(queue, 0)
  let #(queue, _) =
    queue
    |> frontier.settle(a_first.origin, 0)
    |> frontier.pop(delay)
  let #(queue, popped) =
    queue
    |> frontier.settle(a_first.origin, delay)
    |> frontier.pop(2 * delay)

  assert popped == frontier.Empty
  assert frontier.in_flight(queue) == 0
}

pub fn requeue_returns_the_scoop_to_the_front_test() {
  let a_first = scoop("https://a.example/1")
  let a_second = scoop("https://a.example/2")
  let a_first_retried = frontier.Scoop(..a_first, attempts: 1)
  let #(queue, _) =
    frontier.new(delay)
    |> frontier.push(a_first, 0)
    |> frontier.pop(0)

  let #(_, popped) =
    queue
    |> frontier.push(a_second, 0)
    |> frontier.requeue(a_first.origin, 0)
    |> frontier.pop(delay)

  assert popped == frontier.Took(a_first_retried)
}

pub fn requeue_frees_the_origin_test() {
  let a_first = scoop("https://a.example/1")
  let #(queue, _) =
    frontier.new(delay)
    |> frontier.push(a_first, 0)
    |> frontier.pop(0)

  let queue = frontier.requeue(queue, a_first.origin, 0)

  assert frontier.in_flight(queue) == 0
}

pub fn requeue_cools_the_origin_test() {
  let a_first = scoop("https://a.example/1")
  let #(queue, _) =
    frontier.new(delay)
    |> frontier.push(a_first, 0)
    |> frontier.pop(0)

  let #(_, popped) =
    queue
    |> frontier.requeue(a_first.origin, 0)
    |> frontier.pop(0)

  assert popped == frontier.Cooling(until: delay)
}

pub fn requeue_without_a_scoop_in_flight_is_a_no_op_test() {
  let a_first = scoop("https://a.example/1")
  let #(queue, _) =
    frontier.new(delay)
    |> frontier.push(a_first, 0)
    |> frontier.pop(0)

  let #(queue, popped) =
    queue
    |> frontier.settle(a_first.origin, 0)
    |> frontier.requeue(a_first.origin, 0)
    |> frontier.pop(delay)

  assert popped == frontier.Empty
  assert frontier.in_flight(queue) == 0
}

pub fn requeue_on_an_unknown_origin_is_a_no_op_test() {
  let b_first = scoop("https://b.example/1")

  let #(queue, popped) =
    frontier.new(delay)
    |> frontier.requeue(b_first.origin, 0)
    |> frontier.pop(0)

  assert popped == frontier.Empty
  assert frontier.in_flight(queue) == 0
}

pub fn penalize_frees_the_origin_test() {
  let a_first = scoop("https://a.example/1")
  let #(queue, _) =
    frontier.new(delay)
    |> frontier.push(a_first, 0)
    |> frontier.pop(0)

  let queue = frontier.penalize(queue, a_first.origin, 0, option.None)

  assert frontier.in_flight(queue) == 0
}

pub fn penalize_cools_the_origin_for_twice_the_delay_test() {
  let a_first = scoop("https://a.example/1")
  let #(queue, _) =
    frontier.new(delay)
    |> frontier.push(a_first, 0)
    |> frontier.push(scoop("https://a.example/2"), 0)
    |> frontier.pop(0)

  let #(_, popped) =
    queue
    |> frontier.penalize(a_first.origin, 0, option.None)
    |> frontier.pop(0)

  assert popped == frontier.Cooling(until: 2 * delay)
}

pub fn penalize_does_not_requeue_the_scoop_test() {
  let a_first = scoop("https://a.example/1")
  let a_second = scoop("https://a.example/2")
  let #(queue, _) =
    frontier.new(delay)
    |> frontier.push(a_first, 0)
    |> frontier.push(a_second, 0)
    |> frontier.pop(0)

  let #(_, popped) =
    queue
    |> frontier.penalize(a_first.origin, 0, option.None)
    |> frontier.pop(10 * delay)

  assert popped == frontier.Took(a_second)
}

pub fn penalize_backs_off_exponentially_test() {
  let a_first = scoop("https://a.example/1")
  let queue =
    frontier.new(delay)
    |> frontier.push(a_first, 0)
    |> frontier.push(scoop("https://a.example/2"), 0)
    |> frontier.push(scoop("https://a.example/3"), 0)
  let #(queue, _) = frontier.pop(queue, 0)
  let #(queue, _) =
    queue
    |> frontier.penalize(a_first.origin, 0, option.None)
    |> frontier.pop(2 * delay)

  let #(_, popped) =
    queue
    |> frontier.penalize(a_first.origin, 2 * delay, option.None)
    |> frontier.pop(2 * delay)

  assert popped == frontier.Cooling(until: 6 * delay)
}

pub fn penalize_honours_retry_after_test() {
  let a_first = scoop("https://a.example/1")
  let #(queue, _) =
    frontier.new(delay)
    |> frontier.push(a_first, 0)
    |> frontier.push(scoop("https://a.example/2"), 0)
    |> frontier.pop(0)

  let #(_, popped) =
    queue
    |> frontier.penalize(a_first.origin, delay, option.Some(5 * delay))
    |> frontier.pop(delay)

  assert popped == frontier.Cooling(until: 6 * delay)
}

pub fn penalize_on_an_unknown_origin_is_a_no_op_test() {
  let b_first = scoop("https://b.example/1")

  let #(queue, popped) =
    frontier.new(delay)
    |> frontier.penalize(b_first.origin, 0, option.None)
    |> frontier.pop(0)

  assert popped == frontier.Empty
  assert frontier.in_flight(queue) == 0
}

pub fn settle_on_an_unknown_origin_is_a_no_op_test() {
  let b_first = scoop("https://b.example/1")

  let #(queue, popped) =
    frontier.new(delay)
    |> frontier.settle(b_first.origin, 0)
    |> frontier.pop(0)

  assert popped == frontier.Empty
  assert frontier.in_flight(queue) == 0
}
