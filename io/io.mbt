///|
struct Handle(UInt64)

///|
priv type Io

///|
extern "c" fn Io::new() -> Io = "moonbit_co_io_create"

///|
suberror Errno {
  Errno(Int)
}

priv enum Params {
  Open(path~ : Bytes, flags : FixedArray[Byte])
}

struct Request {
  params : Params
  value : Ref[UInt64]
  error : Ref[Int]
  task : @co.Task
}

///|
#borrow(io, flags)
#owned(value, error, task)
extern "c" fn submit_open(
  io : Io,
  path : Bytes,
  flags : FixedArray[Byte],
  value : Ref[UInt64],
  error : Ref[Int],
  task : @co.Task,
) = "moonbit_co_io_submit_open"

///|
#owned(io, buffer, value, error, task)
extern "c" fn submit_read(
  io : Io,
  handle : UInt64,
  buffer : FixedArray[Byte],
  offset : Int,
  length : Int,
  value : Ref[UInt64],
  error : Ref[Int],
  task : @co.Task,
) = "moonbit_co_io_submit_read"

///|
#owned(io, buffer, value, error, task)
extern "c" fn submit_write(
  io : Io,
  handle : UInt64,
  buffer : Bytes,
  offset : Int,
  length : Int,
  value : Ref[UInt64],
  error : Ref[Int],
  task : @co.Task,
) = "moonbit_co_io_submit_write"

///|
#owned(io, value, error, task)
extern "c" fn submit_close(
  io : Io,
  handle : UInt64,
  value : Ref[UInt64],
  error : Ref[Int],
  task : @co.Task,
) = "moonbit_co_io_submit_close"

///|
#borrow(io, tasks, length)
extern "c" fn io_poll(
  io : Io,
  tasks : FixedArray[@co.Task],
  length : Ref[Int],
  timeout : Int64,
) = "moonbit_co_io_poll"

///|
let max_completions : Int = 256

///|
let io : Io = Io::new()

///|
let poll_tasks : FixedArray[@co.Task] = FixedArray::make(
  max_completions,
  @co.Task::current(),
)

///|
pub fn suspend() -> Unit {
  let length = Ref::new(max_completions)
  io_poll(io, poll_tasks, length, -1)
  for i in 0..<length.val {
    poll_tasks[i].schedule()
  }
}

///|
pub fn open(
  path : Bytes,
  read? : Bool = true,
  write? : Bool = false,
  append? : Bool = false,
  create? : Bool = false,
  truncate? : Bool = false,
  exclusive? : Bool = false,
) -> Handle raise Errno {
  let value = Ref::new(0UL)
  let error = Ref::new(0)
  let flags : FixedArray[Byte] = [
    read.to_int().to_byte(),
    write.to_int().to_byte(),
    append.to_int().to_byte(),
    create.to_int().to_byte(),
    truncate.to_int().to_byte(),
    exclusive.to_int().to_byte(),
  ]
  submit_open(io, path, flags, value, error, @co.Task::current())
  @co.Task::suspend()
  if error.val != 0 {
    raise Errno(error.val)
  }
  Handle(value.val)
}

///|
pub fn read(
  handle : Handle,
  buffer : FixedArray[Byte],
  offset? : Int = 0,
  length? : Int = buffer.length() - offset,
) -> Int raise Errno {
  let value = Ref::new(0UL)
  let error = Ref::new(0)
  submit_read(
    io,
    handle.0,
    buffer,
    offset,
    length,
    value,
    error,
    @co.Task::current(),
  )
  @co.Task::suspend()
  if error.val != 0 {
    raise Errno(error.val)
  }
  value.val.to_int()
}

///|
pub fn write(
  handle : Handle,
  buffer : Bytes,
  offset? : Int = 0,
  length? : Int = buffer.length() - offset,
) -> Int raise Errno {
  let value = Ref::new(0UL)
  let error = Ref::new(0)
  submit_write(
    io,
    handle.0,
    buffer,
    offset,
    length,
    value,
    error,
    @co.Task::current(),
  )
  @co.Task::suspend()
  if error.val != 0 {
    raise Errno(error.val)
  }
  value.val.to_int()
}

///|
pub fn close(handle : Handle) -> Unit raise Errno {
  let value = Ref::new(0UL)
  let error = Ref::new(0)
  submit_close(io, handle.0, value, error, @co.Task::current())
  @co.Task::suspend()
  if error.val != 0 {
    raise Errno(error.val)
  }
}
