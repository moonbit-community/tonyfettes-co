///|
struct Handle(UInt64)

///|
priv type Io

///|
extern "c" fn Io::new() -> Io = "moonbit_co_io_create"

///|
pub(all) suberror Errno {
  Errno(Int)
} derive(Debug)

///|
#borrow(flags)
#owned(io, path, value, error, coroutine)
extern "c" fn submit_open(
  io : Io,
  path : Bytes,
  flags : FixedArray[Byte],
  value : Ref[UInt64],
  error : Ref[Int],
  coroutine : @coroutine.Coroutine,
) = "moonbit_co_io_submit_open"

///|
#owned(io, buffer, value, error, coroutine)
extern "c" fn submit_read(
  io : Io,
  handle : UInt64,
  buffer : FixedArray[Byte],
  offset : Int,
  length : Int,
  value : Ref[UInt64],
  error : Ref[Int],
  coroutine : @coroutine.Coroutine,
) = "moonbit_co_io_submit_read"

///|
#owned(io, buffer, value, error, coroutine)
extern "c" fn submit_write(
  io : Io,
  handle : UInt64,
  buffer : Bytes,
  offset : Int,
  length : Int,
  value : Ref[UInt64],
  error : Ref[Int],
  coroutine : @coroutine.Coroutine,
) = "moonbit_co_io_submit_write"

///|
#owned(io, value, error, coroutine)
extern "c" fn submit_close(
  io : Io,
  handle : UInt64,
  value : Ref[UInt64],
  error : Ref[Int],
  coroutine : @coroutine.Coroutine,
) = "moonbit_co_io_submit_close"

///|
#borrow(io, coroutines, length)
extern "c" fn io_poll(
  io : Io,
  coroutines : FixedArray[@coroutine.Coroutine],
  length : Ref[Int],
  timeout : Int64,
) = "moonbit_co_io_poll"

///|
/// POSIX `EINVAL`, raised for out-of-range offset/length arguments before they
/// reach the native backends (where a negative length would be reinterpreted as
/// a huge unsigned size).
const EINVAL : Int = 22

///|
let max_completions : Int = 256

///|
let io : Io = Io::new()

///|
let poll_coroutines : FixedArray[@coroutine.Coroutine] = FixedArray::make(
  max_completions,
  @coroutine.current(),
)

///|
pub fn suspend() -> Unit {
  let length = Ref(max_completions)
  io_poll(io, poll_coroutines, length, -1)
  for i in 0..<length.val {
    poll_coroutines[i].schedule()
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
  let value = Ref(0UL)
  let error = Ref(0)
  let flags : FixedArray[Byte] = [
    read.to_int().to_byte(),
    write.to_int().to_byte(),
    append.to_int().to_byte(),
    create.to_int().to_byte(),
    truncate.to_int().to_byte(),
    exclusive.to_int().to_byte(),
  ]
  submit_open(io, path, flags, value, error, @coroutine.current())
  @coroutine.suspend()
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
  guard offset >= 0 && length >= 0 && offset + length <= buffer.length() else {
    raise Errno(EINVAL)
  }
  let value = Ref(0UL)
  let error = Ref(0)
  submit_read(
    io,
    handle.0,
    buffer,
    offset,
    length,
    value,
    error,
    @coroutine.current(),
  )
  @coroutine.suspend()
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
  guard offset >= 0 && length >= 0 && offset + length <= buffer.length() else {
    raise Errno(EINVAL)
  }
  let value = Ref(0UL)
  let error = Ref(0)
  submit_write(
    io,
    handle.0,
    buffer,
    offset,
    length,
    value,
    error,
    @coroutine.current(),
  )
  @coroutine.suspend()
  if error.val != 0 {
    raise Errno(error.val)
  }
  value.val.to_int()
}

///|
pub fn close(handle : Handle) -> Unit raise Errno {
  let value = Ref(0UL)
  let error = Ref(0)
  submit_close(io, handle.0, value, error, @coroutine.current())
  @coroutine.suspend()
  if error.val != 0 {
    raise Errno(error.val)
  }
}
