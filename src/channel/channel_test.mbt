///|
using @test {assert_eq}

///|
suberror Done

///|
suberror Other

///|
/// Whether `f` raised `Done`.
fn raises_done(f : () -> Unit raise) -> Bool {
  try f() catch {
    Done => true
    _ => false
  } noraise {
    _ => false
  }
}

///|
test "unbuffered send waits for a receiver" {
  let chan : @channel.Channel[Int32] = @channel.Channel()
  let log : Array[String] = []
  ignore(
    @coroutine.Coroutine(() => {
      try! ({
        log.push("send:before")
        chan.send(1)
        log.push("send:after")
      })
    }),
  )
  // The sender is parked: nobody has received yet.
  assert_eq(log, ["send:before"])
  assert_eq(chan.recv(), 1)
  // Receiving made the sender runnable; give it a turn.
  ignore(@coroutine.Coroutine(() => ()))
  assert_eq(log, ["send:before", "send:after"])
}

///|
test "unbuffered recv takes the value from a parked sender" {
  let chan : @channel.Channel[Int32] = @channel.Channel()
  let received : Array[Int32] = []
  ignore(@coroutine.Coroutine(() => try! received.push(chan.recv())))
  chan.send(7)
  // The value went straight to the parked receiver; let it run.
  ignore(@coroutine.Coroutine(() => ()))
  assert_eq(received, [7])
}

///|
test "buffered send waits only when the buffer is full" {
  let chan : @channel.Channel[Int32] = @channel.Channel(capacity=2)
  let sent : Array[Int32] = []
  ignore(
    @coroutine.Coroutine(() => {
      try! (for i in 0..<4 {
        chan.send(i)
        sent.push(i)
      })
    }),
  )
  // Two values fit in the buffer; the third send is parked.
  assert_eq(sent, [0, 1])
  // Values come out in order: the buffer first, then the parked senders' values.
  assert_eq(chan.recv(), 0)
  assert_eq(chan.recv(), 1)
  assert_eq(chan.recv(), 2)
  assert_eq(chan.recv(), 3)
}

///|
test "close: buffered values are delivered, then recv raises" {
  let chan : @channel.Channel[Int32] = @channel.Channel(capacity=2)
  chan.send(1)
  chan.send(2)
  chan.close(Done)
  assert_eq(chan.recv(), 1)
  assert_eq(chan.recv(), 2)
  assert_eq(raises_done(() => ignore(chan.recv())), true)
  assert_eq(raises_done(() => ignore(chan.recv())), true)
}

///|
test "close wakes a parked receiver with the error" {
  let chan : @channel.Channel[Int32] = @channel.Channel()
  let result : Array[Bool] = []
  ignore(
    @coroutine.Coroutine(() => {
      result.push(raises_done(() => ignore(chan.recv())))
    }),
  )
  chan.close(Done)
  ignore(@coroutine.Coroutine(() => ()))
  assert_eq(result, [true])
}

///|
test "close wakes a parked sender with the error" {
  let chan : @channel.Channel[Int32] = @channel.Channel()
  let result : Array[Bool] = []
  ignore(
    @coroutine.Coroutine(() => result.push(raises_done(() => chan.send(1)))),
  )
  chan.close(Done)
  ignore(@coroutine.Coroutine(() => ()))
  assert_eq(result, [true])
}

///|
test "send on a closed channel raises" {
  let chan : @channel.Channel[Int32] = @channel.Channel(capacity=1)
  chan.close(Done)
  assert_eq(raises_done(() => chan.send(1)), true)
}

///|
test "close is idempotent: the first error stays" {
  let chan : @channel.Channel[Int32] = @channel.Channel()
  chan.close(Done)
  chan.close(Other)
  assert_eq(raises_done(() => ignore(chan.recv())), true)
}

///|
test "select raises the close error of a closed channel" {
  let chan : @channel.Channel[Int32] = @channel.Channel()
  chan.close(Done)
  let other : @channel.Channel[Int32] = @channel.Channel()
  assert_eq(
    raises_done(() => {
      ignore(
        @select.select(selector => {
          other.recv_to(selector)
          chan.recv_to(selector)
        }),
      )
    }),
    true,
  )
}

///|
test "a parked select raises when its channel is closed" {
  let a : @channel.Channel[Int32] = @channel.Channel()
  let b : @channel.Channel[Int32] = @channel.Channel()
  let result : Array[Bool] = []
  ignore(
    @coroutine.Coroutine(() => {
      result.push(
        raises_done(() => {
          ignore(
            @select.select(selector => {
              a.recv_to(selector)
              b.recv_map_to(selector, x => x + 1)
            }),
          )
        }),
      )
    }),
  )
  b.close(Done)
  ignore(@coroutine.Coroutine(() => ()))
  assert_eq(result, [true])
}

///|
test "a select mapper may raise" {
  let chan : @channel.Channel[Int32] = @channel.Channel(capacity=1)
  chan.send(1)
  let selected = () => {
    let _ : Int32 = @select.select(selector => {
      chan.recv_map_to(selector, _ => raise Done)
    })
  }
  assert_eq(raises_done(selected), true)
}

///|
test "select takes the value from a parked sender" {
  let chan : @channel.Channel[Int32] = @channel.Channel()
  ignore(@coroutine.Coroutine(() => try! chan.send(5)))
  assert_eq(@select.select(selector => chan.recv_to(selector)), 5)
}
