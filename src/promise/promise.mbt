///|
/// The outcome of a computation that either produces a `T` or fails with an
/// `E`, settled once and awaited by any number of coroutines.
///
/// The outcome is kept in two fields rather than a `Result`, so settling does
/// not allocate. Most promises are awaited by a single coroutine, so the first
/// waiter has a dedicated slot and only further waiters allocate an array.
struct Promise[T, E] {
  mut value : T?
  mut error : E?
  mut waiter : @coroutine.Coroutine?
  mut more_waiters : Array[@coroutine.Coroutine]?
}

///|
pub fn[T, E] Promise::new() -> Promise[T, E] {
  { value: None, error: None, waiter: None, more_waiters: None, }
}

///|
/// Settle the promise with `value` and wake every waiter.
///
/// Aborts if the promise is already settled.
pub fn[T, E] Promise::resolve(self : Promise[T, E], value : T) -> Unit {
  self.check_unsettled()
  self.value = Some(value)
  self.wake()
}

///|
/// Settle the promise with `error` and wake every waiter.
///
/// Aborts if the promise is already settled.
pub fn[T, E] Promise::reject(self : Promise[T, E], error : E) -> Unit {
  self.check_unsettled()
  self.error = Some(error)
  self.wake()
}

///|
/// Wait for the promise to settle: return its value, or raise its error.
pub fn[T, E : Error] Promise::wait(self : Promise[T, E]) -> T raise E {
  if self.value is Some(value) {
    return value
  }
  if self.error is Some(error) {
    raise error
  }
  let current = @coroutine.current()
  if self.waiter is None {
    self.waiter = Some(current)
  } else if self.more_waiters is Some(more_waiters) {
    more_waiters.push(current)
  } else {
    self.more_waiters = Some([current])
  }
  @coroutine.suspend()
  if self.value is Some(value) {
    return value
  }
  if self.error is Some(error) {
    raise error
  }
  abort("@tonyfettes/co/promise: wait woke up but the promise is not settled")
}

///|
/// Run `f` in a new coroutine and return a promise of its outcome.
pub fn[T, E : Error] spawn(f : () -> T raise E) -> Promise[T, E] {
  let promise = Promise::new()
  ignore(
    @coroutine.Coroutine(() => {
      try f() catch {
        error => promise.reject(error)
      } noraise {
        value => promise.resolve(value)
      }
    }),
  )
  promise
}

///|
fn[T, E] Promise::check_unsettled(self : Promise[T, E]) -> Unit {
  if self.value is Some(_) || self.error is Some(_) {
    abort("@tonyfettes/co/promise: promise settled twice")
  }
}

///|
/// Wake every waiter, detaching them first so the promise doesn't keep the
/// woken coroutines referenced.
fn[T, E] Promise::wake(self : Promise[T, E]) -> Unit {
  if self.waiter is Some(waiter) {
    self.waiter = None
    waiter.schedule()
  }
  if self.more_waiters is Some(more_waiters) {
    self.more_waiters = None
    for waiter in more_waiters {
      waiter.schedule()
    }
  }
}
