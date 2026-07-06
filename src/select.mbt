///|
pub(all) struct Pollable[T]((Selected[T]) -> Unit)

///|
priv enum SelectedState[T] {
  Available
  Claimed
  Occupied(T)
}

///|
struct Selected[T] {
  mut state : SelectedState[T]
}

///|
fn[T] Selected::Selected() -> Selected[T] {
  { state: Available }
}

///|
struct Claim[T](Selected[T])

///|
pub fn[T] Claim::set(self : Claim[T], value : T) -> Unit {
  self.0.state = Occupied(value)
}

///|
pub fn[T] Selected::claim(self : Selected[T]) -> Claim[T]? {
  match self.state {
    Available => {
      self.state = Claimed
      Some(self)
    }
    Claimed | Occupied(_) => None
  }
}

///|
pub fn[R] select(pollables : Array[Pollable[R]]) -> R {
  let selected = Selected()
  for pollable in pollables {
    pollable(selected)
    if selected.state is Occupied(value) {
      return value
    }
  }
  Task::suspend()
  guard selected.state is Occupied(value) else {
    abort("@tonyfettes/co: select woke up without value")
  }
  value
}
