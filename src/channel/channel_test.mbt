///|
using @test {assert_eq}

///|
test "unbuffered channel: send suspends until recv" {
  let chan : @channel.Channel[Int32] = @channel.Channel(0)
  let log : Array[String] = []
  let done = @future.Future::new()
  let _ = @coroutine.Coroutine(() => {
    log.push("send:before")
    chan.send(42)
    log.push("send:after")
    done.set(())
  })
  log.push("recv:before")
  let value = chan.recv()
  log.push("recv:after")
  done.wait()
  assert_eq(value, 42)
  json_inspect(log, content=[
    "send:before", "recv:before", "recv:after", "send:after",
  ])
}

///|
test "unbuffered channel: multiple senders wake in FIFO order" {
  let chan : @channel.Channel[Int32] = @channel.Channel(0)
  let order : Array[String] = []
  let done1 = @future.Future::new()
  let done2 = @future.Future::new()
  let _ = @coroutine.Coroutine(() => {
    chan.send(1)
    order.push("s1")
    done1.set(())
  })
  let _ = @coroutine.Coroutine(() => {
    chan.send(2)
    order.push("s2")
    done2.set(())
  })
  assert_eq(chan.recv(), 1)
  done1.wait()
  assert_eq(order, ["s1"])
  assert_eq(chan.recv(), 2)
  done2.wait()
  assert_eq(order, ["s1", "s2"])
}

///|
test "bounded channel: buffers up to capacity then suspends and preserves FIFO" {
  let chan : @channel.Channel[Int32] = @channel.Channel(2)
  let log : Array[String] = []
  let done1 = @future.Future::new()
  let done2 = @future.Future::new()
  chan.send(1)
  chan.send(2)
  let _ = @coroutine.Coroutine(() => {
    log.push("s3:before")
    chan.send(3)
    log.push("s3:after")
    done1.set(())
  })
  let _ = @coroutine.Coroutine(() => {
    log.push("s4:before")
    chan.send(4)
    log.push("s4:after")
    done2.set(())
  })
  json_inspect(log, content=["s3:before", "s4:before"])
  assert_eq(chan.recv(), 1)
  done1.wait()
  json_inspect(log, content=["s3:before", "s4:before", "s3:after"])
  assert_eq(chan.recv(), 2)
  done2.wait()
  json_inspect(log, content=["s3:before", "s4:before", "s3:after", "s4:after"])
  assert_eq(chan.recv(), 3)
  assert_eq(chan.recv(), 4)
}

///|
test "send_to: ready path via buffer space" {
  let chan : @channel.Channel[Int32] = @channel.Channel(1)
  let idx = @select.select <| selector => { chan.send_to(selector) }
  assert_eq(idx, 0)
  chan.send(7)
  assert_eq(chan.recv(), 7)
}

///|
test "send_to: ready path via waiting reader" {
  let chan : @channel.Channel[Int32] = @channel.Channel(0)
  let got = @future.Future::new()
  let _ = @coroutine.Coroutine(() => got.set(chan.recv()))
  let idx = @select.select <| selector => { chan.send_to(selector) }
  assert_eq(idx, 0)
  chan.send(9)
  assert_eq(got.wait(), 9)
}

///|
test "send_to: returns index of ready channel and ignores zombies" {
  let a : @channel.Channel[Int32] = @channel.Channel(0)
  let b : @channel.Channel[Int32] = @channel.Channel(0)
  let c : @channel.Channel[Int32] = @channel.Channel(0)
  let chosen = @future.Future::new()
  let _ = @coroutine.Coroutine(() => {
    let idx = @select.select <| selector => {
      a.send_to(selector)
      b.send_to(selector)
      c.send_to(selector)
    }
    chosen.set(idx)
    if idx == 2 {
      c.send(30)
    }
  })
  assert_eq(c.recv(), 30)
  assert_eq(chosen.wait(), 2)
  // Leftover registrations on `a` and `b` must be zombies and inert.
  let sent_a = @future.Future::new()
  let _ = @coroutine.Coroutine(() => {
    a.send(99)
    sent_a.set(())
  })
  assert_eq(a.recv(), 99)
  sent_a.wait()
}

///|
test "send_to: early poll win leaves zombie registration inert" {
  let a : @channel.Channel[Int32] = @channel.Channel(0)
  let b : @channel.Channel[Int32] = @channel.Channel(1)
  let idx = @select.select <| selector => {
    a.send_to(selector)
    b.send_to(selector)
  }
  assert_eq(idx, 1)
  b.send(2)
  assert_eq(b.recv(), 2)
  // `a` had a send registration before `b` won immediately; it must be inert.
  let sent_fresh = @future.Future::new()
  let _ = @coroutine.Coroutine(() => {
    a.send(42)
    sent_fresh.set(())
  })
  assert_eq(a.recv(), 42)
  sent_fresh.wait()
}

///|
test "select: send_to paired with recv_to across two coroutines" {
  let chan : @channel.Channel[Int32] = @channel.Channel(0)
  let got = @future.Future::new()
  let sent = @future.Future::new()
  let _ = @coroutine.Coroutine(() => {
    let idx = @select.select <| selector => { chan.send_to(selector) }
    if idx == 0 {
      chan.send(123)
    }
    sent.set(idx)
  })
  let _ = @coroutine.Coroutine(() => {
    let idx = @select.select <| selector => { chan.recv_to(selector) }
    got.set((idx, chan.recv()))
  })
  assert_eq(got.wait(), (0, 123))
  assert_eq(sent.wait(), 0)
}

