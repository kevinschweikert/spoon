import gleam/bool
import gleam/deque
import gleam/dict
import gleam/int
import gleam/option
import gleam/uri
import grip/origin.{type Origin}

pub type Scoop {
  Scoop(url: uri.Uri, depth: Int, attempts: Int, origin: Origin)
}

pub type Slot {
  Slot(
    delay_ms: Int,
    scoops: deque.Deque(Scoop),
    in_flight: option.Option(Scoop),
    failures: Int,
    next_at: Int,
  )
}

// Postponed optimizations:
// - `take_earliest` scans every origin slot on each pop. A balanced tree
//   keyed by `next_at`, or one bucket per distinct `delay_ms`, would make
//   origin lookups cheaper.
// - `in_flight` walks the whole dict on every call. A running counter
//   updated in `pop`, `settle`, and `requeue` would avoid that traversal.
pub opaque type Frontier {
  Frontier(slots: dict.Dict(Origin, Slot))
}

pub type Popped {
  Took(scoop: Scoop)
  Cooling(until: Int)
  Empty
}

pub fn new_scoop(origin: Origin, url: uri.Uri) -> Scoop {
  Scoop(url:, depth: 0, attempts: 0, origin:)
}

pub fn new() -> Frontier {
  Frontier(slots: dict.new())
}

pub fn pop(frontier: Frontier, now: Int) -> #(Frontier, Popped) {
  case take_earliest(frontier.slots) {
    option.None -> #(frontier, Empty)
    option.Some(#(origin, slot, scoop)) -> {
      case slot.next_at > now {
        True -> #(frontier, Cooling(until: slot.next_at))
        False -> #(
          Frontier(slots: dict.insert(frontier.slots, origin, slot)),
          Took(scoop),
        )
      }
    }
  }
}

fn take_earliest(
  slots: dict.Dict(Origin, Slot),
) -> option.Option(#(Origin, Slot, Scoop)) {
  use best, origin, slot <- dict.fold(slots, option.None)
  use <- bool.guard(option.is_some(slot.in_flight), best)
  use <- bool.guard(!is_better(best, slot), best)

  case deque.pop_front(slot.scoops) {
    Ok(#(scoop, scoops)) -> {
      option.Some(#(
        origin,
        Slot(..slot, scoops:, in_flight: option.Some(scoop)),
        scoop,
      ))
    }
    Error(_) -> best
  }
}

fn is_better(best: option.Option(#(Origin, Slot, Scoop)), slot: Slot) -> Bool {
  case best {
    option.None -> True
    option.Some(#(_, b, _)) -> b.next_at >= slot.next_at
  }
}

pub fn push(
  frontier: Frontier,
  scoop: Scoop,
  delay_ms: Int,
  now: Int,
) -> Frontier {
  case dict.get(frontier.slots, scoop.origin) {
    Ok(slot) ->
      Frontier(slots: dict.insert(
        frontier.slots,
        scoop.origin,
        Slot(..slot, scoops: deque.push_back(slot.scoops, scoop)),
      ))
    Error(_) ->
      Frontier(slots: dict.insert(
        frontier.slots,
        scoop.origin,
        Slot(
          delay_ms: delay_ms,
          scoops: deque.from_list([scoop]),
          in_flight: option.None,
          failures: 0,
          next_at: now,
        ),
      ))
  }
}

pub fn settle(frontier: Frontier, origin: Origin, now: Int) -> Frontier {
  case dict.get(frontier.slots, origin) {
    Ok(slot) -> {
      use <- bool.guard(option.is_none(slot.in_flight), frontier)
      let slot =
        Slot(..slot, in_flight: option.None, next_at: now + slot.delay_ms)
      Frontier(slots: dict.insert(frontier.slots, origin, slot))
    }
    Error(_) -> frontier
  }
}

pub fn requeue(frontier: Frontier, origin: Origin, now: Int) -> Frontier {
  case dict.get(frontier.slots, origin) {
    Ok(Slot(scoops: scoops, in_flight: option.Some(scoop), ..) as slot) -> {
      Frontier(slots: dict.insert(
        frontier.slots,
        origin,
        Slot(
          ..slot,
          next_at: now + slot.delay_ms,
          in_flight: option.None,
          scoops: deque.push_front(
            scoops,
            Scoop(..scoop, attempts: scoop.attempts + 1),
          ),
        ),
      ))
    }
    _ -> frontier
  }
}

pub fn penalize(
  frontier: Frontier,
  origin: Origin,
  now: Int,
  retry_after: option.Option(Int),
) -> Frontier {
  case dict.get(frontier.slots, origin) {
    Ok(slot) -> {
      let failures = slot.failures + 1
      let backoff =
        option.lazy_unwrap(retry_after, fn() {
          // exponential backoff
          slot.delay_ms * int.bitwise_shift_left(1, failures)
        })
      let slot =
        Slot(..slot, next_at: now + backoff, failures:, in_flight: option.None)
      let slots = dict.insert(frontier.slots, origin, slot)
      Frontier(slots:)
    }
    Error(_) -> frontier
  }
}

pub fn in_flight(frontier: Frontier) -> Int {
  dict.fold(frontier.slots, 0, fn(count, _origin, slot) {
    case option.is_some(slot.in_flight) {
      True -> count + 1
      False -> count
    }
  })
}

pub fn in_flight_for(
  frontier: Frontier,
  origin: Origin,
) -> option.Option(Scoop) {
  case dict.get(frontier.slots, origin) {
    Ok(slot) -> slot.in_flight
    _ -> option.None
  }
}
