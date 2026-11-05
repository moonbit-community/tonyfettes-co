///|
/// A bounded FIFO channel between coroutines, modelled on Go's channels.
///
/// A channel holds at most `capacity` values. With the default capacity 0 it
/// is unbuffered: `send` waits until a receiver takes the value. Senders that
/// find the buffer full and receivers that find it empty park until a partner
/// arrives, so a slow receiver slows its senders down instead of letting values
/// pile up.
///
/// `close(error)` ends the channel. Values already buffered are still
/// delivered; after that `recv` raises `error`, and so does `send`.
struct Channel[T] {
  // Ring buffer of buffered values; its length is the capacity.
  buffer : FixedArray[T?]
  mut head : Int32
  mut length : Int32
  // Parked receivers. Only non-empty while the buffer is empty and no sender
  // is parked.
  receivers : @ring.Ring[Receiver[T]]
  // Parked senders. Only non-empty while the buffer is full.
  senders : @ring.Ring[Sender[T]]
  mut closed : Error?
}

///|
/// A receiver parked on the channel, one record per wait.
priv enum Receiver[T] {
  // The record carries no close error: a receiver woken without a value reads
  // it from the channel, which keeps this per-wait allocation small.
  Recv(@coroutine.Coroutine, mut value~ : T?)
  RecvTo(@select.Selector[T])
  // Called with the value, or with the close error (two arguments rather
  // than a `Result`, so a wake doesn't allocate).
  RecvMapTo((T?, Error?) -> Claim)
}

///|
/// What a `select` case queued on a channel did when offered a partner.
priv enum Claim {
  // It took part, completing its select.
  Taken
  // Its select already completed through another case; drop it.
  Declined
  // Its select is still polling its cases (see `Selector::is_polling`), so
  // the offer comes from a sibling case: keep it queued and look no further,
  // as every entry after it was queued by the same select.
  Polling
}

///|
/// A sender parked on the channel with the value it wants to hand over, one
/// record per wait.
priv enum Sender[T] {
  Send(@coroutine.Coroutine, T, mut delivered~ : Bool)
  SendTo(T, @select.Selector[Unit])
  // A `select` send case with a result of another type. Its callback is
  // called when a receiver takes the value (with `None`) or when the channel
  // is closed (with the error); the value is delivered only if the case is
  // `Taken`.
  SendMapTo(T, (Error?) -> Claim)
}

///|
/// Create a channel that buffers up to `capacity` values (default 0:
/// unbuffered).
pub fn[T] Channel::Channel(capacity~ : Int32 = 0) -> Channel[T] {
  if capacity < 0 {
    abort("@tonyfettes/co/channel: negative capacity \{capacity}")
  }
  {
    buffer: FixedArray::make(capacity, None),
    head: 0,
    length: 0,
    receivers: @ring.Ring(),
    senders: @ring.Ring(),
    closed: None,
  }
}

///|
/// Send `value`, waiting while the buffer is full.
///
/// Raises the close error if the channel is closed, including when it is
/// closed while this send is waiting.
pub fn[T] Channel::send(self : Channel[T], value : T) -> Unit raise {
  if self.closed is Some(error) {
    raise error
  }
  if self.try_send(value) {
    return
  }
  let sender = Send(@coroutine.current(), value, delivered=false)
  self.senders.push_back(sender)
  @coroutine.suspend()
  if sender is Send(_, _, delivered=true) {
    return
  }
  if self.closed is Some(error) {
    raise error
  }
  abort("@tonyfettes/co/channel: send woke up but the value was not taken")
}

///|
/// Receive a value, waiting while none is available.
///
/// Once the channel is closed and its buffer drained, raises the close error.
pub fn[T] Channel::recv(self : Channel[T]) -> T raise {
  if self.try_recv() is Some(value) {
    return value
  }
  if self.closed is Some(error) {
    raise error
  }
  let receiver = Recv(@coroutine.current(), value=None)
  self.receivers.push_back(receiver)
  @coroutine.suspend()
  if receiver is Recv(_, value=Some(value)) {
    return value
  }
  if self.closed is Some(error) {
    raise error
  }
  abort("@tonyfettes/co/channel: recv woke up but no value available")
}

