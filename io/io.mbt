///|
#cfg(not(platform="windows"))
struct Handle(Int)

///|
#cfg(platform="windows")
#external
type Handle

///|
#cfg(not(platform="windows"))
let invalid_handle : Handle = Handle(-1)

///|
#cfg(platform="windows")
extern "c" fn co_io_invalid_handle() -> Handle = "moonbit_co_io_invalid_handle"

///|
#cfg(platform="windows")
let invalid_handle : Handle = co_io_invalid_handle()

///|
priv type IoContext

///|
priv struct IoResult(FixedArray[UInt64])

///|
fn IoResult::new() -> IoResult {
  [0, 0]
}

///|
fn IoResult::value(self : IoResult) -> UInt64 raise Errno {
  match self.0 {
    [value, 0] => return value
    [_, errno] => raise Errno(errno.to_int())
    _ => abort("unreachable")
  }
}

///|
extern "c" fn IoContext::new() -> IoContext = "moonbit_co_io_create"

///|
pub(all) suberror Errno {
  Errno(Int)
} derive(Debug)

///|
#owned(context, path, result, coroutine)
extern "c" fn submit_open(
  context : IoContext,
  path : @os_string.OsString,
  access~ : AccessMode,
  create~ : CreateMode,
  append~ : Bool,
  sync~ : SyncMode,
  at~ : Handle,
  directory~ : Bool,
  result : IoResult,
  coroutine : @coroutine.Coroutine,
) = "moonbit_co_io_submit_open"

///|
#owned(io, buffer, result, coroutine)
extern "c" fn submit_read(
  io : IoContext,
  handle : Handle,
  buffer~ : FixedArray[Byte],
  offset~ : Int,
  length~ : Int,
  result : IoResult,
  coroutine : @coroutine.Coroutine,
) = "moonbit_co_io_submit_read"

///|
#owned(io, buffer, result, coroutine)
extern "c" fn submit_write(
  io : IoContext,
  handle : Handle,
  buffer~ : Bytes,
  offset~ : Int,
  length~ : Int,
  result : IoResult,
  coroutine : @coroutine.Coroutine,
) = "moonbit_co_io_submit_write"

///|
#owned(io, result, coroutine)
extern "c" fn submit_close(
  io : IoContext,
  handle : Handle,
  result : IoResult,
  coroutine : @coroutine.Coroutine,
) = "moonbit_co_io_submit_close"

///|
#borrow(io, coroutines)
extern "c" fn io_poll(
  io : IoContext,
  coroutines : FixedArray[@coroutine.Coroutine],
  timeout : Int64,
) -> Int = "moonbit_co_io_poll"

///|
/// POSIX `EINVAL`, raised for out-of-range offset/length arguments before they
/// reach the native backends (where a negative length would be reinterpreted as
/// a huge unsigned size).
const EINVAL : Int = 22

///|
const MaxCompletions : Int = 256

///|
let io : IoContext = IoContext::new()

///|
let poll_coroutines : FixedArray[@coroutine.Coroutine] = FixedArray::make(
  MaxCompletions,
  @coroutine.current(),
)

///|
pub fn suspend() -> Unit {
  let length = io_poll(io, poll_coroutines, -1)
  for i in 0..<length {
    poll_coroutines[i].schedule()
  }
}

///|
pub(all) enum CreateMode {
  OpenExisting = 0
  TruncateExisting = 1
  OpenOrCreate = 2
  CreateOrTruncate = 3
  CreateNew = 4
}

///|
pub(all) enum AccessMode {
  ReadOnly = 0
  WriteOnly = 1
  ReadWrite = 2
}

///|
pub(all) enum SyncMode {
  None = 0
  Data = 1
  Full = 2
}

///|
struct Directory(Handle)

///|
struct File(Handle)

///|
pub fn File::handle(self : File) -> Handle {
  self.0
}

///|
pub fn File::close(self : File) -> Unit raise Errno {
  self.0.close()
}

///|
pub fn File::open(
  path : @os_string.OsString,
  access? : AccessMode = ReadOnly,
  create? : CreateMode = OpenExisting,
  append? : Bool = false,
  sync? : SyncMode = None,
  at? : Directory = invalid_handle,
) -> File raise Errno {
  let result = IoResult::new()
  submit_open(
    io,
    path,
    access~,
    create~,
    append~,
    sync~,
    at=at.0,
    directory=false,
    result,
    @coroutine.current(),
  )
  @coroutine.suspend()
  Handle(result.value().to_int())
}

///|
pub fn File::read(
  self : File,
  buffer : FixedArray[Byte],
  offset? : Int = 0,
  length? : Int = buffer.length() - offset,
) -> Int raise Errno {
  self.0.read(buffer, offset~, length~)
}

///|
pub fn File::write(
  self : File,
  buffer : Bytes,
  offset? : Int = 0,
  length? : Int = buffer.length() - offset,
) -> Int raise Errno {
  self.0.write(buffer, offset~, length~)
}

///|
pub fn Handle::read(
  handle : Handle,
  buffer : FixedArray[Byte],
  offset? : Int = 0,
  length? : Int = buffer.length() - offset,
) -> Int raise Errno {
  guard offset >= 0 && length >= 0 && offset + length <= buffer.length() else {
    raise Errno(EINVAL)
  }
  let result = IoResult::new()
  submit_read(
    io,
    handle,
    buffer~,
    offset~,
    length~,
    result,
    @coroutine.current(),
  )
  @coroutine.suspend()
  result.value().to_int()
}

///|
pub fn Handle::write(
  handle : Handle,
  buffer : Bytes,
  offset? : Int = 0,
  length? : Int = buffer.length() - offset,
) -> Int raise Errno {
  guard offset >= 0 && length >= 0 && offset + length <= buffer.length() else {
    raise Errno(EINVAL)
  }
  let result = IoResult::new()
  submit_write(
    io,
    handle,
    buffer~,
    offset~,
    length~,
    result,
    @coroutine.current(),
  )
  @coroutine.suspend()
  result.value().to_int()
}

///|
pub fn Handle::close(handle : Handle) -> Unit raise Errno {
  let result = IoResult::new()
  submit_close(io, handle, result, @coroutine.current())
  @coroutine.suspend()
  result.value() |> ignore()
}
