///|
struct Channel[T] {
  values : @deque.Deque[T]
  readers : @deque.Deque[Reader[T]]
  mut closed : Bool
}

///|
/// Raised by `recv` once a closed channel is drained.
///
/// This is the channel's analogue of EOF on a pipe: the only way a receiver can
/// learn that no value will ever arrive. Without it, a receiver whose sender is
/// gone blocks forever, which is indistinguishable from a slow sender.
pub(all) suberror ChannelClosed {
  ChannelClosed
} derive(Debug)

///|
// Deriving `Debug` promotes `to_repr` to a regular method; declare the
// promotion explicitly instead of relying on the deprecated implicit form.
// Hidden from the interface — `Debug::to_repr` is the supported call form.
#deprecated("Use `Debug::to_repr` instead", skip_current_package=true)
#doc(hidden)
pub extend ChannelClosed with @debug.Debug::{to_repr}

///|
priv enum Reader[T] {
  Recv(@coroutine.Coroutine, mut value~ : T?)
  RecvTo(@select.Selector[T])
  RecvMapTo((T?) -> Bool)
}

///|
pub fn[T] Channel::new() -> Channel[T] {
  Channel::{
    values: @deque.Deque([]),
    readers: @deque.Deque([]),
    closed: false,
  }
}

///|
pub fn[T] Channel::send(self : Channel[T], value : T) -> Unit {
  if self.closed {
    abort("@tonyfettes/co: send on a closed channel")
  }
  while self.readers.pop_front() is Some(reader) {
    match reader {
      Recv(coroutine, value=_) as receiver => {
        receiver.value = Some(value)
        coroutine.schedule()
        break
      }
      RecvTo({ state: Pending, coroutine, .. } as selected) => {
        selected.state = Completed
        selected.value = Some(value)
        if coroutine is Some(coroutine) {
          coroutine.schedule()
        }
        break
      }
      RecvMapTo(func) if func(Some(value)) => break
      _ => continue
    }
  } nobreak {
    self.values.push_back(value)
  }
}

///|
/// Close the channel: no further values will ever arrive, and every parked
/// receiver is woken so it can observe that.
///
/// Idempotent, so any number of teardown paths may call it. Buffered values are
/// still delivered first, like a pipe that is drained before EOF. This is the
/// only way a receiver learns that its sender is gone; without it the receiver
/// would wait forever, which looks exactly like a slow sender.
pub fn[T] Channel::close(self : Channel[T]) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  // Waking everyone is all that is needed: the record is popped here, so nobody
  // is left registered, and each receiver raises `ChannelClosed` when it runs.
  while self.readers.pop_front() is Some(reader) {
    match reader {
      Recv(coroutine, value=_) => coroutine.schedule()
      RecvTo({ state: Pending, coroutine, .. } as selected) => {
        selected.state = Closed
        selected.closed_error = Some(ChannelClosed)
        if coroutine is Some(coroutine) {
          coroutine.schedule()
        }
      }
      // The mapped case's closure owns the selector; `None` tells it "closed".
      // A case that lost the race (already `Completed`) ignores it, so a value
      // that was delivered first still wins.
      RecvMapTo(func) => func(None) |> ignore()
      _ => continue
    }
  }
}

///|
pub fn[T] Channel::recv_to(
  self : Channel[T],
  selected : @select.Selector[T],
) -> Unit {
  guard selected.state is Pending else { return }
  if self.values.pop_front() is Some(value) {
    selected.state = Completed
    selected.value = Some(value)
    return
  }
  if self.closed {
    selected.state = Closed
    selected.closed_error = Some(ChannelClosed)
    return
  }
  self.readers.push_back(RecvTo(selected))
}

///|
pub fn[T, R] Channel::recv_map_to(
  self : Channel[T],
  selected : @select.Selector[R],
  f : (T) -> R raise,
) -> Unit raise {
  guard selected.state is Pending else { return }
  if self.values.pop_front() is Some(value) {
    selected.state = Completed
    selected.value = Some(f(value))
    return
  }
  if self.closed {
    selected.state = Closed
    return
  }
  // `None` means "this channel closed": the same closure serves both events, so
  // a mapped case costs exactly one allocation, like an unmapped one.
  self.readers.push_back(
    RecvMapTo(event => {
      guard selected.state is Pending else { false }
      match event {
        None => {
          selected.state = Closed
          selected.closed_error = Some(ChannelClosed)
          if selected.coroutine is Some(coroutine) {
            coroutine.schedule()
          }
          true
        }
        Some(value) => {
          selected.state = Completed
          if selected.coroutine is Some(coroutine) {
            coroutine.schedule()
          }
          selected.thunk = Some(() => f(value))
          true
        }
      }
    }),
  )
}

///|
pub fn[T] Channel::recv(self : Channel[T]) -> T raise {
  if self.values.pop_front() is Some(value) {
    return value
  }
  if self.closed {
    raise ChannelClosed
  }
  let reader = Recv(@coroutine.current(), value=None)
  self.readers.push_back(reader)
  @coroutine.suspend()
  if reader is Recv(_, value~) && value is Some(value) {
    return value
  }
  // `close` pops the record and wakes us; nothing else can wake a receiver
  // without a value.
  guard self.closed else {
    abort("@tonyfettes/co: recv woke up but no value available")
  }
  raise ChannelClosed
}
