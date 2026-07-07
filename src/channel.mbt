///|
struct Channel[T] {
  values : @deque.Deque[T]
  readers : @deque.Deque[Reader[T]]
}

///|
priv enum Reader[T] {
  Receiver(@coroutine.Coroutine, mut value~ : T?)
  Pollable((T) -> Bool)
}

///|
pub fn[T] Channel::new() -> Channel[T] {
  Channel::{ values: @deque.Deque([]), readers: @deque.Deque([]) }
}

///|
pub fn[T] Channel::send(self : Channel[T], value : T) -> Unit {
  while self.readers.pop_front() is Some(reader) {
    match reader {
      Receiver(coroutine, value=_) as receiver => {
        receiver.value = Some(value)
        coroutine.schedule()
        break
      }
      Pollable(func) => if func(value) { break } else { continue }
    }
  } nobreak {
    self.values.push_back(value)
  }
}

///|
pub fn[T, R] Channel::on_recv(self : Channel[T], f : (T) -> R) -> Pollable[R] {
  Pollable(selected => {
    if self.values.pop_front() is Some(value) {
      if selected.claim() is Some(claim) {
        claim.resolve(f(value))
      }
      return
    }
    let coroutine = @coroutine.current()
    self.readers.push_back(
      Pollable(val => {
        if selected.claim() is Some(claim) {
          claim.deferred(() => f(val))
          coroutine.schedule()
          true
        } else {
          false
        }
      }),
    )
  })
}

///|
pub fn[T] Channel::recv(self : Channel[T]) -> T {
  if self.values.pop_front() is Some(value) {
    return value
  }
  let reader = Receiver(@coroutine.current(), value=None)
  self.readers.push_back(reader)
  @coroutine.suspend()
  guard reader is Receiver(_, value~) && value is Some(value) else {
    abort("@tonyfettes/co: recv woke up but no value available")
  }
  value
}
