///|
pub(all) struct Pollable[T]((Selected[T]) -> Unit)

///|
priv enum SelectedState[T] {
  Available
  Claimed
  Occupied(T)
  Deferred(() -> T)
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
pub fn[T] Claim::resolve(self : Claim[T], value : T) -> Unit {
  self.0.state = Occupied(value)
}

///|
pub fn[T] Claim::deferred(self : Claim[T], thunk : () -> T) -> Unit {
  self.0.state = Deferred(thunk)
}

///|
pub fn[T] Selected::claim(self : Selected[T]) -> Claim[T]? {
  match self.state {
    Available => {
      self.state = Claimed
      Some(self)
    }
    Claimed | Occupied(_) | Deferred(_) => None
  }
}

///|
pub fn[R] select(pollables : Array[Pollable[R]]) -> R {
  let selected = Selected()
  for pollable in pollables {
    pollable(selected)
    match selected.state {
      Occupied(value) => return value
      Deferred(thunk) => return thunk()
      Available | Claimed => continue
    }
  }
  @coroutine.suspend()
  match selected.state {
    Occupied(value) => return value
    Deferred(thunk) => return thunk()
    Available | Claimed => abort("@tonyfettes/co: select woke up without value")
  }
}
