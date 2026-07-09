///|
// A recv_map_to reader left behind by a completed select must not claim later
// sends: the wake-path closure has to flip the claim flag, or the zombie eats
// the value and ghost-schedules the (already finished) selecting coroutine.
test "recv_map_to zombie reader must not consume later sends" {
  let a : @channel.Channel[Int] = @channel.Channel::new()
  let b : @channel.Channel[Int] = @channel.Channel::new()
  let result = @future.Future::new()
  let _ = @coroutine.spawn(name="selector", () => {
    result.set(
      @select.select <| selector => {
        a.recv_map_to(selector) <| x => { x }
        b.recv_map_to(selector) <| y => { y }
      },
    )
  })
  // selector is suspended with readers registered on both channels.
  a.send(1)
  inspect(result.wait(), content="1")
  // select already finished via A; B's leftover reader is a zombie now.
  b.send(99)
  inspect(b.recv(), content="99")
}
