///|
pub struct Future[T] {
  priv chan : Channel[T]
}

///|
#callsite(autofill(loc))
pub fn[T] Future::new(
  loc~ : SourceLoc,
  name? : String = loc.to_string(),
  stack_size? : UInt64 = 65536,
  f : () -> T,
) -> Future[T] {
  let chan : Channel[T] = Channel::new()
  create(loc~, name~, stack_size~, () => chan.send(f()))
  Future::{ chan, }
}

///|
pub fn[T] Future::wait(self : Future[T]) -> T {
  self.chan.recv()
}
