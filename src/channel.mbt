///|
struct Channel[T] {
  values : @deque.Deque[T]
  readers : @deque.Deque[Task]
}

///|
pub fn[T] Channel::new() -> Channel[T] {
  Channel::{ values: @deque.Deque::new(), readers: @deque.Deque::new() }
}

///|
pub fn[T] Channel::send(self : Channel[T], value : T) -> Unit {
  self.values.push_back(value)
  if self.readers.pop_front() is Some(reader) {
    reader.schedule()
  }
}

///|
pub fn[T] Channel::recv(self : Channel[T]) -> T {
  if self.values.pop_front() is Some(value) {
    return value
  }
  let routine = Task::current()
  self.readers.push_back(routine)
  Task::suspend()
  guard self.values.pop_front() is Some(value) else {
    abort("@tonyfettes/co: recv woke up but no value available")
  }
  value
}
