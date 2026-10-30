///|
/// Minimal TCP echo server: one coroutine per connection.
///
///   moon run --release --target native ./echo
///   telnet 127.0.0.1 8080      # type, get it echoed back
fn main raise {
  let listener = @io.TcpListener::bind(@io.SocketAddr::loopback(8080))
  println("listening on \{listener.local_addr().to_string()}")
  let mut served = 0
  for ;; {
    let (stream, peer) = listener.accept()
    served += 1
    let id = served
    ignore(
      @coroutine.Coroutine(name="conn-\{id}", () => {
        let buffer = FixedArray::make(4096, b'\x00')
        for ;; {
          let n = stream.read(buffer) catch {
            err => {
              println("[#\{id}] read error: \{err}")
              break
            }
          }
          if n == 0 {
            println("[#\{id}] peer closed (\{peer.to_string()})")
            break
          }
          let payload = buffer.unsafe_reinterpret_as_bytes()[:n].to_owned()
          ignore(stream.write(payload) catch { _ => break })
        }
        stream.close() catch {
          _ => ()
        }
      }),
    )
  }
}
