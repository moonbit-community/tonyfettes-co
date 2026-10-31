///|
/// Filesystem benchmark for `co` + `co-io`.
///
/// ```
/// fs_bench seq   <path> <block> <mib>                     # sequential read
/// fs_bench rand  <path> <block> <qd> <ops> <file_mib>     # random `pread`, QD sweep
/// fs_bench stall <hot> <cold> <block> <readers> <ops>     # head-of-line blocking
/// ```
///
/// Every mode prints one line: throughput, per-op cost and a latency
/// distribution, plus the CPU time this process spent, so the reader can tell
/// "the syscall path is slow" from "the disk is slow".
extern "c" fn now_ns() -> Int64 = "co_bench_now_ns"

///|
#borrow(path)
extern "c" fn evict_pages(path : String) -> Int32 = "co_bench_evict"

///|
const NS_PER_S : Int64 = 1_000_000_000

///|
const MIB : Int64 = 1_048_576

///|
fn int_arg(args : Array[String], index : Int32, fallback : Int32) -> Int32 {
  guard index < args.length() else { return fallback }
  @string.parse_int(args[index]) catch {
    _ => fallback
  }
}

///|
fn open_ro(path : String) -> @io.File raise {
  @io.File::open(@os_string.from_string(path))
}

///|
fn percentile(sorted : Array[Int64], p : Int32) -> Int64 {
  guard sorted.length() > 0 else { return 0L }
  sorted[(sorted.length() - 1) * p / 100]
}

///|
fn mb_per_s(bytes : Int64, ns : Int64) -> Double {
  guard ns > 0L else { return 0.0 }
  bytes.to_double() / MIB.to_double() / (ns.to_double() / NS_PER_S.to_double())
}

///|
/// Zero-length reads: the full submit/suspend/resume path with almost no work in
/// the kernel, which prices the runtime layer (allocations, coroutine switch,
/// enter) separately from copying.
fn run_nop(path : String, ops : Int32) -> Unit raise {
  let file = open_ro(path)
  let buffer = FixedArray::make(1, b'\x00')
  let start = now_ns()
  for _ in 0..<ops {
    let n = file.read(buffer, length=0, position=0)
    if n < 0 {
      break
    }
  }
  let elapsed = now_ns() - start
  file.close()
  println(
    "nop: \{elapsed.to_double() / ops.to_double()} ns/op over \{ops} zero-length reads",
  )
}

///|
/// Sequential read: one coroutine, one handle, `mib` MiB from offset 0.
fn run_seq(path : String, block : Int32, mib : Int32) -> Unit raise {
  let file = open_ro(path)
  let buffer = FixedArray::make(block, b'\x00')
  let blocks = (mib.to_int64() * MIB / block.to_int64()).to_int()
  let start = now_ns()
  let mut bytes = 0L
  for _ in 0..<blocks {
    let n = file.read(buffer)
    if n <= 0 {
      break
    }
    bytes += n.to_int64()
  }
  let elapsed = now_ns() - start
  file.close()
  println(
    "seq block=\{block} mib=\{mib}: \{mb_per_s(bytes, elapsed)} MiB/s  \{blocks} ops in \{elapsed.to_double() / 1.0e6} ms  \{elapsed.to_double() / blocks.to_double() / 1000.0} us/op",
  )
}

///|
/// Random reads at a fixed queue depth. Each coroutine owns a handle, so the
/// per-request `position` never races with another coroutine.
fn run_rand(
  path : String,
  block : Int32,
  qd : Int32,
  ops : Int32,
  file_mib : Int32,
  evict : Bool,
) -> Unit raise {
  let blocks = (file_mib.to_int64() * MIB / block.to_int64()).to_int()
  if evict {
    ignore(evict_pages(path))
  }
  let per = ops / qd
  let latency : Array[Int64] = []
  let done : @channel.Channel[Int32] = @channel.Channel::new()
  let start = now_ns()
  for id in 0..<qd {
    let id = id
    ignore(
      @coroutine.Coroutine(name="rand-\{id}", () => {
        let file = open_ro(path) catch {
          error => {
            println("[#\{id}] open failed: \{error}")
            done.send(0)
            return
          }
        }
        let buffer = FixedArray::make(block, b'\x00')
        let mut state = 0x2545F4914F6CDD1DUL + id.to_uint64()
        let mut ok = 0
        for _ in 0..<per {
          // xorshift64*: cheap, enough for offset scattering.
          state = state ^ (state >> 12)
          state = state ^ (state << 25)
          state = state ^ (state >> 27)
          let block_index = (
              ((state * 2685821657736338717UL) >> 32).to_int() & 0x3FFFFFFF
            ) %
            blocks
          let position = block_index.to_int64() * block.to_int64()
          let t0 = now_ns()
          let n = file.read(buffer, position~) catch {
            @io.Errno(code) => {
              println(
                "[#\{id}] read failed: errno \{code} at position \{position}",
              )
              0
            }
            error => {
              println("[#\{id}] read failed: \{error}")
              0
            }
          }
          latency.push(now_ns() - t0)
          if n > 0 {
            ok += 1
          } else {
            break
          }
        }
        file.close() catch {
          _ => ()
        }
        done.send(ok)
      }),
    )
  }
  let mut ok = 0
  for _ in 0..<qd {
    ok += done.recv()
  }
  let elapsed = now_ns() - start
  latency.sort()
  println(
    "rand block=\{block} qd=\{qd}: \{ok.to_int64().to_double() / (elapsed.to_double() / NS_PER_S.to_double())} IOPS  \{elapsed.to_double() / ok.to_double() / 1000.0} us/op  \{mb_per_s(ok.to_int64() * block.to_int64(), elapsed)} MiB/s  p50=\{percentile(latency, 50).to_double() / 1000.0} p99=\{percentile(latency, 99).to_double() / 1000.0} max=\{latency[latency.length() - 1].to_double() / 1000.0} us",
  )
}

