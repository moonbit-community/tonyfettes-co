///|
struct Channel[T] {
  capacity : Int32
  values : @deque.Deque[T]
  readers : @deque.Deque[Reader[T]]
  writers : @deque.Deque[Writer[T]]
}

///|
priv enum Reader[T] {
  Recv(@coroutine.Coroutine, mut value~ : T?)
  RecvTo(@select.Selector[T])
  RecvMapTo((T, Bool) -> Bool)
}

///|
priv enum Writer[T] {
  Send(@coroutine.Coroutine, T, mut sent~ : Bool)
  SendTo(@select.Selector[Unit], T)
  SendMapTo(T, (Bool) -> Bool)
}

///|
pub fn[T] Channel::Channel(capacity : Int32) -> Channel[T] {
  if capacity < 0 {
    abort("@tonyfettes/co/channel: capacity must be non-negative")
  }
  Channel::{
    capacity,
    values: @deque.Deque([]),
    readers: @deque.Deque([]),
    writers: @deque.Deque([]),
  }
}

///|
fn[T] Channel::pop_writer(self : Channel[T]) -> T? {
  while self.writers.pop_front() is Some(writer) {
    match writer {
      Send(coroutine, value, sent=false) as sender => {
        sender.sent = true
        coroutine.schedule()
        return Some(value)
      }
      SendTo({ completed: false, coroutine, .. } as selected, value) => {
        selected.completed = true
        if coroutine is Some(coroutine) {
          coroutine.schedule()
        }
        selected.value = Some(())
        return Some(value)
      }
      SendMapTo(value, claim) if claim(true) => return Some(value)
      _ => continue
    }
  }
  None
}

///|
fn[T, R] Channel::pop_writer_for(
  self : Channel[T],
  selected : @select.Selector[R],
) -> T? {
  let mut skipped : Array[Writer[T]]? = None
  while self.writers.pop_front() is Some(writer) {
    match writer {
      Send(coroutine, value, sent=false) as sender => {
        sender.sent = true
        coroutine.schedule()
        selected.completed = true
        return Some(value)
      }
      SendTo({ completed: false, coroutine, .. } as writer_selected, value) => {
        selected.completed = true
        if writer_selected.completed {
          selected.completed = false
          match skipped {
            Some(buf) => buf.push(writer)
            None => skipped = Some([writer])
          }
          continue
        }
        writer_selected.completed = true
        if coroutine is Some(coroutine) {
          coroutine.schedule()
        }
        writer_selected.value = Some(())
        return Some(value)
      }
      SendMapTo(value, claim) => {
        if claim(false) {
          continue
        }
        selected.completed = true
        if claim(false) {
          selected.completed = false
          match skipped {
            Some(buf) => buf.push(writer)
            None => skipped = Some([writer])
          }
          continue
        }
        if claim(true) {
          return Some(value)
        }
        selected.completed = false
        continue
      }
      _ => continue
    }
  }
  if skipped is Some(buf) {
    for i = buf.length() - 1; i >= 0; i = i - 1 {
      self.writers.push_front(buf[i])
    }
  }
  None
}

///|
fn[T, R] Channel::try_send_for(
  self : Channel[T],
  value : T,
  selected : @select.Selector[R],
) -> Bool {
  let mut skipped : Array[Reader[T]]? = None
  while self.readers.pop_front() is Some(reader) {
    match reader {
      Recv(coroutine, value=_) as receiver => {
        receiver.value = Some(value)
        coroutine.schedule()
        selected.completed = true
        return true
      }
      RecvTo({ completed: false, coroutine, .. } as reader_selected) => {
        selected.completed = true
        if reader_selected.completed {
          selected.completed = false
          match skipped {
            Some(buf) => buf.push(reader)
            None => skipped = Some([reader])
          }
          continue
        }
        reader_selected.completed = true
        if coroutine is Some(coroutine) {
          coroutine.schedule()
        }
        reader_selected.value = Some(value)
        return true
      }
      RecvMapTo(func) => {
        if func(value, false) {
          continue
        }
        selected.completed = true
        if func(value, false) {
          selected.completed = false
          match skipped {
            Some(buf) => buf.push(reader)
            None => skipped = Some([reader])
          }
          continue
        }
        if func(value, true) {
          return true
        }
        selected.completed = false
        continue
      }
      _ => continue
    }
  }
  if self.values.length() < self.capacity {
    selected.completed = true
    self.values.push_back(value)
    return true
  }
  if skipped is Some(buf) {
    for i = buf.length() - 1; i >= 0; i = i - 1 {
      self.readers.push_front(buf[i])
    }
  }
  false
}

