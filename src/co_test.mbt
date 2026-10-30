///|
using @test {assert_eq}

///|
priv suberror CoroutineTestError derive(Debug)

///|
test "Coroutine: errors cross the native trampoline" {
  let error = @test.expect_error(() => {
    ignore(@coroutine.Coroutine(name="raises", () => raise CoroutineTestError))
  })
  assert_true(error is CoroutineTestError)

  let gate : @channel.Channel[Unit] = @channel.Channel::new()
  let never : @future.Future[Int32] = @future.Future::new()
  ignore(
    @coroutine.Coroutine(name="raises-after-suspend", () => {
      gate.recv() |> ignore()
      raise CoroutineTestError
    }),
  )
  gate.send(())
  let error = @test.expect_error(() => never.wait() |> ignore())
  assert_true(error is CoroutineTestError)

  // The creator and scheduler must both remain usable after the error crosses
  // the co_reset callback boundary.
  let result = @future.Future::new()
  ignore(@coroutine.Coroutine(name="after-error", () => result.set(42)))
  assert_eq(result.wait(), 42)
}

///|
test "Channel" {
  let chan = @channel.Channel::new()
  let done = @channel.Channel::new()
  let _ = @coroutine.Coroutine(name="f", () => {
    println("f: 1")
    println("f: chan.recv() -> \{chan.recv()}")
    println("f: 2")
    println("f: chan.recv() -> \{chan.recv()}")
    println("f: 3")
    done.send(())
  })
  println("main: before chan.send(3)")
  chan.send(3)
  println("main: before chan.send(4)")
  chan.send(4)
  println("main: waiting for f")
  done.recv()
  println("main: done")
}

///|
test "Bidirectional: f <-> g" {
  let forward = @channel.Channel::new()
  let backward = @channel.Channel::new()
  let done = @channel.Channel::new()
  let _ = @coroutine.Coroutine(name="f", () => {
    println("f: before forward.send(1)")
    forward.send(1)
    println("f: after forward.send(1)")
    println("f: before backward.recv()")
    println("f: after backward.recv() -> \{backward.recv()}")
    done.send(())
  })
  let _ = @coroutine.Coroutine(name="g", () => {
    println("g: before forward.recv()")
    println("g: after forward.recv() -> \{forward.recv()}")
    println("g: before backward.send(2)")
    backward.send(2)
    println("g: after backward.send(2)")
    done.send(())
  })
  done.recv()
  done.recv()
}

///|
test "Channel: values follow FIFO" {
  let chan : @channel.Channel[Int32] = @channel.Channel::new()
  let done = @channel.Channel::new()
  chan.send(1)
  chan.send(2)
  chan.send(3)
  let results = []
  let _ = @coroutine.Coroutine(name="reader", () => {
    results.push(chan.recv())
    results.push(chan.recv())
    results.push(chan.recv())
    done.send(())
  })
  done.recv()
  assert_eq(results, [1, 2, 3])
}

///|
test "Channel: readers follow FIFO" {
  let chan : @channel.Channel[Int32] = @channel.Channel::new()
  let done : @channel.Channel[Unit] = @channel.Channel::new()
  let results = []
  let _ = @coroutine.Coroutine(name="reader1", () => {
    results.push(("reader1", chan.recv()))
    done.send(())
  })
  let _ = @coroutine.Coroutine(name="reader2", () => {
    results.push(("reader2", chan.recv()))
    done.send(())
  })
  chan.send(10)
  chan.send(20)
  done.recv()
  done.recv()
  assert_eq(results, [("reader1", 10), ("reader2", 20)])
}

///|
test "Bidirectional: main <-> f" {
  let forward = @channel.Channel::new()
  let backward = @channel.Channel::new()
  let _ = @coroutine.Coroutine(name="f", () => {
    println("f: before forward.send(1)")
    forward.send(1)
    println("f: after forward.send(1)")
    println("f: before backward.recv()")
    println("f: after backward.recv() -> \{backward.recv()}")
  })
  println("main: before forward.recv()")
  println("main: after forward.recv() -> \{forward.recv()}")
  println("main: before backward.send(2)")
  backward.send(2)
  println("main: after backward.send(2)")
}

