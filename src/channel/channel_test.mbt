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
  @select.select <| selector => { chan.send_to(7, selector) }
  assert_eq(chan.recv(), 7)
}

///|
test "send_to: ready path via waiting reader" {
  let chan : @channel.Channel[Int32] = @channel.Channel(0)
  let got = @future.Future::new()
  let _ = @coroutine.Coroutine(() => got.set(chan.recv()))
  @select.select <| selector => { chan.send_to(9, selector) }
  assert_eq(got.wait(), 9)
}

///|
test "send_to: suspend path wakes on recv" {
  let a : @channel.Channel[Int32] = @channel.Channel(0)
  let b : @channel.Channel[Int32] = @channel.Channel(0)
  let done = @future.Future::new()
  let _ = @coroutine.Coroutine(() => {
    @select.select <| selector => {
      a.send_to(1, selector)
      b.send_to(2, selector)
    }
    done.set(())
  })
  assert_eq(b.recv(), 2)
  done.wait()
  // Leftover SendTo writer on `a` must be a zombie and not deliver stale `1`.
  let sent_fresh = @future.Future::new()
  let _ = @coroutine.Coroutine(() => {
    a.send(99)
    sent_fresh.set(())
  })
  assert_eq(a.recv(), 99)
  sent_fresh.wait()
}

///|
test "send_to: early poll win leaves zombie writer inert" {
  let a : @channel.Channel[Int32] = @channel.Channel(0)
  let b : @channel.Channel[Int32] = @channel.Channel(1)
  @select.select <| selector => {
    a.send_to(1, selector)
    b.send_to(2, selector)
  }
  assert_eq(b.recv(), 2)
  // `a` had a SendTo registered before `b` won immediately; it must be inert.
  let sent_fresh = @future.Future::new()
  let _ = @coroutine.Coroutine(() => {
    a.send(42)
    sent_fresh.set(())
  })
  assert_eq(a.recv(), 42)
  sent_fresh.wait()
}

///|
test "send_map_to: ready path and suspend path" {
  let a : @channel.Channel[Int32] = @channel.Channel(1)
  let b : @channel.Channel[Int32] = @channel.Channel(1)
  a.send(10)
  let r1 = @select.select <| selector => {
    a.send_map_to(20, selector) <| () => { "a" }
    b.send_map_to(30, selector) <| () => { "b" }
  }
  assert_eq(r1, "b")
  assert_eq(a.recv(), 10)
  assert_eq(b.recv(), 30)
  // `a`'s leftover SendMapTo(20) was a zombie; `a` must be empty now.
  a.send(55)
  assert_eq(a.recv(), 55)
}

///|
test "send_map_to: wake-path mapper is deferred past recv()" {
  let chan : @channel.Channel[Int32] = @channel.Channel(0)
  let order : Array[String] = []
  let result = @future.Future::new()
  let _ = @coroutine.Coroutine(() => {
    let selector = @select.Selector()
    chan.send_map_to(1, selector) <| () => {
      order.push("mapper")
      "sent"
    }
    result.set(selector.wait())
  })
  order.push("recv:before")
  assert_eq(chan.recv(), 1)
  order.push("recv:after")
  assert_eq(result.wait(), "sent")
  json_inspect(order, content=["recv:before", "recv:after", "mapper"])
}

///|
test "send_map_to: wake-path mapper may block on another channel without deadlocking" {
  let c1 : @channel.Channel[Int32] = @channel.Channel(0)
  let c2 : @channel.Channel[Int32] = @channel.Channel(0)
  let result = @future.Future::new()
  let _ = @coroutine.Coroutine(() => {
    result.set(
      @select.select <| selector => {
        c1.send_map_to(10, selector) <| () => { c2.recv() }
      },
    )
  })
  let v = c1.recv()
  c2.send(v + 5)
  assert_eq(result.wait(), 15)
}

///|
test "send_map_to: zombie writer must not deliver stale value" {
  let a : @channel.Channel[Int32] = @channel.Channel(0)
  let b : @channel.Channel[Int32] = @channel.Channel(0)
  let result = @future.Future::new()
  let _ = @coroutine.Coroutine(() => {
    result.set(
      @select.select <| selector => {
        a.send_map_to(1, selector) <| () => { "a" }
        b.send_map_to(2, selector) <| () => { "b" }
      },
    )
  })
  assert_eq(a.recv(), 1)
  assert_eq(result.wait(), "a")
  let done = @future.Future::new()
  let _ = @coroutine.Coroutine(() => {
    b.send(99)
    done.set(())
  })
  assert_eq(b.recv(), 99)
  done.wait()
}

///|
test "send_map_to: mapper re-entering sibling case must not double-claim" {
  let a : @channel.Channel[Int32] = @channel.Channel(0)
  let b : @channel.Channel[Int32] = @channel.Channel(0)
  let log : Array[String] = []
  let result = @future.Future::new()
  let mut got_b = -1
  let _ = @coroutine.Coroutine(() => {
    let r = @select.select <| selector => {
      a.send_map_to(1, selector) <| () => {
        log.push("sendA")
        // Re-enter sibling case `b` while `a` won.
        let _ = @coroutine.Coroutine(() => b.send(99))
        got_b = b.recv()
        "A"
      }
      b.recv_map_to(selector) <| y => {
        log.push("recvB(\{y})")
        "B:\{y}"
      }
    }
    result.set(r)
  })
  assert_eq(a.recv(), 1)
  assert_eq(result.wait(), "A")
  assert_eq(got_b, 99)
  json_inspect(log, content=["sendA"])
}

