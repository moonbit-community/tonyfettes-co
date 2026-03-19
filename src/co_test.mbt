///|
test "Channel" {
  let chan = @co.Channel::new()
  @co.create(name="f", () => {
    println("f: 1")
    println("f: chan.recv() -> \{chan.recv()}")
    println("f: 2")
    println("f: chan.recv() -> \{chan.recv()}")
    println("f: 3")
  })
  println("main: before chan.send(3)")
  chan.send(3)
  println("main: after chan.send(3)")
}

///|
test "Bidirectional: f <-> g" {
  let forward = @co.Channel::new()
  let backward = @co.Channel::new()
  @co.create(name="f", () => {
    println("f: before forward.send(1)")
    forward.send(1)
    println("f: after forward.send(1)")
    println("f: before backward.recv()")
    println("f: after backward.recv() -> \{backward.recv()}")
  })
  @co.create(name="g", () => {
    println("g: before forward.recv()")
    println("g: after forward.recv() -> \{forward.recv()}")
    println("g: before backward.send(2)")
    backward.send(2)
    println("g: after backward.send(2)")
  })
}

///|
test "Channel: values follow FIFO" {
  let chan : @co.Channel[Int] = @co.Channel::new()
  // Send multiple values before any recv — should come back in FIFO order
  chan.send(1)
  chan.send(2)
  chan.send(3)
  let results = []
  @co.create(name="reader", () => {
    results.push(chan.recv())
    results.push(chan.recv())
    results.push(chan.recv())
  })
  assert_eq(results, [1, 2, 3])
}

///|
test "Channel: readers follow FIFO" {
  let chan : @co.Channel[Int] = @co.Channel::new()
  let results = []
  // Two coroutines block on recv; the first to block should be the first resumed
  @co.create(name="reader1", () => results.push(("reader1", chan.recv())))
  @co.create(name="reader2", () => results.push(("reader2", chan.recv())))
  // reader1 blocked first, so it should get 10; reader2 should get 20
  chan.send(10)
  chan.send(20)
  assert_eq(results, [("reader1", 10), ("reader2", 20)])
}

///|
test "Bidirectional: main <-> f" {
  let forward = @co.Channel::new()
  let backward = @co.Channel::new()
  @co.create(name="f", () => {
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
