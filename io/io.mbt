///|
#cfg(not(platform="windows"))
struct Handle(Int32)

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
extern "c" fn IoContext::alloc() -> IoContext = "moonbit_co_io_alloc"

///|
#borrow(io)
extern "c" fn io_init(io : IoContext) -> Int32 = "moonbit_co_io_init"

///|
fn IoContext::new() -> IoContext raise Errno {
  let io = IoContext::alloc()
  let errno = io_init(io)
  if errno != 0 {
    raise Errno(errno)
  }
  io
}

///|
pub(all) suberror Errno {
  Errno(Int32)
} derive(Debug)

///|
// `derive(Debug)` promotes `Debug::to_repr` to a regular method of `Errno`;
// declare that promotion explicitly instead of relying on the deprecated
// implicit form. Hidden from the interface — `Debug::to_repr` is the
// supported call form for formatting an error.
#deprecated("Use `Debug::to_repr` instead", skip_current_package=true)
#doc(hidden)
pub extend Errno with @debug.Debug::{to_repr}

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
  offset~ : Int32,
  length~ : Int32,
  position~ : Int64,
  result : IoResult,
  coroutine : @coroutine.Coroutine,
) = "moonbit_co_io_submit_read"

///|
#owned(io, buffer, result, coroutine)
extern "c" fn submit_write(
  io : IoContext,
  handle : Handle,
  buffer~ : Bytes,
  offset~ : Int32,
  length~ : Int32,
  position~ : Int64,
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
) -> Int32 = "moonbit_co_io_poll"

///|
/// POSIX `EINVAL`, raised for out-of-range offset/length arguments before they
/// reach the native backends (where a negative length would be reinterpreted as
/// a huge unsigned size).
const EINVAL : Int32 = 22

///|
const MaxCompletions : Int32 = 256

///|
fn create_io_context() -> IoContext {
  IoContext::new() catch {
    Errno(errno) =>
      abort("failed to initialize the I/O context: errno \{errno}")
  }
}

///|
let io : IoContext = create_io_context()

///|
let poll_coroutines : FixedArray[@coroutine.Coroutine] = FixedArray::make(
  MaxCompletions,
  @coroutine.current(),
)