///|
test "select: recv_to parked first, paired with send_to across two coroutines" {
  let chan : @channel.Channel[Int32] = @channel.Channel(0)
  let got = @future.Future::new()
  let sent = @future.Future::new()
  let _ = @coroutine.Coroutine(() => {
    let idx = @select.select <| selector => { chan.recv_to(selector) }
    got.set((idx, chan.recv()))
  })
  let _ = @coroutine.Coroutine(() => {
    let idx = @select.select <| selector => { chan.send_to(selector) }
    if idx == 0 {
      chan.send(456)
    }
    sent.set(idx)
  })
  assert_eq(got.wait(), (0, 456))
  assert_eq(sent.wait(), 0)
}

///|
test "select: send and recv on the same unbuffered channel do not match each other" {
  // send registered first, then recv; external recv wakes send branch (0).
  let c1 : @channel.Channel[Int32] = @channel.Channel(0)
  let r1 = @future.Future::new()
  let _ = @coroutine.Coroutine(() => {
    let idx = @select.select <| selector => {
      c1.send_to(selector)
      c1.recv_to(selector)
    }
    if idx == 0 {
      c1.send(10)
    }
    r1.set(idx)
  })
  assert_eq(c1.recv(), 10)
  assert_eq(r1.wait(), 0)

  // send registered first, then recv; external send wakes recv branch (1).
  let c2 : @channel.Channel[Int32] = @channel.Channel(0)
  let r2 = @future.Future::new()
  let _ = @coroutine.Coroutine(() => {
    let idx = @select.select <| selector => {
      c2.send_to(selector)
      c2.recv_to(selector)
    }
    let val = if idx == 1 { c2.recv() } else { -1 }
    r2.set((idx, val))
  })
  c2.send(20)
  assert_eq(r2.wait(), (1, 20))

  // recv registered first, then send; external recv wakes send branch (1).
  let c3 : @channel.Channel[Int32] = @channel.Channel(0)
  let r3 = @future.Future::new()
  let _ = @coroutine.Coroutine(() => {
    let idx = @select.select <| selector => {
      c3.recv_to(selector)
      c3.send_to(selector)
    }
    if idx == 1 {
      c3.send(30)
    }
    r3.set(idx)
  })
  assert_eq(c3.recv(), 30)
  assert_eq(r3.wait(), 1)

  // recv registered first, then send; external send wakes recv branch (0).
  let c4 : @channel.Channel[Int32] = @channel.Channel(0)
  let r4 = @future.Future::new()
  let _ = @coroutine.Coroutine(() => {
    let idx = @select.select <| selector => {
      c4.recv_to(selector)
      c4.send_to(selector)
    }
    let val = if idx == 0 { c4.recv() } else { -1 }
    r4.set((idx, val))
  })
  c4.send(40)
  assert_eq(r4.wait(), (0, 40))
}

///|
test "select: send and recv on the same buffered channel" {
  // Empty buffer: recv registers (0), then send wins via buffer space (1).
  let c1 : @channel.Channel[Int32] = @channel.Channel(1)
  let idx1 = @select.select <| selector => {
    c1.recv_to(selector)
    c1.send_to(selector)
  }
  assert_eq(idx1, 1)
  c1.send(1)
  assert_eq(c1.recv(), 1)

  // Full buffer: send registers (0), then recv wins via buffered item (1).
  let c2 : @channel.Channel[Int32] = @channel.Channel(1)
  c2.send(10)
  let idx2 = @select.select <| selector => {
    c2.send_to(selector)
    c2.recv_to(selector)
  }
  assert_eq(idx2, 1)
  assert_eq(c2.recv(), 10)
}

///|
test "manual Selector: send becomes ready before wait() is called" {
  let c : @channel.Channel[Int32] = @channel.Channel(0)
  let s = @select.Selector()
  c.send_to(s)
  let got = @future.Future::new()
  let _ = @coroutine.Coroutine(() => got.set(c.recv()))
  assert_eq(s.wait(), 0)
  c.send(11)
  assert_eq(got.wait(), 11)
}

///|
test "select: skipping own registration preserves FIFO for other selectors" {
  let c1 : @channel.Channel[Int32] = @channel.Channel(0)
  let s1 = @select.Selector()
  c1.send_to(s1)
  let got2 = @future.Future::new()
  let got3 = @future.Future::new()
  let _ = @coroutine.Coroutine(() => {
    let idx = @select.select <| s => { c1.send_to(s) }
    c1.send(2)
    got2.set(idx)
  })
  let _ = @coroutine.Coroutine(() => {
    let idx = @select.select <| s => { c1.send_to(s) }
    c1.send(3)
    got3.set(idx)
  })
  // s1's recv_to skips its own send_to (0) and wakes the first external selector (2).
  c1.recv_to(s1)
  assert_eq(s1.wait(), 1)
  assert_eq(c1.recv(), 2)
  assert_eq(got2.wait(), 0)
  assert_eq(c1.recv(), 3)
  assert_eq(got3.wait(), 0)
}

///|
test "panic negative capacity" {
  let _ : @channel.Channel[Int32] = @channel.Channel(-1)
}
