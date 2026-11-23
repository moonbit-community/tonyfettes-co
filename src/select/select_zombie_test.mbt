///|
test "select leaves zombie reader on early poll win" {
  let a : @channel.Channel[Int32] = @channel.Channel(1)
  let b : @channel.Channel[Int32] = @channel.Channel(1)
  b.send(1)
  let ready = @select.select <| selector => {
    a.recv_to(selector)
    b.recv_to(selector)
  }
  inspect(ready, content="1")
  inspect(b.recv(), content="1")
  // `a`'s leftover registration is a zombie and must not interfere with later sends.
  a.send(42)
  inspect(a.recv(), content="42")
}

///|
test "select leaves zombie reader on suspended win" {
  let a : @channel.Channel[Int32] = @channel.Channel(0)
  let b : @channel.Channel[Int32] = @channel.Channel(1)
  let result = @future.Future::new()
  let _ = @coroutine.Coroutine(() => {
    let idx = @select.select <| selector => {
      a.recv_to(selector)
      b.recv_to(selector)
    }
    result.set(if idx == 0 { a.recv() } else { b.recv() })
  })
  a.send(1)
  inspect(result.wait(), content="1")
  b.send(99)
  inspect(b.recv(), content="99")
}
