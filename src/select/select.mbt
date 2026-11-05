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
/// Whether the select is still polling its cases: not completed, and `wait`
/// has not started waiting. Its cases may already be queued on channels, but
/// no sibling case may take them (a send and a receive on one channel).
pub fn[T] Selector::is_polling(self : Selector[T]) -> Bool {
  !self.completed && self.coroutine is None
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
