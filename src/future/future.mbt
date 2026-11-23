///|
struct Future[T] {
  mut value : T?
  waiters : Array[@coroutine.Coroutine]
  selectors : Array[@select.Registration]
}

///|
pub fn[T] Future::new() -> Future[T] {
  Future::{ value: None, waiters: Array(), selectors: Array(), }
}

///|
pub fn[T] Future::set(self : Future[T], value : T) -> Unit {
  self.value = Some(value)
  for waiter in self.waiters {
    waiter.schedule()
  }
  self.waiters.clear()
  for reg in self.selectors {
    ignore(reg.notify())
  }
  self.selectors.clear()
}

///|
pub fn[T] Future::wait(self : Future[T]) -> T {
  if self.value is Some(value) {
    return value
  }
  self.waiters.push(@coroutine.current())
  @coroutine.suspend()
  guard self.value is Some(value) else {
    abort("@tonyfettes/co: wait woke up but no value available")
  }
  value
}

///|
pub fn[T] Future::wait_to(
  self : Future[T],
  selector : @select.Selector,
) -> Unit {
  guard !selector.is_ready() else { return }
  let id = selector.next_id()
  if self.value is Some(_) {
    ignore(selector.notify(id))
    return
  }
  self.selectors.push(selector.register(id))
}
