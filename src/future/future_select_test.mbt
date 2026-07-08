///|
test "future: select ready path takes the first registered case" {
  let int_fut : @future.Future[Int] = @future.Future::new()
  int_fut.set(3)
  let str_fut : @future.Future[String] = @future.Future::new()
  str_fut.set("string")
  inspect(
    @select.select <| selector => {
      int_fut.wait_map_to(selector) <| int => { int.to_string() }
      str_fut.wait_to(selector)
    },
    content="3",
  )
}

///|
test "future: select wakes when a pending future is set" {
  let a : @future.Future[Int] = @future.Future::new()
  let b : @future.Future[Int] = @future.Future::new()
  let result = @future.Future::new()
  let _ = @coroutine.Coroutine::new(name="selector", () => {
    result.set(
      @select.select <| selector => {
        a.wait_to(selector)
        b.wait_to(selector)
      },
    )
  })
  // selector is suspended with waiters registered on both futures.
  b.set(42)
  inspect(result.wait(), content="42")
  // select already finished via B; A's leftover WaitTo waiter must be inert.
  a.set(1)
  inspect(a.wait(), content="1")
}

///|
// Wake-path mapper must run in the selecting coroutine after it resumes,
// never on the setter's stack during `set` (mirrors the channel defer test).
test "future: wake-path mapper is deferred past set()" {
  let a : @future.Future[Int] = @future.Future::new()
  let order : Array[String] = []
  let result = @future.Future::new()
  let _ = @coroutine.Coroutine::new(name="selector", () => {
    let selector = @select.Selector()
    a.wait_map_to(selector) <| x => {
      order.push("mapper")
      x
    }
    result.set(selector.wait())
  })
  order.push("set:before")
  a.set(1)
  order.push("set:after")
  inspect(result.wait(), content="1")
  json_inspect(order, content=["set:before", "set:after", "mapper"])
}

///|
// A completed select's leftover wait_map_to waiter still fires when its future
// is eventually set; the completed guard must make it a no-op instead of
// ghost-scheduling the (already finished) selecting coroutine.
test "future: leftover wait_map_to waiter is inert after select completes" {
  let a : @future.Future[Int] = @future.Future::new()
  let b : @future.Future[Int] = @future.Future::new()
  let result = @future.Future::new()
  let _ = @coroutine.Coroutine::new(name="selector", () => {
    result.set(
      @select.select <| selector => {
        a.wait_map_to(selector) <| x => { x }
        b.wait_map_to(selector) <| y => { y }
      },
    )
  })
  a.set(1)
  inspect(result.wait(), content="1")
  b.set(99)
  inspect(b.wait(), content="99")
}
