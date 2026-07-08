///|
struct Future[T] {
  mut value : T?
  waiters : Array[Waiter[T]]
}

///|
priv enum Waiter[T] {
  Wait(@coroutine.Coroutine)
  WaitTo(@select.Selector[T])
  WaitMapTo((T) -> Unit)
}

///|
pub fn[T] Future::new() -> Future[T] {
  Future::{ value: None, waiters: Array::new() }
}

///|
pub fn[T] Future::set(self : Future[T], value : T) -> Unit {
  self.value = Some(value)
  for waiter in self.waiters {
    match waiter {
      Wait(coroutine) => coroutine.schedule()
      WaitTo({ completed: false, coroutine, .. } as selector) => {
        selector.completed = true
        selector.value = Some(value)
        if coroutine is Some(coroutine) {
          coroutine.schedule()
        }
      }
      WaitMapTo(func) => func(value)
      _ => continue
    }
  }
  self.waiters.clear()
}

///|
pub fn[T] Future::wait(self : Future[T]) -> T {
  if self.value is Some(value) {
    return value
  }
  self.waiters.push(Wait(@coroutine.current()))
  @coroutine.suspend()
  guard self.value is Some(value) else {
    abort("@tonyfettes/co: wait woke up but no value available")
  }
  value
}

///|
pub fn[T] Future::wait_to(
  self : Future[T],
  selector : @select.Selector[T],
) -> Unit {
  guard !selector.completed else { return }
  if self.value is Some(value) {
    selector.completed = true
    selector.value = Some(value)
    return
  }
  self.waiters.push(WaitTo(selector))
}

///|
pub fn[T, R] Future::wait_map_to(
  self : Future[T],
  selector : @select.Selector[R],
  f : (T) -> R,
) -> Unit {
  guard !selector.completed else { return }
  if self.value is Some(value) {
    selector.completed = true
    selector.value = Some(f(value))
    return
  }
  self.waiters.push(
    WaitMapTo(value => {
      guard !selector.completed else { return }
      selector.completed = true
      if selector.coroutine is Some(coroutine) {
        coroutine.schedule()
      }
      selector.thunk = Some(() => f(value))
    }),
  )
}
