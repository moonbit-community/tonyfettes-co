///|
pub(all) struct Selector[T] {
  mut coroutine : @coroutine.Coroutine?
  mut completed : Bool
  mut value : T?
  // Computes the completed case's outcome once `wait` resumes: applies its
  // mapper, or raises the error it failed with (e.g. its channel's close
  // error).
  mut thunk : (() -> T raise)?
}

///|
pub fn[T] Selector::Selector() -> Selector[T] {
  { coroutine: None, completed: false, value: None, thunk: None, }
}

///|
/// The outcome of the completed case: its value, or the error it failed with.
fn[T] Selector::outcome(self : Selector[T]) -> T? raise {
  if self.value is Some(value) {
    return Some(value)
  }
  if self.thunk is Some(thunk) {
    let value = thunk()
    self.value = Some(value)
    return Some(value)
  }
  None
}

///|
/// Wait for the first case to complete and return its value, or raise the
/// error it failed with (for a channel case, the channel's close error).
pub fn[T] Selector::wait(self : Selector[T]) -> T raise {
  if self.outcome() is Some(value) {
    return value
  }
  self.coroutine = Some(@coroutine.current())
  @coroutine.suspend()
  if self.outcome() is Some(value) {
    return value
  }
  abort("@tonyfettes/co/select: Selector woke up without value")
}

///|
#locals(f)
pub fn[R] select(f : (Selector[R]) -> Unit) -> R raise {
  let selector = Selector()
  f(selector)
  selector.wait()
}
