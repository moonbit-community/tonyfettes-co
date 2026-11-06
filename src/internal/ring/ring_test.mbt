///|
test "fifo order across wrap-around and growth" {
  let ring : @ring.Ring[Int32] = @ring.Ring()
  let out : Array[Int32] = []
  for i in 0..<5 {
    ring.push_back(i)
  }
  for _ in 0..<3 {
    out.push(ring.pop_front().unwrap_or(-1))
  }
  for i in 5..<20 {
    ring.push_back(i)
  }
  while ring.pop_front() is Some(v) {
    out.push(v)
  }
  @test.assert_eq(out, Array::makei(20, i => i))
  @test.assert_eq(ring.is_empty(), true)
  @test.assert_eq(ring.pop_front(), None)
}

///|
test "push_front puts a value back ahead of the queue" {
  let ring : @ring.Ring[Int32] = @ring.Ring()
  ring.push_front(1) // grows from empty
  for i in 2..<10 {
    ring.push_back(i) // fills and grows with head at the end of the buffer
  }
  let first = ring.pop_front().unwrap()
  ring.push_front(first)
  ring.push_front(0)
  let out : Array[Int32] = []
  while ring.pop_front() is Some(v) {
    out.push(v)
  }
  @test.assert_eq(out, Array::makei(10, i => i))
}
