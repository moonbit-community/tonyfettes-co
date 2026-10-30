///|
test "net: echo one connection" {
  let listener = @io.TcpListener::bind(@io.SocketAddr::loopback(0))
  let addr = listener.local_addr()
  assert_true(addr.port > 0)
  let served : @future.Promise[String, Failure] = @future.Promise::new()
  // Server: one connection, echo it, close.
  ignore(
    @coroutine.Coroutine(name="server", () => {
      let (stream, peer) = listener.accept()
      let buffer = FixedArray::make(64, b'\x00')
      let n = stream.read(buffer)
      let echoed = stream.write(
        buffer.unsafe_reinterpret_as_bytes()[:n].to_owned(),
      )
      stream.close()
      // The peer port is the client's ephemeral port, not the listen port.
      assert_eq(peer.ip, 0x7F000001)
      assert_true(peer.port > 0)
      served.resolve("read=\{n} wrote=\{echoed}")
    }),
  )
  // Client: `connect` on loopback completes without the server accepting, and
  // every other operation goes through the same io backend, so nothing blocks
  // the scheduler.
  let client = @io.TcpStream::connect(addr)
  let payload = b"hello coroutine"
  assert_eq(client.write(payload), payload.length())
  let buffer = FixedArray::make(64, b'\x00')
  let n = client.read(buffer)
  client.close()
  assert_eq(buffer.unsafe_reinterpret_as_bytes()[:n], payload)
  assert_eq(served.wait(), "read=15 wrote=15")
  listener.close()
}

///|
test "net: end of stream reads as 0" {
  let listener = @io.TcpListener::bind(@io.SocketAddr::loopback(0))
  let addr = listener.local_addr()
  let seen : @future.Promise[String, Failure] = @future.Promise::new()
  ignore(
    @coroutine.Coroutine(name="server", () => {
      let (stream, _) = listener.accept()
      let buffer = FixedArray::make(16, b'\x00')
      let first = stream.read(buffer)
      let second = stream.read(buffer)
      stream.close()
      seen.resolve("\{first},\{second}")
    }),
  )
  let client = @io.TcpStream::connect(addr)
  ignore(client.write(b"bye"))
  client.close()
  assert_eq(seen.wait(), "3,0")
  listener.close()
}
