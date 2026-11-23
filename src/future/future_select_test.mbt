///|
test "future: select ready path takes the first registered case" {
  let int_fut : @future.Future[Int32] = @future.Future::new()
  int_fut.set(3)
  let str_fut : @future.Future[String] = @future.Future::new()
  str_fut.set("string")
  let ready = @select.select <| selector => {
    int_fut.wait_to(selector)
    str_fut.wait_to(selector)
  }
  inspect(ready, content="0")
  inspect(int_fut.wait().to_string(), content="3")
}

///|
test "future: select wakes when a pending future is set" {
  let a : @future.Future[Int32] = @future.Future::new()
  let b : @future.Future[Int32] = @future.Future::new()
  let result = @future.Future::new()
  let _ = @coroutine.Coroutine(() => {
    let idx = @select.select <| selector => {
      a.wait_to(selector)
      b.wait_to(selector)
    }
    result.set((idx, if idx == 0 { a.wait() } else { b.wait() }))
  })
  // selector is suspended with registrations on both futures.
  b.set(42)
  let (idx, val) = result.wait()
  inspect(idx, content="1")
  inspect(val, content="42")
  // select already finished via B; A's leftover registration must be inert.
  a.set(1)
  inspect(a.wait(), content="1")
}
