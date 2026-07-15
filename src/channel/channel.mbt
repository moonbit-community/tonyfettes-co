///|
struct Channel[T] {
  values : @deque.Deque[T]
  readers : @deque.Deque[Reader[T]]
}

///|
priv enum Reader[T] {
  Recv(@coroutine.Coroutine, mut value~ : T?)
  RecvTo(@select.Selector[T])
  RecvMapTo((T) -> Bool)
}

///|
pub fn[T] Channel::new() -> Channel[T] {
  Channel::{ values: @deque.Deque([]), readers: @deque.Deque([]) }
}

///|
pub fn[T] Channel::send(self : Channel[T], value : T) -> Unit {
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
  let reader = Recv(@coroutine.current(), value=None)
  self.readers.push_back(reader)
  @coroutine.suspend()
  guard reader is Recv(_, value~) && value is Some(value) else {
    abort("@tonyfettes/co: recv woke up but no value available")
  }
  value
}
