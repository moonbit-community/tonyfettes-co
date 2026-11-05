///|
using @test {assert_eq}

///|
test "Channel" {
  let chan = @channel.Channel::new()
  let done = @channel.Channel::new()
  let _ = @coroutine.Coroutine(() => {
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
  let _ = @coroutine.Coroutine(() => {
    println("f: before forward.send(1)")
    forward.send(1)
    println("f: after forward.send(1)")
    println("f: before backward.recv()")
    println("f: after backward.recv() -> \{backward.recv()}")
    done.send(())
  })
  let _ = @coroutine.Coroutine(() => {
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
  let chan : @channel.Channel[Int] = @channel.Channel::new()
  let done = @channel.Channel::new()
  chan.send(1)
  chan.send(2)
  chan.send(3)
  let results = []
  let _ = @coroutine.Coroutine(() => {
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
  let chan : @channel.Channel[Int] = @channel.Channel::new()
  let done : @channel.Channel[Unit] = @channel.Channel::new()
  let results = []
  let _ = @coroutine.Coroutine(() => {
    results.push(("reader1", chan.recv()))
    done.send(())
  })
  let _ = @coroutine.Coroutine(() => {
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
  let _ = @coroutine.Coroutine(() => {
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
  let _ = @coroutine.Coroutine(() => f.set(21 * 2))
  assert_eq(f.wait(), 42)
}

///|
test "Future: multiple futures" {
  let a = @future.Future::new()
  let b = @future.Future::new()
  let c = @future.Future::new()
  let _ = @coroutine.Coroutine(() => a.set(10))
  let _ = @coroutine.Coroutine(() => b.set(20))
  let _ = @coroutine.Coroutine(() => c.set(30))
  assert_eq(a.wait() + b.wait() + c.wait(), 60)
}

///|
test "Coroutine: spawn and complete" {
  let result = @future.Future::new()
  let _ = @coroutine.Coroutine(() => result.set(42))
  assert_eq(result.wait(), 42)
}

///|
test "Coroutine: a finished handle stays inert after its stack is reused" {
  // `a` finishes inside the spawn, so its stack goes back to the pool.
  let a = @coroutine.Coroutine(() => ())
  // `b` takes that stack and parks on a gate nobody has opened yet.
  let gate : @future.Future[Int] = @future.Future::new()
  let finished : @future.Future[Unit] = @future.Future::new()
  let mut got = -1
  let _ = @coroutine.Coroutine(() => {
    got = gate.wait()
    finished.set(())
  })
  // Scheduling the stale handle must not wake `b`.
  a.schedule()
  // Give the scheduler a round: a woken `b` would run here and find no value.
  let _ = @coroutine.Coroutine(() => ())
  gate.set(1)
  finished.wait()
  assert_eq(got, 1)
}

///|
test "Coroutine: FIFO scheduling order" {
  let order : Array[Int] = []
  let done = @channel.Channel::new()
  let _ = @coroutine.Coroutine(() => {
    order.push(1)
    done.send(())
  })
  let _ = @coroutine.Coroutine(() => {
    order.push(2)
    done.send(())
  })
  let _ = @coroutine.Coroutine(() => {
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
  let results : Array[Int] = []
  let done = @channel.Channel::new()
  let _ = @coroutine.Coroutine(() => {
    results.push(f.wait())
    done.send(())
  })
  let _ = @coroutine.Coroutine(() => {
    results.push(f.wait())
    done.send(())
  })
  let _ = @coroutine.Coroutine(() => {
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
  let chan : @channel.Channel[Int] = @channel.Channel::new()
  let woken : Array[String] = []
  let done = @channel.Channel::new()
  let _ = @coroutine.Coroutine(() => {
    let _ = chan.recv()
    woken.push("r1")
    done.send(())
  })
  let _ = @coroutine.Coroutine(() => {
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
  let _ = @coroutine.Coroutine(() => {
    let v = chan.recv()
    println("waiter: chan.recv() -> \{v}")
    f.set(v * 2)
  })
  chan.send(5)
  println("main: chan.send(5)")
  assert_eq(f.wait(), 10)
}