///|
test "Future: wait for result" {
  let f = @future.Future::new()
  let _ = @coroutine.Coroutine(name="compute", () => f.set(21 * 2))
  assert_eq(f.wait(), 42)
}

///|
test "Future: multiple futures" {
  let a = @future.Future::new()
  let b = @future.Future::new()
  let c = @future.Future::new()
  let _ = @coroutine.Coroutine(name="a", () => a.set(10))
  let _ = @coroutine.Coroutine(name="b", () => b.set(20))
  let _ = @coroutine.Coroutine(name="c", () => c.set(30))
  assert_eq(a.wait() + b.wait() + c.wait(), 60)
}

///|
test "Coroutine: spawn and complete" {
  let result = @future.Future::new()
  let _ = @coroutine.Coroutine(name="worker", () => result.set(42))
  assert_eq(result.wait(), 42)
}

///|
test "Coroutine: FIFO scheduling order" {
  let order : Array[Int32] = []
  let done = @channel.Channel::new()
  let _ = @coroutine.Coroutine(name="a", () => {
    order.push(1)
    done.send(())
  })
  let _ = @coroutine.Coroutine(name="b", () => {
    order.push(2)
    done.send(())
  })
  let _ = @coroutine.Coroutine(name="c", () => {
    order.push(3)
    done.send(())
  })
  done.recv()
  done.recv()
  done.recv()
  assert_eq(order, [1, 2, 3])
}

///|
test "Future: multiple waiters" {
  let f = @future.Future::new()
  let results : Array[Int32] = []
  let done = @channel.Channel::new()
  let _ = @coroutine.Coroutine(name="w1", () => {
    results.push(f.wait())
    done.send(())
  })
  let _ = @coroutine.Coroutine(name="w2", () => {
    results.push(f.wait())
    done.send(())
  })
  let _ = @coroutine.Coroutine(name="w3", () => {
    results.push(f.wait())
    done.send(())
  })
  f.set(99)
  done.recv()
  done.recv()
  done.recv()
  assert_eq(results, [99, 99, 99])
}

///|
test "Channel: send wakes one reader" {
  let chan : @channel.Channel[Int32] = @channel.Channel::new()
  let woken : Array[String] = []
  let done = @channel.Channel::new()
  let _ = @coroutine.Coroutine(name="r1", () => {
    let _ = chan.recv()
    woken.push("r1")
    done.send(())
  })
  let _ = @coroutine.Coroutine(name="r2", () => {
    let _ = chan.recv()
    woken.push("r2")
    done.send(())
  })
  // Send one value — only one reader should wake
  chan.send(1)
  done.recv()
  assert_eq(woken, ["r1"])
  // Send second — the other reader wakes
  chan.send(2)
  done.recv()
  assert_eq(woken, ["r1", "r2"])
}

///|
test "Future: blocks until ready" {
  let chan = @channel.Channel::new()
  let f = @future.Future::new()
  let _ = @coroutine.Coroutine(name="waiter", () => {
    let v = chan.recv()
    println("waiter: chan.recv() -> \{v}")
    f.set(v * 2)
  })
  chan.send(5)
  println("main: chan.send(5)")
  assert_eq(f.wait(), 10)
}

///|
test "Channel close: a parked receiver is woken and its defer runs" {
  let gate : @channel.Channel[Unit] = @channel.Channel::new()
  let log : Array[String] = []
  ignore(
    @coroutine.Coroutine(name="receiver", () => {
      defer log.push("cleanup")
      gate.recv() catch {
        @channel.ChannelClosed => log.push("closed")
        _ => log.push("other-error")
      }
      log.push("returned")
    }),
  )
  assert_eq(log, [])
  gate.close()
  ignore(@coroutine.Coroutine(name="drain", () => ()))
  assert_eq(log, ["closed", "returned", "cleanup"])
}

