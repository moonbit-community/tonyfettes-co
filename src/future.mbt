///|
struct Future[T] {
  mut value : T?
  waiter : Array[Task]
}

///|
#callsite(autofill(loc))
pub fn[T] Future::new(
  loc~ : SourceLoc,
  name? : String = loc.to_string(),
  stack_size? : UInt64 = 65536,
  f : () -> T,
) -> Future[T] {
  let future = Future::{ value: None, waiter: [] }
  launch(loc~, name~, stack_size~, () => {
    future.value = Some(f())
    for task in future.waiter {
      task.schedule()
    }
    future.waiter.clear()
  })
  future
}

///|
pub fn[T] Future::wait(self : Future[T]) -> T {
  if self.value is Some(value) {
    return value
  }
  self.waiter.push(Task::current())
  Task::suspend()
  guard self.value is Some(value) else {
    abort("@tonyfettes/co: wait woke up but no value available")
  }
  value
}
