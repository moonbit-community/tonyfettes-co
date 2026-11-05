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

///|
test "select send: hands the value to a parked receiver" {
  let chan : @channel.Channel[Int32] = @channel.Channel()
  let got : Array[Int32] = []
  ignore(@coroutine.Coroutine(() => try! got.push(chan.recv())))
  let r = @select.select(s => chan.send_map_to(s, 1, () => "sent"))
  assert_eq(r, "sent")
  // The receiver is runnable; give it a turn.
  ignore(@coroutine.Coroutine(() => ()))
  assert_eq(got, [1])
}

///|
test "select send: fills free buffer space" {
  let chan : @channel.Channel[Int32] = @channel.Channel(capacity=1)
  @select.select(s => chan.send_to(s, 7))
  assert_eq(chan.recv(), 7)
}

///|
test "select send: parks until a receiver takes the value" {
  let chan : @channel.Channel[Int32] = @channel.Channel()
  let result : @channel.Channel[String] = @channel.Channel(capacity=1)
  ignore(
    @coroutine.Coroutine(() => {
      try! result.send(
        @select.select(s => chan.send_map_to(s, 5, () => "sent")),
      )
    }),
  )
  assert_eq(chan.recv(), 5)
  assert_eq(result.recv(), "sent")
}

///|
test "select send: a send case meets a recv case of another select" {
  let chan : @channel.Channel[Int32] = @channel.Channel()
  let result : @channel.Channel[String] = @channel.Channel(capacity=1)
  ignore(
    @coroutine.Coroutine(() => {
      try! result.send(
        @select.select(s => chan.send_map_to(s, 3, () => "sent")),
      )
    }),
  )
  assert_eq(@select.select(s => chan.recv_to(s)), 3)
  assert_eq(result.recv(), "sent")
}

///|
test "select send: a closed channel fails the case" {
  let chan : @channel.Channel[Int32] = @channel.Channel()
  chan.close(Done)
  assert_eq(raises_done(() => @select.select(s => chan.send_to(s, 1))), true)
}

///|
test "select send: closing the channel fails a parked case" {
  let chan : @channel.Channel[Int32] = @channel.Channel()
  let failed : Array[Bool] = []
  ignore(
    @coroutine.Coroutine(() => {
      failed.push(raises_done(() => @select.select(s => chan.send_to(s, 1))))
    }),
  )
  chan.close(Done)
  ignore(@coroutine.Coroutine(() => ()))
  assert_eq(failed, [true])
}

///|
test "select send: a losing send case does not send" {
  let a : @channel.Channel[Int32] = @channel.Channel()
  let b : @channel.Channel[Int32] = @channel.Channel()
  let result : @channel.Channel[String] = @channel.Channel(capacity=1)
  ignore(
    @coroutine.Coroutine(() => {
      try! result.send(
        @select.select(s => {
          a.send_map_to(s, 1, () => "sent a")
          b.recv_map_to(s, x => "recv b \{x}")
        }),
      )
    }),
  )
  b.send(2)
  assert_eq(result.recv(), "recv b 2")
  // The case on `a` lost: a receiver must not get its value.
  ignore(@coroutine.Coroutine(() => try! a.send(9)))
  assert_eq(a.recv(), 9)
}

///|
test "select send: a send and a recv case on one channel never match each other" {
  // Unbuffered and nobody else on the channel: both cases park, and the
  // select only completes when another coroutine receives.
  let chan : @channel.Channel[Int32] = @channel.Channel()
  let result : @channel.Channel[String] = @channel.Channel(capacity=1)
  ignore(
    @coroutine.Coroutine(() => {
      try! result.send(
        @select.select(s => {
          chan.send_map_to(s, 1, () => "sent")
          chan.recv_map_to(s, x => "recv \{x}")
        }),
      )
    }),
  )
  assert_eq(chan.recv(), 1)
  assert_eq(result.recv(), "sent")
}

///|
test "select send: a full buffer is drained by the recv case alone" {
  let chan : @channel.Channel[Int32] = @channel.Channel(capacity=1)
  chan.send(7)
  let r = @select.select(s => {
    chan.send_map_to(s, 2, () => "sent")
    chan.recv_map_to(s, x => "recv \{x}")
  })
  assert_eq(r, "recv 7")
  // The send case lost, so 2 was never buffered.
  chan.send(3)
  assert_eq(chan.recv(), 3)
}

///|
test "select send_to: a parked case is taken by a receiver" {
  let chan : @channel.Channel[Int32] = @channel.Channel()
  let log : Array[String] = []
  ignore(
    @coroutine.Coroutine(() => {
      try! @select.select(s => chan.send_to(s, 4))
      log.push("sent")
    }),
  )
  assert_eq(chan.recv(), 4)
  ignore(@coroutine.Coroutine(() => ()))
  assert_eq(log, ["sent"])
}

///|
test "select send_to: never matches a recv case of the same select" {
  let chan : @channel.Channel[Unit] = @channel.Channel()
  let log : Array[String] = []
  ignore(
    @coroutine.Coroutine(() => {
      try! @select.select(s => {
        chan.send_to(s, ())
        chan.recv_to(s)
      })
      log.push("done")
    }),
  )
  // Both cases parked; a receiver from outside takes the send case.
  chan.recv()
  ignore(@coroutine.Coroutine(() => ()))
  assert_eq(log, ["done"])
}
