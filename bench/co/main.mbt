///|
const PINGPONG_ROUNDS : Int = 1_000_000

///|
const CHAN_OPS : Int = 1_000_000

///|
const CHAIN_ROUNDS : Int = 200_000

///|
const CHAIN_DEPTH : Int = 30

///|
const SPAWN_TASKS : Int = 200_000

///|
const PARKED_TASKS : Int = 100_000

///|
fn run(name : String, f : () -> Unit) -> Unit {
  let ts = @bench.monotonic_clock_start()
  f()
  let us = @bench.monotonic_clock_end(ts)
  println("co \{name}: \{us} us")
}

///|
/// Channel throughput without any context switch: fill then drain.
fn bench_chan() -> Unit {
  let chan : @channel.Channel[Int] = @channel.Channel::new()
  for i in 0..<CHAN_OPS {
    chan.send(i)
  }
  let mut sum = 0
  for _ in 0..<CHAN_OPS {
    sum += chan.recv()
  }
  if sum == 0 {
    println("unexpected sum")
  }
}

///|
/// Two tasks bouncing a token: 2 context switches + 2 channel ops per round.
fn bench_pingpong() -> Unit {
  let ping : @channel.Channel[Int] = @channel.Channel::new()
  let pong : @channel.Channel[Int] = @channel.Channel::new()
  let _ = @coroutine.spawn(name="echo", () => {
    for _ in 0..<PINGPONG_ROUNDS {
      pong.send(ping.recv())
    }
  })
  for _ in 0..<PINGPONG_ROUNDS {
    ping.send(1)
    ignore(pong.recv())
  }
}

///|
/// Non-tail recursion so every level keeps a real frame.
fn chain(
  depth : Int,
  ping : @channel.Channel[Int],
  pong : @channel.Channel[Int],
) -> Int {
  if depth == 0 {
    pong.send(ping.recv())
    1
  } else {
    chain(depth - 1, ping, pong) + 1
  }
}

///|
/// Same as pingpong, but the echo side suspends under a 30-frame call stack.
fn bench_chain() -> Unit {
  let ping : @channel.Channel[Int] = @channel.Channel::new()
  let pong : @channel.Channel[Int] = @channel.Channel::new()
  let _ = @coroutine.spawn(name="echo", () => {
    for _ in 0..<CHAIN_ROUNDS {
      ignore(chain(CHAIN_DEPTH, ping, pong))
    }
  })
  for _ in 0..<CHAIN_ROUNDS {
    ping.send(1)
    ignore(pong.recv())
  }
}

///|
/// Spawn a task that runs to completion immediately, N times.
fn bench_spawn() -> Unit {
  let mut count = 0
  for _ in 0..<SPAWN_TASKS {
    let _ = @coroutine.spawn(name="t", () => count += 1)
  }
  if count != SPAWN_TASKS {
    println("spawn mismatch: \{count}")
  }
}

///|
/// Park N coroutines forever; peak RSS is measured from outside the process.
/// Coroutine::suspend documents that the caller must store the handle before
/// parking, so keep every coroutine rooted in `parked` until the function
/// (and with it the process peak) is past the measurement point.
fn bench_parked() -> Unit {
  let parked : Array[@coroutine.Coroutine] = []
  for _ in 0..<PARKED_TASKS {
    parked.push(@coroutine.spawn(name="p", () => @coroutine.suspend()))
  }
  if parked.length() != PARKED_TASKS {
    println("parked mismatch: \{parked.length()}")
  }
}

///|
const SELECT_OPS : Int = 1_000_000

///|
const SELECT_ROUNDS : Int = 1_000_000

///|
/// Two-way select where one channel is always ready: measures the per-call
/// allocation overhead of the select machinery, no context switch.
fn bench_select() -> Unit {
  let a : @channel.Channel[Int] = @channel.Channel::new()
  let b : @channel.Channel[Int] = @channel.Channel::new()
  let mut sum = 0
  for i in 0..<SELECT_OPS {
    if i % 2 == 0 {
      a.send(i)
    } else {
      b.send(i)
    }
    sum += @select.select(s => {
      a.recv_map_to(s, _ => 1)
      b.recv_map_to(s, _ => 1)
    })
  }
  if sum != SELECT_OPS {
    println("select mismatch: \{sum}")
  }
}

///|
/// Pingpong where both sides receive through select: exercises the
/// suspend/deferred-wake path of select.
fn bench_select_suspend() -> Unit {
  let ping : @channel.Channel[Int] = @channel.Channel::new()
  let pong : @channel.Channel[Int] = @channel.Channel::new()
  let _ = @coroutine.spawn(name="echo", () => {
    for _ in 0..<SELECT_ROUNDS {
      pong.send(@select.select(s => ping.recv_map_to(s, x => x)))
    }
  })
  for _ in 0..<SELECT_ROUNDS {
    ping.send(1)
    ignore(@select.select(s => pong.recv_map_to(s, x => x)))
  }
}

///|
fn main {
  let args = @env.args()
  let scenario = if args.length() > 0 { args[args.length() - 1] } else { "" }
  match scenario {
    "chan" => run("chan", bench_chan)
    "pingpong" => run("pingpong", bench_pingpong)
    "chain" => run("chain", bench_chain)
    "spawn" => run("spawn", bench_spawn)
    "parked" => run("parked", bench_parked)
    "select" => run("select", bench_select)
    "select_suspend" => run("select_suspend", bench_select_suspend)
    _ =>
      println(
        "usage: co_bench <chan|pingpong|chain|spawn|parked|select|select_suspend>",
      )
  }
}
