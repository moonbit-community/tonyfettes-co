///|
/// A growable FIFO ring buffer whose `pop_front` clears the vacated slot.
///
/// `@deque.Deque::pop_front` keeps referring to a removed element from its
/// old slot until the slot is reused, so a queue of parked waiters would keep
/// a woken waiter's record (and the coroutine, selector or closure in it)
/// alive. It is also a call into core that the C compiler doesn't inline;
/// these methods are small enough to be.
struct Ring[T] {
  mut buf : FixedArray[T?]
  mut head : Int32
  mut len : Int32
}

///|
pub fn[T] Ring::Ring() -> Ring[T] {
  { buf: [], head: 0, len: 0, }
}

///|
pub fn[T] Ring::length(self : Ring[T]) -> Int32 {
  self.len
}

///|
pub fn[T] Ring::is_empty(self : Ring[T]) -> Bool {
  self.len == 0
}

///|
pub fn[T] Ring::push_back(self : Ring[T], value : T) -> Unit {
  if self.len == self.buf.length() {
    self.grow()
  }
  let capacity = self.buf.length()
  let tail = self.head + self.len
  self.buf[if tail >= capacity { tail - capacity } else { tail }] = Some(value)
  self.len += 1
}

///|
pub fn[T] Ring::push_front(self : Ring[T], value : T) -> Unit {
  if self.len == self.buf.length() {
    self.grow()
  }
  let head = if self.head == 0 { self.buf.length() - 1 } else { self.head - 1 }
  self.buf[head] = Some(value)
  self.head = head
  self.len += 1
}

///|
pub fn[T] Ring::pop_front(self : Ring[T]) -> T? {
  guard self.len > 0 else { return None }
  let value = self.buf[self.head]
  self.buf[self.head] = None
  let next = self.head + 1
  self.head = if next == self.buf.length() { 0 } else { next }
  self.len -= 1
  value
}

///|
fn[T] Ring::grow(self : Ring[T]) -> Unit {
  let old = self.buf
  let capacity = old.length()
  let buf : FixedArray[T?] = FixedArray::make(
    if capacity == 0 {
      8
    } else {
      capacity * 2
    },
    None,
  )
  for i in 0..<self.len {
    let index = self.head + i
    buf[i] = old[if index >= capacity { index - capacity } else { index }]
  }
  self.buf = buf
  self.head = 0
}