///|
pub fn[T] Channel::send(self : Channel[T], value : T) -> Unit {
  while self.readers.pop_front() is Some(reader) {
    match reader {
      Recv(coroutine, value=_) as receiver => {
        receiver.value = Some(value)
        coroutine.schedule()
        return
      }
      RecvTo({ completed: false, coroutine, .. } as selected) => {
        selected.completed = true
        if coroutine is Some(coroutine) {
          coroutine.schedule()
        }
        selected.value = Some(value)
        return
      }
      RecvMapTo(func) if func(value, true) => return
      _ => continue
    }
  }
  if self.values.length() < self.capacity {
    self.values.push_back(value)
    return
  }
  let writer = Send(@coroutine.current(), value, sent=false)
  self.writers.push_back(writer)
  @coroutine.suspend()
  guard writer is Send(_, _, sent=true) else {
    abort("@tonyfettes/co/channel: send woke up before value was received")
  }
}

///|
pub fn[T] Channel::send_to(
  self : Channel[T],
  value : T,
  selected : @select.Selector[Unit],
) -> Unit {
  guard !selected.completed else { return }
  if self.try_send_for(value, selected) {
    selected.value = Some(())
    return
  }
  self.writers.push_back(SendTo(selected, value))
}

///|
pub fn[T, R] Channel::send_map_to(
  self : Channel[T],
  value : T,
  selected : @select.Selector[R],
  f : () -> R,
) -> Unit {
  guard !selected.completed else { return }
  if self.try_send_for(value, selected) {
    selected.value = Some(f())
    return
  }
  self.writers.push_back(
    SendMapTo(value, commit => {
      if !commit {
        selected.completed
      } else {
        guard !selected.completed else { false }
        selected.completed = true
        if selected.coroutine is Some(coroutine) {
          coroutine.schedule()
        }
        selected.thunk = Some(f)
        true
      }
    }),
  )
}

///|
pub fn[T] Channel::recv_to(
  self : Channel[T],
  selected : @select.Selector[T],
) -> Unit {
  guard !selected.completed else { return }
  if self.values.pop_front() is Some(value) {
    selected.completed = true
    if self.pop_writer() is Some(next_value) {
      self.values.push_back(next_value)
    }
    selected.value = Some(value)
    return
  }
  if self.pop_writer_for(selected) is Some(value) {
    selected.value = Some(value)
    return
  }
  self.readers.push_back(RecvTo(selected))
}

///|
pub fn[T, R] Channel::recv_map_to(
  self : Channel[T],
  selected : @select.Selector[R],
  f : (T) -> R,
) -> Unit {
  guard !selected.completed else { return }
  if self.values.pop_front() is Some(value) {
    selected.completed = true
    if self.pop_writer() is Some(next_value) {
      self.values.push_back(next_value)
    }
    selected.value = Some(f(value))
    return
  }
  if self.pop_writer_for(selected) is Some(value) {
    selected.value = Some(f(value))
    return
  }
  self.readers.push_back(
    RecvMapTo((value, commit) => {
      if !commit {
        selected.completed
      } else {
        guard !selected.completed else { false }
        selected.completed = true
        if selected.coroutine is Some(coroutine) {
          coroutine.schedule()
        }
        selected.thunk = Some(() => f(value))
        true
      }
    }),
  )
}

///|
pub fn[T] Channel::recv(self : Channel[T]) -> T {
  if self.values.pop_front() is Some(value) {
    if self.pop_writer() is Some(next_value) {
      self.values.push_back(next_value)
    }
    return value
  }
  if self.pop_writer() is Some(value) {
    return value
  }
  let reader = Recv(@coroutine.current(), value=None)
  self.readers.push_back(reader)
  @coroutine.suspend()
  guard reader is Recv(_, value~) && value is Some(value) else {
    abort("@tonyfettes/co/channel: recv woke up but no value available")
  }
  value
}
