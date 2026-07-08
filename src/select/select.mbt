///|
pub(all) struct Selector[T] {
  mut coroutine : @coroutine.Coroutine?
  mut completed : Bool
  mut value : T?
  mut thunk : (() -> T)?
}

///|
pub fn[T] Selector::Selector() -> Selector[T] {
  { coroutine: None, completed: false, value: None, thunk: None }
}

///|
pub fn[T] Selector::wait(self : Selector[T]) -> T {
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
pub fn[R] select(f : (Selector[R]) -> Unit) -> R {
  let selector = Selector()
  f(selector)
  selector.wait()
}
