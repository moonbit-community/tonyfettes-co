///|
/// State of a select case.
///
/// This is a payload-less enum on purpose: it compiles to a single `int32` slot,
/// so writing it costs one store and never allocates (a *payload-carrying* enum
/// would be a heap object with an allocation per transition). The value itself
/// stays in `Selector::value`, which is an unboxed `T?`.
pub(all) enum SelectorState {
  /// Nobody has claimed this case yet.
  Pending
  /// A value (or a deferred `thunk`) has been delivered to this case.
  Completed
  /// The thing being waited on is closed: there will never be a value.
  Closed
}

///|
pub(all) struct Selector[T] {
  mut coroutine : @coroutine.Coroutine?
  mut state : SelectorState
  mut value : T?
  mut thunk : (() -> T raise)?
  // What "closed" means for this case, planted by whoever registered it (a
  // channel plants `ChannelClosed`). Selecting is a mechanism; the case owner
  // decides how its end-of-stream is reported. `select` cannot name a channel
  // error itself without depending on the channel package.
  mut closed_error : Error?
}

///|
pub fn[T] Selector::Selector() -> Selector[T] {
  {
    coroutine: None,
    state: Pending,
    value: None,
    thunk: None,
    closed_error: None,
  }
}

///|
pub fn[T] Selector::wait(self : Selector[T]) -> T raise {
  if self.value is Some(value) {
    return value
  }
  if self.thunk is Some(thunk) {
    let value = thunk()
    self.value = Some(value)
    return value
  }
  self.coroutine = Some(@coroutine.current())
  @coroutine.suspend()
  // The waker set exactly one of these; a `Closed` case is the analogue of EOF.
  if self.state is Closed {
    guard self.closed_error is Some(error) else {
      abort("@tonyfettes/co/select: case closed without an error to report")
    }
    raise error
  }
  if self.value is Some(value) {
    return value
  }
  if self.thunk is Some(thunk) {
    let value = thunk()
    self.value = Some(value)
    return value
  }
  abort("@tonyfettes/co/select: Selector woke up without value")
}

///|
#locals(f)
pub fn[R] select(f : (Selector[R]) -> Unit raise) -> R raise {
  let selector = Selector()
  f(selector)
  selector.wait()
}