///|
test "Channel close: every parked receiver is woken" {
  let gate : @channel.Channel[Unit] = @channel.Channel::new()
  let log : Array[String] = []
  for i in 0..<3 {
    ignore(
      @coroutine.Coroutine(name="receiver-\{i}", () => {
        gate.recv() catch {
          @channel.ChannelClosed => log.push("closed-\{i}")
          _ => log.push("other-error-\{i}")
        }
      }),
    )
  }
  assert_eq(log, [])
  gate.close()
  ignore(@coroutine.Coroutine(name="drain", () => ()))
  assert_eq(log, ["closed-0", "closed-1", "closed-2"])
}

///|
test "Channel close: buffered values drain before the close is observed" {
  let gate : @channel.Channel[Int32] = @channel.Channel::new()
  gate.send(1)
  gate.send(2)
  gate.close()
  let log : Array[String] = []
  ignore(
    @coroutine.Coroutine(name="receiver", () => {
      let first = gate.recv()
      let second = gate.recv()
      log.push("\{first},\{second}")
      let third = gate.recv() catch {
        @channel.ChannelClosed => -1
        _ => -2
      }
      log.push("third=\{third}")
    }),
  )
  ignore(@coroutine.Coroutine(name="drain", () => ()))
  assert_eq(log, ["1,2", "third=-1"])
}

///|
test "Channel close: idempotent, and recv on a drained closed channel raises" {
  let gate : @channel.Channel[Int32] = @channel.Channel::new()
  gate.close()
  gate.close() // idempotent: teardown paths may close more than once
  let error = @test.expect_error(() => gate.recv())
  assert_true(error is @channel.ChannelClosed)
}

///|
test "Channel close: wakes a select case waiting on the channel" {
  let gate : @channel.Channel[Int32] = @channel.Channel::new()
  let log : Array[String] = []
  ignore(
    @coroutine.Coroutine(name="selector", () => {
      defer log.push("cleanup")
      let value = @select.select(s => gate.recv_map_to(s, value => value * 2))
      log.push("value=\{value}")
    }),
  )
  gate.close()
  // Dropping this spawn lets the selector unwind; its `ChannelClosed` is handed
  // to the creator, so the spawn itself raises it.
  let error = @test.expect_error(() => {
    ignore(@coroutine.Coroutine(name="drain", () => ()))
  })
  assert_true(error is @channel.ChannelClosed)
  assert_eq(log, ["cleanup"])
}

///|
test "Channel close: an unmapped select case observes the close too" {
  let gate : @channel.Channel[Int32] = @channel.Channel::new()
  let other : @channel.Channel[Int32] = @channel.Channel::new()
  let log : Array[String] = []
  ignore(
    @coroutine.Coroutine(name="selector", () => {
      defer log.push("cleanup")
      let value = @select.select(s => {
        other.recv_map_to(s, value => value * 10)
        gate.recv_to(s)
      })
      log.push("value=\{value}")
    }),
  )
  gate.close()
  let error = @test.expect_error(() => {
    ignore(@coroutine.Coroutine(name="drain", () => ()))
  })
  assert_true(error is @channel.ChannelClosed)
  assert_eq(log, ["cleanup"])
}

///|
test "Channel close: a value delivered before the close still wins" {
  let gate : @channel.Channel[Int32] = @channel.Channel::new()
  let log : Array[String] = []
  ignore(
    @coroutine.Coroutine(name="selector", () => {
      let value = @select.select(s => gate.recv_map_to(s, value => value * 2))
      log.push("value=\{value}")
    }),
  )
  // The send claims the case and schedules the selector; the close then finds
  // the case already claimed and must not override the delivered value.
  gate.send(21)
  gate.close()
  ignore(@coroutine.Coroutine(name="drain", () => ()))
  assert_eq(log, ["value=42"])
}