///|
/// Close the channel with `error`.
///
/// Parked receivers and senders are woken and raise `error`. Buffered values
/// are still delivered to later receivers; after them `recv` raises `error`.
/// Closing an already closed channel does nothing: the first error stays.
pub fn[T] Channel::close(self : Channel[T], error : Error) -> Unit {
  if self.closed is Some(_) {
    return
  }
  self.closed = Some(error)
  while self.receivers.pop_front() is Some(receiver) {
    match receiver {
      Recv(coroutine, ..) => coroutine.schedule()
      RecvTo({ completed: false, coroutine, .. } as selector) => {
        selector.completed = true
        fail(selector, error)
        if coroutine is Some(coroutine) {
          coroutine.schedule()
        }
      }
      RecvMapTo(func) => ignore(func(None, Some(error)))
      _ => continue
    }
  }
  while self.senders.pop_front() is Some(sender) {
    match sender {
      Send(coroutine, _, ..) => coroutine.schedule()
      SendTo(_, { completed: false, coroutine, .. } as selector) => {
        selector.completed = true
        fail(selector, error)
        if coroutine is Some(coroutine) {
          coroutine.schedule()
        }
      }
      SendMapTo(_, claim) => ignore(claim(Some(error)))
      _ => continue
    }
  }
}

///|
pub fn[T] Channel::recv_to(
  self : Channel[T],
  selector : @select.Selector[T],
) -> Unit {
  guard !selector.completed else { return }
  if self.try_recv() is Some(value) {
    selector.completed = true
    selector.value = Some(value)
    return
  }
  if self.closed is Some(error) {
    selector.completed = true
    fail(selector, error)
    return
  }
  self.receivers.push_back(RecvTo(selector))
}

///|
pub fn[T, R] Channel::recv_map_to(
  self : Channel[T],
  selector : @select.Selector[R],
  f : (T) -> R raise,
) -> Unit {
  guard !selector.completed else { return }
  if self.try_recv() is Some(value) {
    selector.completed = true
    // A failing mapper fails the select: `wait` raises its error.
    selector.value = Some(f(value)) catch {
      error => {
        fail(selector, error)
        None
      }
    }
    return
  }
  if self.closed is Some(error) {
    selector.completed = true
    fail(selector, error)
    return
  }
  self.receivers.push_back(
    RecvMapTo((value, error) => {
      guard !selector.completed else { Declined }
      guard error is Some(_) || !selector.is_polling() else { Polling }
      selector.completed = true
      if selector.coroutine is Some(coroutine) {
        coroutine.schedule()
      }
      if value is Some(value) {
        selector.thunk = Some(() => f(value))
      } else if error is Some(error) {
        fail(selector, error)
      }
      Taken
    }),
  )
}

///|
/// A `select` case sending `value`; the select's value is `()`.
pub fn[T] Channel::send_to(
  self : Channel[T],
  selector : @select.Selector[Unit],
  value : T,
) -> Unit {
  guard !selector.completed else { return }
  if self.closed is Some(error) {
    selector.completed = true
    fail(selector, error)
    return
  }
  if self.try_send(value) {
    selector.completed = true
    selector.value = Some(())
    return
  }
  self.senders.push_back(SendTo(value, selector))
}

///|
/// A `select` case sending `value`. Once it is sent, the select's value is
/// `f()`; a case that loses the select does not send.
///
/// A closed channel fails the case: the select raises the close error.
pub fn[T, R] Channel::send_map_to(
  self : Channel[T],
  selector : @select.Selector[R],
  value : T,
  f : () -> R raise,
) -> Unit {
  guard !selector.completed else { return }
  if self.closed is Some(error) {
    selector.completed = true
    fail(selector, error)
    return
  }
  if self.try_send(value) {
    selector.completed = true
    selector.value = Some(f()) catch {
      error => {
        fail(selector, error)
        None
      }
    }
    return
  }
  self.senders.push_back(
    SendMapTo(value, error => {
      guard !selector.completed else { Declined }
      guard error is Some(_) || !selector.is_polling() else { Polling }
      selector.completed = true
      if selector.coroutine is Some(coroutine) {
        coroutine.schedule()
      }
      if error is Some(error) {
        fail(selector, error)
      } else {
        selector.thunk = Some(f)
      }
      Taken
    }),
  )
}