///|
/// Head-of-line blocking: while `readers` coroutines serve `ops` reads from the
/// cached `hot` file, one coroutine reads the just-evicted `cold` file from
/// disk. If a cold miss stalls the scheduler, the hot readers' tail latency
/// jumps to the disk read time even though their pages are in page cache.
fn run_stall(
  hot : String,
  cold : String,
  block : Int32,
  readers : Int32,
  ops : Int32,
) -> Unit raise {
  // Evict through a C helper: this process has no raw fd, and dropping the
  // pages here keeps the effect close to the measurement.
  ignore(evict_pages(cold))
  let hot_size = (64L * MIB / block.to_int64()).to_int()
  let latency : Array[Int64] = []
  let done : @channel.Channel[Int32] = @channel.Channel::new()
  let mut cold_ms = 0.0
  let cold_done : @channel.Channel[Double] = @channel.Channel::new()
  for id in 0..<readers {
    let id = id
    ignore(
      @coroutine.Coroutine(name="hot-\{id}", () => {
        let file = open_ro(hot) catch {
          error => {
            println("[#\{id}] open failed: \{error}")
            done.send(0)
            return
          }
        }
        let buffer = FixedArray::make(block, b'\x00')
        let mut state = 0x9E3779B97F4A7C15UL + id.to_uint64()
        let mut ok = 0
        for _ in 0..<ops {
          state = state ^ (state >> 12)
          state = state ^ (state << 25)
          state = state ^ (state >> 27)
          let position = ((state >> 32).to_int() & 0x3FFFFFFF).to_int64() %
            hot_size.to_int64() *
            block.to_int64()
          let t0 = now_ns()
          let n = file.read(buffer, position~) catch { _ => 0 }
          latency.push(now_ns() - t0)
          if n <= 0 {
            break
          }
          ok += 1
        }
        file.close() catch {
          _ => ()
        }
        done.send(ok)
      }),
    )
  }
  let _ = @coroutine.Coroutine(name="cold", () => {
    let file = open_ro(cold) catch {
      error => {
        println("[cold] open failed: \{error}")
        cold_done.send(0.0)
        return
      }
    }
    let buffer = FixedArray::make(block, b'\x00')
    let t0 = now_ns()
    let mut bytes = 0L
    for _ in 0..<(16L * MIB / block.to_int64()).to_int() {
      let n = file.read(buffer) catch { _ => 0 }
      if n <= 0 {
        break
      }
      bytes += n.to_int64()
    }
    let elapsed = now_ns() - t0
    file.close() catch {
      _ => ()
    }
    println(
      "[cold] 16 MiB from disk in \{elapsed.to_double() / 1.0e6} ms = \{mb_per_s(bytes, elapsed)} MiB/s",
    )
    cold_done.send(elapsed.to_double() / 1.0e6)
  })
  let mut ok = 0
  for _ in 0..<readers {
    ok += done.recv()
  }
  cold_ms = cold_done.recv()
  latency.sort()
  println(
    "stall block=\{block} readers=\{readers}: hot \{ok} reads  p50=\{percentile(latency, 50).to_double() / 1000.0} p99=\{percentile(latency, 99).to_double() / 1000.0} max=\{latency[latency.length() - 1].to_double() / 1000.0} us  (cold read took \{cold_ms} ms)",
  )
}

///|
fn main raise {
  let args = @env.args()
  guard args.length() >= 2 else {
    println(
      "usage: fs_bench <seq|rand|stall|nop> ...  |  seq <path> <block> <mib>  |  rand <path> <block> <qd> <ops> <file_mib>  |  stall <hot> <cold> <block> <readers> <ops>",
    )
    return
  }
  match args[1] {
    "seq" => run_seq(args[2], int_arg(args, 3, 4096), int_arg(args, 4, 256))
    "nop" => run_nop(args[2], int_arg(args, 3, 100000))
    "rand" =>
      run_rand(
        args[2],
        int_arg(args, 3, 4096),
        int_arg(args, 4, 1),
        int_arg(args, 5, 10000),
        int_arg(args, 6, 64),
        args.length() > 7 && args[7] == "evict",
      )
    "stall" =>
      run_stall(
        args[2],
        args[3],
        int_arg(args, 4, 4096),
        int_arg(args, 5, 8),
        int_arg(args, 6, 2000),
      )
    mode => println("unknown mode \{mode}")
  }
}
