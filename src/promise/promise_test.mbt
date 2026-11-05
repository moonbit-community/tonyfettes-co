///|
using @test {assert_eq}

///|
suberror Boom

///|
test "value from a body that finishes immediately" {
  let p : @promise.Promise[Int, Boom] = @promise.Promise(() => 42)
  assert_eq(p.wait(), 42)
}

///|
test "typed error from a body that finishes immediately" {
  let p : @promise.Promise[Int, Boom] = @promise.Promise(() => raise Boom)
  let got = p.wait() catch { Boom => -1 }
  assert_eq(got, -1)
}

///|
test "wait suspends until the body settles" {
  let gate : @channel.Channel[Int] = @channel.Channel::new()
  let ok : @promise.Promise[Int, Boom] = @promise.Promise(() => {
    gate.recv() + 1
  })
  let err : @promise.Promise[Int, Boom] = @promise.Promise(() => {
    ignore(gate.recv())
    raise Boom
  })
  gate.send(1)
  gate.send(2)
  assert_eq(ok.wait(), 2)
  let got = err.wait() catch { Boom => -1 }
  assert_eq(got, -1)
}

///|
test "every waiter is woken" {
  let gate : @channel.Channel[Int] = @channel.Channel::new()
  let p : @promise.Promise[Int, Boom] = @promise.Promise(() => gate.recv())
  let results : Array[Int] = []
  let done : @channel.Channel[Unit] = @channel.Channel::new()
  for _ in 0..<3 {
    ignore(
      @coroutine.Coroutine(() => {
        results.push(p.wait() catch { Boom => -1 })
        done.send(())
      }),
    )
  }
  gate.send(7)
  for _ in 0..<3 {
    done.recv()
  }
  assert_eq(results, [7, 7, 7])
}

///|
test "every waiter sees the error" {
  let gate : @channel.Channel[Unit] = @channel.Channel::new()
  let p : @promise.Promise[Int, Boom] = @promise.Promise(() => {
    gate.recv()
    raise Boom
  })
  let results : Array[Int] = []
  let done : @channel.Channel[Unit] = @channel.Channel::new()
  for _ in 0..<2 {
    ignore(
      @coroutine.Coroutine(() => {
        results.push(p.wait() catch { Boom => -1 })
        done.send(())
      }),
    )
  }
  gate.send(())
  for _ in 0..<2 {
    done.recv()
  }
  assert_eq(results, [-1, -1])
}

///|
test "wait after settling returns without suspending" {
  let p : @promise.Promise[Int, Boom] = @promise.Promise(() => 3)
  assert_eq(p.wait(), 3)
  assert_eq(p.wait(), 3)
}
