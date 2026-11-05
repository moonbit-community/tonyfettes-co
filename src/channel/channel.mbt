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
  receivers : @deque.Deque[Receiver[T]]
  // Parked senders. Only non-empty while the buffer is full.
  senders : @deque.Deque[Sender[T]]
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
  // than a `Result`, so a wake doesn't allocate). Returns whether the case
  // took it; a case whose `select` already completed declines.
  RecvMapTo((T?, Error?) -> Bool)
}

///|
/// A sender parked on the channel with the value it wants to hand over.
priv struct Sender[T] {
  coroutine : @coroutine.Coroutine
  value : T
  mut delivered : Bool
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
    receivers: @deque.Deque([]),
    senders: @deque.Deque([]),
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
  if self.hand_to_receiver(value) {
    return
  }
  if self.length < self.buffer.length() {
    self.push_buffer(value)
    return
  }
  let sender = { coroutine: @coroutine.current(), value, delivered: false, }
  self.senders.push_back(sender)
  @coroutine.suspend()
  if sender.delivered {
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
  if self.take() is Some(value) {
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
    sender.coroutine.schedule()
  }
}

///|
pub fn[T] Channel::recv_to(
  self : Channel[T],
  selector : @select.Selector[T],
) -> Unit {
  guard !selector.completed else { return }
  if self.take() is Some(value) {
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
  if self.take() is Some(value) {
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
      guard !selector.completed else { false }
      selector.completed = true
      if selector.coroutine is Some(coroutine) {
        coroutine.schedule()
      }
      if value is Some(value) {
        selector.thunk = Some(() => f(value))
      } else if error is Some(error) {
        fail(selector, error)
      }
      true
    }),
  )
}

///|
/// Give `value` directly to a parked receiver, if there is one.
fn[T] Channel::hand_to_receiver(self : Channel[T], value : T) -> Bool {
  // Checked first so the common no-waiter case doesn't call `pop_front`.
  guard !self.receivers.is_empty() else { return false }
  while self.receivers.pop_front() is Some(receiver) {
    match receiver {
      Recv(coroutine, ..) as receiver => {
        receiver.value = Some(value)
        coroutine.schedule()
        return true
      }
      RecvTo({ completed: false, coroutine, .. } as selector) => {
        selector.completed = true
        selector.value = Some(value)
        if coroutine is Some(coroutine) {
          coroutine.schedule()
        }
        return true
      }
      RecvMapTo(func) => if func(Some(value), None) { return true }
      // A case of a `select` that already completed elsewhere.
      _ => continue
    }
  }
  false
}

///|
/// Take the next value without waiting: from the buffer (refilling it from a
/// parked sender), or straight from a parked sender when unbuffered.
fn[T] Channel::take(self : Channel[T]) -> T? {
  if self.length > 0 {
    let value = self.pop_buffer()
    if !self.senders.is_empty() && self.senders.pop_front() is Some(sender) {
      self.push_buffer(sender.value)
      sender.delivered = true
      sender.coroutine.schedule()
    }
    return Some(value)
  }
  if !self.senders.is_empty() && self.senders.pop_front() is Some(sender) {
    sender.delivered = true
    sender.coroutine.schedule()
    return Some(sender.value)
  }
  None
}

///|
fn[T] Channel::push_buffer(self : Channel[T], value : T) -> Unit {
  let capacity = self.buffer.length()
  let tail = self.head + self.length
  let index = if tail >= capacity { tail - capacity } else { tail }
  self.buffer[index] = Some(value)
  self.length += 1
}

///|
fn[T] Channel::pop_buffer(self : Channel[T]) -> T {
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
