///|
pub struct Selector {
  mut coroutine : @coroutine.Coroutine?
  mut count : Int32
  mut ready : Int32
}

///|
pub struct Registration {
  selector : Selector
  id : Int32
}

///|
pub fn Selector::Selector() -> Selector {
  { coroutine: None, count: 0, ready: -1, }
}

///|
pub fn Selector::is_ready(self : Selector) -> Bool {
  self.ready >= 0
}

///|
pub fn Selector::next_id(self : Selector) -> Int32 {
  let id = self.count
  self.count += 1
  id
}

///|
pub fn Selector::register(self : Selector, id : Int32) -> Registration {
  { selector: self, id, }
}

///|
pub fn Selector::notify(self : Selector, id : Int32) -> Bool {
  guard self.ready < 0 else { return false }
  self.ready = id
  if self.coroutine is Some(coroutine) {
    coroutine.schedule()
  }
  true
}

///|
pub fn Registration::is_ready(self : Registration) -> Bool {
  self.selector.ready >= 0
}

///|
pub fn Registration::belongs_to(
  self : Registration,
  selector : Selector,
) -> Bool {
  physical_equal(self.selector, selector)
}

///|
pub fn Registration::notify(self : Registration) -> Bool {
  self.selector.notify(self.id)
}

///|
pub fn Selector::wait(self : Selector) -> Int32 {
  if self.ready >= 0 {
    return self.ready
  }
  self.coroutine = Some(@coroutine.current())
  @coroutine.suspend()
  if self.ready >= 0 {
    return self.ready
  }
  abort("@tonyfettes/co/select: Selector woke up without ready case")
}

///|
#locals(f)
pub fn select(f : (Selector) -> Unit) -> Int32 {
  let selector = Selector()
  f(selector)
  selector.wait()
}
