///|
// Core regression for deferred mapper execution. On the wake path a case's
// mapper must run in the *selector* after it resumes, never on the sender's
// stack during `send`. This is asserted via ordering so a reintroduced eager
// path fails with a clean diff instead of deadlocking.
test "select: wake-path mapper is deferred past send()" {
  let chan : @co.Channel[Int] = @co.Channel::new()
  let order : Array[String] = []
  let result = @co.Future::new()
  let _ = @co.Task::new(name="selector", () => {
    result.set(
      @co.select([
        chan.on_recv(x => {
          order.push("mapper")
          x
        }),
      ]),
    )
  })
  // `selector` is suspended with a reader registered on `chan`.
  order.push("send:before")
  chan.send(1)
  order.push("send:after")
  let r = result.wait()
  inspect(r, content="1")
  // Deferred: the mapper ran only after send() returned to the sender, i.e. in
  // the selector. Eager execution would interleave "mapper" between the two.
  json_inspect(order, content=["send:before", "send:after", "mapper"])
}

///|
// End-to-end deadlock scenario from the review: a mapper that blocks on another
// channel which the sender only unblocks *after* `send` returns. If the mapper
// ran on the sender's stack it would park inside send(), the selector would
// never be scheduled, and this would hang. Deferring `f` to the selector lets
// the sender finish both sends first.
test "select: mapper may block on another channel without deadlocking" {
  let c1 : @co.Channel[Int] = @co.Channel::new()
  let c2 : @co.Channel[Int] = @co.Channel::new()
  let result = @co.Future::new()
  let _ = @co.Task::new(name="selector", () => {
    result.set(@co.select([c1.on_recv(x => x + c2.recv())]))
  })
  c1.send(1) // wakes the selector's c1 case (deferred)
  c2.send(2) // reached only because send(1) did not block on the mapper
  inspect(result.wait(), content="3")
}
