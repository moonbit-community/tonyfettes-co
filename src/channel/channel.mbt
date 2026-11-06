///|
struct Channel[T] {
  buffer : FixedArray[T?]
  mut head : Int32
  mut length : Int32
  receivers : @ring.Ring[Receiver[T]]
  senders : @ring.Ring[Sender[T]]
  mut closed : Error?
}

///|
priv enum Receiver[T] {
  Recv(@coroutine.Coroutine, mut value~ : T?)
  RecvTo(@select.Selector[T])
  RecvMapTo((T?, Error?) -> Claim)
}

///|
priv enum Claim {
  Taken
  Declined
  Polling
}

///|
priv enum Sender[T] {
  Send(@coroutine.Coroutine, T, mut sent~ : Bool)
  SendTo(T, @select.Selector[Unit])
  SendMapTo(T, (Error?) -> Claim)
}

///|
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
pub fn[T] Channel::send(self : Channel[T], value : T) -> Unit raise {
  if self.closed is Some(error) {
    raise error
  }
  if self.try_send(value) {
    return
  }
  let sender = Send(@coroutine.current(), value, sent=false)
  self.senders.push_back(sender)
  @coroutine.suspend()
  if sender is Send(_, _, sent=true) {
    return
  }
  if self.closed is Some(error) {
    raise error
  }
  abort("@tonyfettes/co/channel: send woke up but the value was not taken")
}

///|
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
        selector.thunk = Some(() => raise error)
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
        selector.thunk = Some(() => raise error)
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
    selector.thunk = Some(() => raise error)
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
    selector.value = Some(f(value)) catch {
      error => {
        selector.thunk = Some(() => raise error)
        None
      }
    }
    return
  }
  if self.closed is Some(error) {
    selector.completed = true
    selector.thunk = Some(() => raise error)
    return
  }
  self.receivers.push_back(
    RecvMapTo((value, error) => {
      guard !selector.completed else { Declined }
      guard error is Some(_) || selector.coroutine is Some(_) else { Polling }
      selector.completed = true
      if selector.coroutine is Some(coroutine) {
        coroutine.schedule()
      }
      if value is Some(value) {
        selector.thunk = Some(() => f(value))
      } else if error is Some(error) {
        selector.thunk = Some(() => raise error)
      }
      Taken
    }),
  )
}

///|
pub fn[T] Channel::send_to(
  self : Channel[T],
  selector : @select.Selector[Unit],
  value : T,
) -> Unit {
  guard !selector.completed else { return }
  if self.closed is Some(error) {
    selector.completed = true
    selector.thunk = Some(() => raise error)
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
pub fn[T, R] Channel::send_map_to(
  self : Channel[T],
  selector : @select.Selector[R],
  value : T,
  f : () -> R raise,
) -> Unit {
  guard !selector.completed else { return }
  if self.closed is Some(error) {
    selector.completed = true
    selector.thunk = Some(() => raise error)
    return
  }
  if self.try_send(value) {
    selector.completed = true
    selector.value = Some(f()) catch {
      error => {
        selector.thunk = Some(() => raise error)
        None
      }
    }
    return
  }
  self.senders.push_back(
    SendMapTo(value, error => {
      guard !selector.completed else { Declined }
      guard error is Some(_) || selector.coroutine is Some(_) else { Polling }
      selector.completed = true
      if selector.coroutine is Some(coroutine) {
        coroutine.schedule()
      }
      if error is Some(error) {
        selector.thunk = Some(() => raise error)
      } else {
        selector.thunk = Some(f)
      }
      Taken
    }),
  )
}

///|
fn[T] Channel::try_send(self : Channel[T], value : T) -> Bool {
  while self.receivers.pop_front() is Some(receiver) {
    match receiver {
      Recv(coroutine, ..) as receiver => {
        receiver.value = Some(value)
        coroutine.schedule()
        return true
      }
      RecvTo({ completed: false, coroutine: None, .. }) as receiver => {
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
      _ => continue
    }
  }
  guard self.length < self.buffer.length() else { return false }
  self.push_value(value)
  true
}

///|
fn[T] Channel::try_recv(self : Channel[T]) -> T? {
  let value = while self.senders.pop_front() is Some(sender) {
    match sender {
      Send(coroutine, value, ..) as sender => {
        sender.sent = true
        coroutine.schedule()
        break Some(value)
      }
      SendTo(_, { completed: false, coroutine: None, .. }) as sender => {
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
  guard self.length > 0 else { return value }
  let buffered = self.pop_value()
  if value is Some(value) {
    self.push_value(value)
  }
  Some(buffered)
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