///|
/// Send `value` without waiting: to a parked receiver, or into the buffer.
/// Returns whether it was sent.
fn[T] Channel::try_send(self : Channel[T], value : T) -> Bool {
  // Redundant with `pop_front`'s own check, but it keeps the common
  // no-waiter case to one comparison: the C compiler splits the waiter loop
  // off into a separate, non-inlined part (~11 instructions per op in the
  // chan bench without it).
  if !self.receivers.is_empty() {
    while self.receivers.pop_front() is Some(receiver) {
      match receiver {
        Recv(coroutine, ..) as receiver => {
          receiver.value = Some(value)
          coroutine.schedule()
          return true
        }
        // The rest of the queue is the polling select's own cases: none of
        // them may take it, but the buffer still can.
        RecvTo(selector) as receiver if selector.is_polling() => {
          self.receivers.push_front(receiver)
          break
        }
        RecvTo({ completed: false, coroutine, .. } as selector) => {
          selector.completed = true
          selector.value = Some(value)
          if coroutine is Some(coroutine) {
            coroutine.schedule()
          }
          return true
        }
        RecvMapTo(claim) as receiver =>
          match claim(Some(value), None) {
            Taken => return true
            Declined => continue
            Polling => {
              self.receivers.push_front(receiver)
              break
            }
          }
        // A case of a `select` that already completed elsewhere.
        _ => continue
      }
    }
  }
  guard self.length < self.buffer.length() else { return false }
  self.push_value(value)
  true
}

///|
/// Take the next value without waiting: from the buffer (refilling it from a
/// parked sender), or straight from a parked sender when unbuffered.
fn[T] Channel::try_recv(self : Channel[T]) -> T? {
  // Redundant with `pop_front`'s own check, but it keeps the no-waiter case
  // to one comparison, as in `try_send`.
  let from_sender = if self.senders.is_empty() {
    None
  } else {
    while self.senders.pop_front() is Some(sender) {
      match sender {
        Send(coroutine, value, ..) as sender => {
          sender.delivered = true
          coroutine.schedule()
          break Some(value)
        }
        // The rest of the queue is the polling select's own cases.
        SendTo(_, selector) as sender if selector.is_polling() => {
          self.senders.push_front(sender)
          break None
        }
        SendTo(value, { completed: false, coroutine, .. } as selector) => {
          selector.completed = true
          selector.value = Some(())
          if coroutine is Some(coroutine) {
            coroutine.schedule()
          }
          break Some(value)
        }
        // A case of a `select` that already completed elsewhere.
        SendTo(_) => continue
        SendMapTo(value, claim) as sender =>
          match claim(None) {
            Taken => break Some(value)
            Declined => continue
            Polling => {
              self.senders.push_front(sender)
              break None
            }
          }
      }
    } nobreak {
      None
    }
  }
  guard self.length > 0 else { return from_sender }
  // A parked sender means the buffer was full: its value goes in behind the
  // one taken out.
  let value = self.pop_value()
  if from_sender is Some(next) {
    self.push_value(next)
  }
  Some(value)
}

///|
fn[T] Channel::push_value(self : Channel[T], value : T) -> Unit {
  let capacity = self.buffer.length()
  let tail = self.head + self.length
  let index = if tail >= capacity { tail - capacity } else { tail }
  self.buffer[index] = Some(value)
  self.length += 1
}

///|
fn[T] Channel::pop_value(self : Channel[T]) -> T {
  guard self.buffer[self.head] is Some(value) else {
    abort("@tonyfettes/co/channel: empty buffer slot")
  }
  self.buffer[self.head] = None
  let next = self.head + 1
  self.head = if next == self.buffer.length() { 0 } else { next }
  self.length -= 1
  value
}

///|
/// Make `selector`'s `wait` raise `error`. Stored as the thunk so `Selector`
/// needs no error field; the closure is only allocated on this failure path.
fn[R] fail(selector : @select.Selector[R], error : Error) -> Unit {
  selector.thunk = Some(() => raise error)
}
