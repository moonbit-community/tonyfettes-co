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
  RecvMapTo((T) -> Bool)
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
      RecvTo({ completed: false, coroutine, .. } as selected) => {
        selected.completed = true
        if coroutine is Some(coroutine) {
          coroutine.schedule()
        }
        selected.value = Some(value)
        break
      }
      RecvMapTo(func) if func(value) => break
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
      // TODO: `select` cases (`RecvTo`/`RecvMapTo`) are not signalled yet. The
      // mapped ones hide the selector behind a closure, so `Selector` needs its
      // own "closed" state before they can be woken here.
      _ => continue
    }
  }
}

///|
pub fn[T] Channel::recv_to(
  self : Channel[T],
  selected : @select.Selector[T],
) -> Unit {
  guard !selected.completed else { return }
  if self.values.pop_front() is Some(value) {
    selected.completed = true
    selected.value = Some(value)
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
  guard !selected.completed else { return }
  if self.values.pop_front() is Some(value) {
    selected.completed = true
    selected.value = Some(f(value))
    return
  }
  self.readers.push_back(
    RecvMapTo(value => {
      guard !selected.completed else { false }
      selected.completed = true
      if selected.coroutine is Some(coroutine) {
        coroutine.schedule()
      }
      selected.thunk = Some(() => f(value))
      true
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
