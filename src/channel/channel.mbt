///|
priv struct Reader[T] {
  coroutine : @coroutine.Coroutine
  mut value : T?
}

///|
priv struct Writer[T] {
  coroutine : @coroutine.Coroutine
  value : T
  mut sent : Bool
}

///|
struct Channel[T] {
  capacity : Int32
  values : @deque.Deque[T]
  readers : @deque.Deque[Reader[T]]
  writers : @deque.Deque[Writer[T]]
  recv_selectors : @deque.Deque[@select.Registration]
  send_selectors : @deque.Deque[@select.Registration]
}

///|
pub fn[T] Channel::Channel(capacity : Int32) -> Channel[T] {
  if capacity < 0 {
    abort("@tonyfettes/co/channel: capacity must be non-negative")
  }
  Channel::{
    capacity,
    values: @deque.Deque([]),
    readers: @deque.Deque([]),
    writers: @deque.Deque([]),
    recv_selectors: @deque.Deque([]),
    send_selectors: @deque.Deque([]),
  }
}

///|
fn notify_one(queue : @deque.Deque[@select.Registration]) -> Bool {
  while queue.pop_front() is Some(reg) {
    if reg.notify() {
      return true
    }
  }
  false
}

///|
fn notify_other(
  queue : @deque.Deque[@select.Registration],
  self_selector : @select.Selector,
) -> Bool {
  let n = queue.length()
  for _ in 0..<n {
    guard queue.pop_front() is Some(reg) else { break }
    if reg.is_ready() {
      continue
    }
    if reg.belongs_to(self_selector) {
      queue.push_back(reg)
      continue
    }
    if reg.notify() {
      return true
    }
  }
  false
}

///|
pub fn[T] Channel::send(self : Channel[T], value : T) -> Unit {
  if self.readers.pop_front() is Some(reader) {
    reader.value = Some(value)
    reader.coroutine.schedule()
    return
  }
  if self.values.length() < self.capacity {
    self.values.push_back(value)
    if !self.recv_selectors.is_empty() {
      ignore(notify_one(self.recv_selectors))
    }
    return
  }
  let writer = Writer::{ coroutine: @coroutine.current(), value, sent: false, }
  self.writers.push_back(writer)
  if !self.recv_selectors.is_empty() {
    ignore(notify_one(self.recv_selectors))
  }
  @coroutine.suspend()
  guard writer.sent else {
    abort("@tonyfettes/co/channel: send woke up before value was received")
  }
}

///|
pub fn[T] Channel::recv(self : Channel[T]) -> T {
  if self.values.pop_front() is Some(value) {
    if self.writers.pop_front() is Some(writer) {
      writer.sent = true
      writer.coroutine.schedule()
      self.values.push_back(writer.value)
    } else if !self.send_selectors.is_empty() {
      ignore(notify_one(self.send_selectors))
    }
    return value
  }
  if self.writers.pop_front() is Some(writer) {
    writer.sent = true
    writer.coroutine.schedule()
    return writer.value
  }
  let reader = Reader::{ coroutine: @coroutine.current(), value: None, }
  self.readers.push_back(reader)
  if !self.send_selectors.is_empty() {
    ignore(notify_one(self.send_selectors))
  }
  @coroutine.suspend()
  guard reader.value is Some(value) else {
    abort("@tonyfettes/co/channel: recv woke up but no value available")
  }
  value
}

///|
pub fn[T] Channel::recv_to(
  self : Channel[T],
  selector : @select.Selector,
) -> Unit {
  guard !selector.is_ready() else { return }
  let id = selector.next_id()
  if self.values.length() > 0 ||
    self.writers.length() > 0 ||
    notify_other(self.send_selectors, selector) {
    ignore(selector.notify(id))
    return
  }
  self.recv_selectors.push_back(selector.register(id))
}

///|
pub fn[T] Channel::send_to(
  self : Channel[T],
  selector : @select.Selector,
) -> Unit {
  guard !selector.is_ready() else { return }
  let id = selector.next_id()
  if self.readers.length() > 0 || notify_other(self.recv_selectors, selector) {
    ignore(selector.notify(id))
    return
  }
  if self.values.length() < self.capacity {
    ignore(selector.notify(id))
    self.recv_selectors.clear()
    return
  }
  self.send_selectors.push_back(selector.register(id))
}
