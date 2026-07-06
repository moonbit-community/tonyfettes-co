///|
// Reproduces the double-claim race: a winning case's mapper re-enters another
// case of the same `select`. Because the claim is not made visible before the
// mapper runs, the sibling case also claims and consumes its value, which is
// then silently dropped when the outer assignment overwrites the box.
test "select: mapper re-entering a sibling case must not consume it" {
  let a : @co.Channel[Int] = @co.Channel::new()
  let b : @co.Channel[Int] = @co.Channel::new()
  let log : Array[String] = []
  let result = @co.Future::new()
  let _ = @co.Task::new(name="selector", () => {
    let r = @co.select([
      a.on_recv(x => {
        log.push("mapA(\{x})")
        // re-enter a sibling case of the same select while A is being claimed
        b.send(99)
        "A:\{x}"
      }),
      b.on_recv(y => {
        log.push("mapB(\{y})")
        "B:\{y}"
      }),
    ])
    result.set(r)
  })
  // `selector` is now suspended with readers registered on both `a` and `b`.
  a.send(1)
  let r = result.wait()
  // `select` chose A, so B's mapper must NOT run and the 99 sent to `b` must be
  // preserved in the channel for a later reader. Correct behavior: only mapA ran.
  json_inspect(log, content=["mapA(1)"])
  inspect(r, content="A:1")
}
