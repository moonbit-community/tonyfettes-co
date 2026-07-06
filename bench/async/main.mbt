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
async fn run(name : String, f : async () -> Unit) -> Unit {
  let ts = @bench.monotonic_clock_start()
  f()
  let us = @bench.monotonic_clock_end(ts)
  println("async \{name}: \{us} us")
}

///|
/// Queue throughput without any suspension: fill then drain.
async fn bench_chan() -> Unit {
  let queue : @aqueue.Queue[Int] = @aqueue.Queue(kind=Unbounded)
  for i in 0..<CHAN_OPS {
    queue.put(i)
  }
  let mut sum = 0
  for _ in 0..<CHAN_OPS {
    sum += queue.get()
  }
  if sum == 0 {
    println("unexpected sum")
  }
}

///|
/// Two tasks bouncing a token: 2 suspensions + 2 queue ops per round.
async fn bench_pingpong() -> Unit {
  let ping : @aqueue.Queue[Int] = @aqueue.Queue(kind=Unbounded)
  let pong : @aqueue.Queue[Int] = @aqueue.Queue(kind=Unbounded)
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      for _ in 0..<PINGPONG_ROUNDS {
        pong.put(ping.get())
      }
    })
    for _ in 0..<PINGPONG_ROUNDS {
      ping.put(1)
      ignore(pong.get())
    }
  })
}

///|
/// Non-tail recursion so every level keeps a real frame.
async fn chain(
  depth : Int,
  ping : @aqueue.Queue[Int],
  pong : @aqueue.Queue[Int],
) -> Int {
  if depth == 0 {
    pong.put(ping.get())
    1
  } else {
    chain(depth - 1, ping, pong) + 1
  }
}

///|
/// Same as pingpong, but the echo side suspends under a 30-frame async chain.
async fn bench_chain() -> Unit {
  let ping : @aqueue.Queue[Int] = @aqueue.Queue(kind=Unbounded)
  let pong : @aqueue.Queue[Int] = @aqueue.Queue(kind=Unbounded)
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      for _ in 0..<CHAIN_ROUNDS {
        ignore(chain(CHAIN_DEPTH, ping, pong))
      }
    })
    for _ in 0..<CHAIN_ROUNDS {
      ping.put(1)
      ignore(pong.get())
    }
  })
}

///|
/// Spawn a task that runs to completion immediately, N times.
async fn bench_spawn() -> Unit {
  let mut count = 0
  @async.with_task_group(group => {
    for _ in 0..<SPAWN_TASKS {
      group.spawn_bg(() => count += 1)
    }
  })
  if count != SPAWN_TASKS {
    println("spawn mismatch: \{count}")
  }
}

///|
/// Park N tasks on a long sleep; peak RSS is measured from outside the
/// process. no_wait children are canceled as soon as the group body exits,
/// so the body must not return until every child has entered its sleep:
/// each child bumps the counter and immediately suspends into sleep (no
/// suspension point between the two), so counter == N implies all parked.
async fn bench_parked() -> Unit {
  let mut parked = 0
  @async.with_task_group(group => {
    for _ in 0..<PARKED_TASKS {
      group.spawn_bg(no_wait=true, () => {
        parked += 1
        @async.sleep(3_600_000)
      })
    }
    while parked < PARKED_TASKS {
      @async.pause()
    }
  })
}

///|
async fn main {
  let args = @env.args()
  let scenario = if args.length() > 0 { args[args.length() - 1] } else { "" }
  match scenario {
    "chan" => run("chan", bench_chan)
    "pingpong" => run("pingpong", bench_pingpong)
    "chain" => run("chain", bench_chain)
    "spawn" => run("spawn", bench_spawn)
    "parked" => run("parked", bench_parked)
    _ => println("usage: async_bench <chan|pingpong|chain|spawn|parked>")
  }
}
