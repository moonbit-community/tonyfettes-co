///|
/// An IPv4 endpoint.
pub(all) struct SocketAddr {
  ip : UInt32 // host byte order
  port : Int32
}

///|
pub fn SocketAddr::SocketAddr(ip : UInt32, port : Int32) -> SocketAddr {
  { ip, port, }
}

///|
pub fn SocketAddr::to_string(self : SocketAddr) -> String {
  let a = (self.ip >> 24) & 0xFF
  let b = (self.ip >> 16) & 0xFF
  let c = (self.ip >> 8) & 0xFF
  let d = self.ip & 0xFF
  "\{a}.\{b}.\{c}.\{d}:\{self.port}"
}

///|
pub fn SocketAddr::loopback(port : Int32) -> SocketAddr {
  { ip: 0x7F000001, port, }
}

///|
extern "c" fn net_listen(ip : UInt32, port : Int32, backlog : Int32) -> Int32 = "moonbit_co_net_listen"

///|
extern "c" fn net_local_port(fd : Int32) -> Int32 = "moonbit_co_net_local_port"

///|
extern "c" fn net_connect(ip : UInt32, port : Int32) -> Int32 = "moonbit_co_net_connect"

///|
extern "c" fn net_close(fd : Int32) = "moonbit_co_net_close"

///|
#borrow(peer, ip_out, port_out)
extern "c" fn net_decode_peer(
  peer : Bytes,
  ip_out : Ref[UInt32],
  port_out : Ref[Int32],
) -> Int32 = "moonbit_co_net_decode_peer"

///|
/// A bound, listening TCP socket. `accept` suspends the calling coroutine until
/// a connection arrives.
pub struct TcpListener {
  fd : Int32
  ip : UInt32
}

///|
/// Bind and listen. Port 0 picks an ephemeral port; read it back with
/// `TcpListener::local_addr`.
pub fn TcpListener::bind(
  addr : SocketAddr,
  backlog~ : Int32 = 128,
) -> TcpListener raise Errno {
  let fd = net_listen(addr.ip, addr.port, backlog)
  guard fd >= 0 else { raise Errno(-fd) }
  { fd, ip: addr.ip, }
}

///|
/// The address actually bound (the port may differ from the requested one).
pub fn TcpListener::local_addr(self : TcpListener) -> SocketAddr raise Errno {
  let port = net_local_port(self.fd)
  guard port >= 0 else { raise Errno(-port) }
  { ip: self.ip, port, }
}

///|
/// Wait for the next connection, suspending the calling coroutine.
///
/// Only the `accept` waits: reading and writing the accepted stream suspend
/// per operation, so each connection can be served by its own coroutine.
pub fn TcpListener::accept(self : TcpListener) -> (TcpStream, SocketAddr) raise {
  let (handle, peer) = Handle::accept(Handle(self.fd))
  let ip = Ref(0U)
  let port = Ref(0)
  ignore(net_decode_peer(peer, ip, port))
  ({ handle, }, { ip: ip.val, port: port.val, })
}

///|
/// Stop accepting. Connections already accepted stay open.
pub fn TcpListener::close(self : TcpListener) -> Unit {
  net_close(self.fd)
}

///|
/// A connected TCP socket.
pub struct TcpStream {
  handle : Handle
}

///|
/// Connect to `addr`. The connection is established synchronously.
pub fn TcpStream::connect(addr : SocketAddr) -> TcpStream raise Errno {
  let fd = net_connect(addr.ip, addr.port)
  guard fd >= 0 else { raise Errno(-fd) }
  { handle: Handle(fd), }
}

///|
/// Read up to `buffer.length()` bytes, suspending until data arrives.
/// Returns 0 at end of stream.
pub fn TcpStream::read(
  self : TcpStream,
  buffer : FixedArray[Byte],
) -> Int32 raise {
  self.handle.recv(buffer)
}

///|
/// Write `buffer`, suspending until the kernel accepts it.
pub fn TcpStream::write(self : TcpStream, buffer : Bytes) -> Int32 raise {
  self.handle.send(buffer)
}

///|
/// Close the connection; the peer sees end of stream.
pub fn TcpStream::close(self : TcpStream) -> Unit raise {
  self.handle.close()
}
