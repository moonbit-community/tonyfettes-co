///|
struct Pollable[T] {
  poll : () -> T?
  register : (Selected[T]) -> Unit
}

///|
pub fn[T] Pollable::Pollable(
  poll? : () -> T? = () => None,
  register~ : (Selected[T]) -> Unit,
) -> Pollable[T] {
  Pollable::{ poll, register }
}

///|
struct Selected[T] {
  mut value : T?
}

///|
fn[T] Selected::Selected() -> Selected[T] {
  { value: None }
}

///|
#locals(f)
pub fn[T] Selected::try_set(self : Selected[T], f : () -> T) -> Bool {
  if self.value is Some(_) {
    false
  } else {
    self.value = Some(f())
    true
  }
}

///|
pub fn[R] select(pollables : Array[Pollable[R]]) -> R {
  for pollable in pollables {
    if (pollable.poll)() is Some(value) {
      return value
    }
  }
  let selected = Selected()
  for pollable in pollables {
    (pollable.register)(selected)
    guard selected.value is None else {
      abort(
        "@tonyfettes/co: selected is set during registration",
      )
    }
  }
  Task::suspend()
  guard selected.value is Some(value) else {
    abort("@tonyfettes/co: select woke up without value")
  }
  value
}