///|
test "select: send_to paired with recv_to across two coroutines" {
  let chan : @channel.Channel[Int32] = @channel.Channel(0)
  let got = @future.Future::new()
  let sent = @future.Future::new()
  let _ = @coroutine.Coroutine(() => {
    @select.select <| selector => { chan.send_to(123, selector) }
    sent.set(())
  })
  let _ = @coroutine.Coroutine(() => {
    got.set(@select.select <| selector => { chan.recv_to(selector) })
  })
  assert_eq(got.wait(), 123)
  sent.wait()
}

///|
test "select: send_map_to paired with recv_map_to across two coroutines" {
  let chan : @channel.Channel[Int32] = @channel.Channel(0)
  let got = @future.Future::new()
  let sent = @future.Future::new()
  let _ = @coroutine.Coroutine(() => {
    got.set(
      @select.select <| selector => {
        chan.recv_map_to(selector) <| x => { x * 2 }
      },
    )
  })
  let _ = @coroutine.Coroutine(() => {
    sent.set(
      @select.select <| selector => {
        chan.send_map_to(21, selector) <| () => { "ok" }
      },
    )
  })
  assert_eq(got.wait(), 42)
  assert_eq(sent.wait(), "ok")
}

///|
test "select: send and recv on the same unbuffered channel do not match each other" {
  // send registered first, then recv; external recv wakes send branch.
  let c1 : @channel.Channel[Int32] = @channel.Channel(0)
  let r1 = @future.Future::new()
  let _ = @coroutine.Coroutine(() => {
    r1.set(
      @select.select <| selector => {
        c1.send_map_to(10, selector) <| () => { "sent" }
        c1.recv_map_to(selector) <| x => { "recvd:\{x}" }
      },
    )
  })
  assert_eq(c1.recv(), 10)
  assert_eq(r1.wait(), "sent")

  // send registered first, then recv; external send wakes recv branch.
  let c2 : @channel.Channel[Int32] = @channel.Channel(0)
  let r2 = @future.Future::new()
  let _ = @coroutine.Coroutine(() => {
    r2.set(
      @select.select <| selector => {
        c2.send_map_to(10, selector) <| () => { "sent" }
        c2.recv_map_to(selector) <| x => { "recvd:\{x}" }
      },
    )
  })
  c2.send(20)
  assert_eq(r2.wait(), "recvd:20")

  // recv registered first, then send; external recv wakes send branch.
  let c3 : @channel.Channel[Int32] = @channel.Channel(0)
  let r3 = @future.Future::new()
  let _ = @coroutine.Coroutine(() => {
    r3.set(
      @select.select <| selector => {
        c3.recv_map_to(selector) <| x => { "recvd:\{x}" }
        c3.send_map_to(30, selector) <| () => { "sent" }
      },
    )
  })
  assert_eq(c3.recv(), 30)
  assert_eq(r3.wait(), "sent")

  // recv registered first, then send; external send wakes recv branch.
  let c4 : @channel.Channel[Int32] = @channel.Channel(0)
  let r4 = @future.Future::new()
  let _ = @coroutine.Coroutine(() => {
    r4.set(
      @select.select <| selector => {
        c4.recv_map_to(selector) <| x => { "recvd:\{x}" }
        c4.send_map_to(30, selector) <| () => { "sent" }
      },
    )
  })
  c4.send(40)
  assert_eq(r4.wait(), "recvd:40")
}

///|
test "select: send and recv on the same buffered channel" {
  // Empty buffer: recv registers, then send wins via buffer space.
  let c1 : @channel.Channel[Int32] = @channel.Channel(1)
  let r1 = @select.select <| selector => {
    c1.recv_map_to(selector) <| x => { "recvd:\{x}" }
    c1.send_map_to(1, selector) <| () => { "sent" }
  }
  assert_eq(r1, "sent")
  assert_eq(c1.recv(), 1)

  // Full buffer: send registers, then recv wins via buffer pop without
  // admitting the selector's own cancelled send into the buffer.
  let c2 : @channel.Channel[Int32] = @channel.Channel(1)
  c2.send(10)
  let r2 = @select.select <| selector => {
    c2.send_map_to(20, selector) <| () => { "sent" }
    c2.recv_map_to(selector) <| x => { "recvd:\{x}" }
  }
  assert_eq(r2, "recvd:10")
  // Buffer must now be empty (20 was NOT sent).
  c2.send(30)
  assert_eq(c2.recv(), 30)
}

///|
test "manual Selector: send completes before wait() is called" {
  let c1 : @channel.Channel[Int32] = @channel.Channel(0)
  let s1 : @select.Selector[Unit] = @select.Selector()
  c1.send_to(11, s1)
  let got1 = @future.Future::new()
  let _ = @coroutine.Coroutine(() => got1.set(c1.recv()))
  s1.wait()
  assert_eq(got1.wait(), 11)

  let c2 : @channel.Channel[Int32] = @channel.Channel(0)
  let s2 : @select.Selector[String] = @select.Selector()
  c2.send_map_to(22, s2) <| () => { "mapped" }
  let got2 = @future.Future::new()
  let _ = @coroutine.Coroutine(() => got2.set(c2.recv()))
  assert_eq(s2.wait(), "mapped")
  assert_eq(got2.wait(), 22)
}

///|
test "panic negative capacity" {
  let _ : @channel.Channel[Int32] = @channel.Channel(-1)
}
