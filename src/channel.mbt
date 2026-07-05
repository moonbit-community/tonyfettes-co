///|
struct Channel[T] {
  values : @deque.Deque[T]
  readers : @deque.Deque[Reader[T]]
}

///|
priv enum Reader[T] {
  Receiver(Task, mut value~ : T?)
  Pollable((T) -> Bool)
}

///|
pub fn[T] Channel::new() -> Channel[T] {
  Channel::{ values: @deque.Deque([]), readers: @deque.Deque([]) }
}

///|
pub fn[T] Channel::send(self : Channel[T], value : T) -> Unit {
  while self.readers.pop_front() is Some(reader) {
    match reader {
      Receiver(task, value=_) as receiver => {
        receiver.value = Some(value)
        task.schedule()
        break
      }
      Pollable(func) => if func(value) { break } else { continue }
    }
  } nobreak {
    self.values.push_back(value)
  }
}

///|
pub fn[T, R] Channel::on_recv(self : Channel[T], f : (T) -> R) -> Pollable[R] {
  {
    poll: () => self.values.pop_front().map(value => f(value)),
    register: box => {
      let task = Task::current()
      self.readers.push_back(
        Pollable(val => {
          box.try_set(() => {
            let val = f(val)
            task.schedule()
            val
          })
        }),
      )
    },
  }
}

///|
pub fn[T] Channel::recv(self : Channel[T]) -> T {
  if self.values.pop_front() is Some(value) {
    return value
  }
  let reader = Receiver(Task::current(), value=None)
  self.readers.push_back(reader)
  Task::suspend()
  guard reader is Receiver(_, value~) && value is Some(value) else {
    abort("@tonyfettes/co: recv woke up but no value available")
  }
  value
}
