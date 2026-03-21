///|
test "Channel" {
  let chan = @co.Channel::new()
  let done = @co.Channel::new()
  @co.create(name="f", () => {
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
  let forward = @co.Channel::new()
  let backward = @co.Channel::new()
  let done = @co.Channel::new()
  @co.create(name="f", () => {
    println("f: before forward.send(1)")
    forward.send(1)
    println("f: after forward.send(1)")
    println("f: before backward.recv()")
    println("f: after backward.recv() -> \{backward.recv()}")
    done.send(())
  })
  @co.create(name="g", () => {
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
  let chan : @co.Channel[Int] = @co.Channel::new()
  let done = @co.Channel::new()
  chan.send(1)
  chan.send(2)
  chan.send(3)
  let results = []
  @co.create(name="reader", () => {
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
  let chan : @co.Channel[Int] = @co.Channel::new()
  let done : @co.Channel[Unit] = @co.Channel::new()
  let results = []
  @co.create(name="reader1", () => {
    results.push(("reader1", chan.recv()))
    done.send(())
  })
  @co.create(name="reader2", () => {
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