///|
pub fn suspend() -> Unit raise Errno {
  let length = io_poll(io, poll_coroutines, -1)
  if length < 0 {
    raise Errno(-length)
  }
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
pub fn File::close(self : File) -> Unit raise {
  self.0.close()
}

///|
pub fn File::open(
  path : @os_string.OsString,
  access~ : AccessMode = ReadOnly,
  create~ : CreateMode = OpenExisting,
  append~ : Bool = false,
  sync~ : SyncMode = None,
  at~ : Directory = invalid_handle,
) -> File raise {
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
/// Reads into `buffer[offset..offset+length]` from the current file position
/// (`position` defaults to `-1`), suspending the calling coroutine until the
/// read completes. Returns the number of bytes read, `0` at end of file.
///
/// `offset` addresses the *buffer*; pass `position` to read at a fixed file
/// offset (`pread` semantics), which is the only form that is safe to issue
/// concurrently on one handle.
pub fn File::read(
  self : File,
  buffer : FixedArray[Byte],
  offset~ : Int32 = 0,
  length~ : Int32 = buffer.length() - offset,
  position~ : Int64 = -1,
) -> Int32 raise {
  self.0.read(buffer, offset~, length~, position~)
}

///|
/// Writes `buffer[offset..offset+length]` at the current file position
/// (`position` defaults to `-1`).
pub fn File::write(
  self : File,
  buffer : Bytes,
  offset~ : Int32 = 0,
  length~ : Int32 = buffer.length() - offset,
  position~ : Int64 = -1,
) -> Int32 raise {
  self.0.write(buffer, offset~, length~, position~)
}

///|
pub fn Handle::read(
  handle : Handle,
  buffer : FixedArray[Byte],
  offset~ : Int32 = 0,
  length~ : Int32 = buffer.length() - offset,
  position~ : Int64 = -1,
) -> Int32 raise {
  guard offset >= 0 &&
    length >= 0 &&
    offset + length <= buffer.length() &&
    position >= -1 else {
    raise Errno(EINVAL)
  }
  let result = IoResult::new()
  submit_read(
    io,
    handle,
    buffer~,
    offset~,
    length~,
    position~,
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
  offset~ : Int32 = 0,
  length~ : Int32 = buffer.length() - offset,
  position~ : Int64 = -1,
) -> Int32 raise {
  guard offset >= 0 &&
    length >= 0 &&
    offset + length <= buffer.length() &&
    position >= -1 else {
    raise Errno(EINVAL)
  }
  let result = IoResult::new()
  submit_write(
    io,
    handle,
    buffer~,
    offset~,
    length~,
    position~,
    result,
    @coroutine.current(),
  )
  @coroutine.suspend()
  result.value().to_int()
}

///|
pub fn Handle::close(handle : Handle) -> Unit raise {
  let result = IoResult::new()
  submit_close(io, handle, result, @coroutine.current())
  @coroutine.suspend()
  result.value() |> ignore()
}

///|
#owned(io, peer, result, coroutine)
extern "c" fn submit_accept(
  io : IoContext,
  handle : Handle,
  peer~ : Bytes,
  result : IoResult,
  coroutine : @coroutine.Coroutine,
) = "moonbit_co_io_submit_accept"

///|
#owned(io, buffer, result, coroutine)
extern "c" fn submit_recv(
  io : IoContext,
  handle : Handle,
  buffer~ : FixedArray[Byte],
  offset~ : Int32,
  length~ : Int32,
  result : IoResult,
  coroutine : @coroutine.Coroutine,
) = "moonbit_co_io_submit_recv"

///|
#owned(io, buffer, result, coroutine)
extern "c" fn submit_send(
  io : IoContext,
  handle : Handle,
  buffer~ : Bytes,
  offset~ : Int32,
  length~ : Int32,
  result : IoResult,
  coroutine : @coroutine.Coroutine,
) = "moonbit_co_io_submit_send"

///|
#owned(io, addr, result, coroutine)
extern "c" fn submit_connect(
  io : IoContext,
  handle : Handle,
  addr~ : Bytes,
  result : IoResult,
  coroutine : @coroutine.Coroutine,
) = "moonbit_co_io_submit_connect"

///|
/// Connect a socket to `addr`, suspending the calling coroutine until the
/// connection is established. `addr` is a 16-byte `sockaddr_in`.
pub fn Handle::connect(self : Handle, addr : Bytes) -> Unit raise {
  let result = IoResult::new()
  submit_connect(io, self, addr~, result, @coroutine.current())
  @coroutine.suspend()
  result.value() |> ignore()
}

///|
/// Accept a connection on a listening socket.
///
/// Returns the new connection and the raw peer `sockaddr` (132 bytes: 128 of
/// address followed by a `uint32` length) for `SocketAddr` to decode.
pub fn Handle::accept(self : Handle) -> (Handle, Bytes) raise {
  let result = IoResult::new()
  let peer = Bytes::new(132)
  submit_accept(io, self, peer~, result, @coroutine.current())
  @coroutine.suspend()
  (Handle(result.value().to_int()), peer)
}

///|
/// Receive from a socket. Returns 0 at end of stream, like `read(2)`, but
/// without touching a file offset.
pub fn Handle::recv(
  handle : Handle,
  buffer : FixedArray[Byte],
  offset~ : Int32 = 0,
  length~ : Int32 = buffer.length() - offset,
) -> Int32 raise {
  guard offset >= 0 && length >= 0 && offset + length <= buffer.length() else {
    raise Errno(EINVAL)
  }
  let result = IoResult::new()
  submit_recv(
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
/// Send to a socket with `MSG_NOSIGNAL`, so a peer that has gone away yields
/// `EPIPE` instead of killing the process with `SIGPIPE`.
pub fn Handle::send(
  handle : Handle,
  buffer : Bytes,
  offset~ : Int32 = 0,
  length~ : Int32 = buffer.length() - offset,
) -> Int32 raise {
  guard offset >= 0 && length >= 0 && offset + length <= buffer.length() else {
    raise Errno(EINVAL)
  }
  let result = IoResult::new()
  submit_send(
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
