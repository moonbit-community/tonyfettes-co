///|
using @test {assert_eq}

///|
suberror Boom

///|
test "spawn: value from a body that finishes immediately" {
  let p : @promise.Promise[Int32, Boom] = @promise.spawn(() => 42)
  assert_eq(p.wait(), 42)
}

///|
test "spawn: typed error from a body that finishes immediately" {
  let p : @promise.Promise[Int32, Boom] = @promise.spawn(() => raise Boom)
  let got = p.wait() catch { Boom => -1 }
  assert_eq(got, -1)
}

///|
test "spawn: wait suspends until the body settles" {
  let gate : @future.Future[Int32] = @future.Future::new()
  let ok : @promise.Promise[Int32, Boom] = @promise.spawn(() => gate.wait() + 1)
  let err : @promise.Promise[Int32, Boom] = @promise.spawn(() => {
    ignore(gate.wait())
    raise Boom
  })
  gate.set(1)
  assert_eq(ok.wait(), 2)
  let got = err.wait() catch { Boom => -1 }
  assert_eq(got, -1)
}

///|
test "every waiter is woken" {
  let p : @promise.Promise[Int32, Boom] = @promise.Promise::new()
  let results : Array[Int32] = []
  let done : @future.Future[Unit] = @future.Future::new()
  for _ in 0..<3 {
    ignore(
      @coroutine.Coroutine(() => {
        results.push(p.wait() catch { Boom => -1 })
        if results.length() == 3 {
          done.set(())
        }
      }),
    )
  }
  p.resolve(7)
  done.wait()
  assert_eq(results, [7, 7, 7])
}

///|
test "every waiter sees the error" {
  let p : @promise.Promise[Int32, Boom] = @promise.Promise::new()
  let results : Array[Int32] = []
  let done : @future.Future[Unit] = @future.Future::new()
  for _ in 0..<2 {
    ignore(
      @coroutine.Coroutine(() => {
        results.push(p.wait() catch { Boom => -1 })
        if results.length() == 2 {
          done.set(())
        }
      }),
    )
  }
  p.reject(Boom)
  done.wait()
  assert_eq(results, [-1, -1])
}

///|
test "wait after settling returns without suspending" {
  let p : @promise.Promise[Int32, Boom] = @promise.Promise::new()
  p.resolve(3)
  assert_eq(p.wait(), 3)
  assert_eq(p.wait(), 3)
}
