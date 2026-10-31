///|
/// The same echo server as `bench/net/co_echo`, written with moonbitlang/async, so the
/// two runtimes can be compared with one load generator.
async fn main {
  let server = @socket.TcpServer(@socket.Addr::new(0x7F000001, 8080))
  println("listening on \{server.addr}")
  @async.with_task_group(group => {
    for ;; {
      let (conn, peer) = server.accept()
      group.spawn_bg(no_wait=true, () => {
        let buf = FixedArray::make(16384, b'\x00')
        for ;; {
          let n = conn.read(buf) catch { _ => break }
          if n == 0 {
            break
          }
          conn.write(buf.unsafe_reinterpret_as_bytes()[:n].to_owned()) catch {
            _ => break
          }
        }
        let _ = peer
      })
    }
  })
}
