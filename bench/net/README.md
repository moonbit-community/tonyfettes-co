# TCP echo benchmark

Two echo servers with the same shape — one coroutine/task per connection, 16 KiB
read buffer, `TCP_NODELAY`, `127.0.0.1:8080` — plus a C load generator, so the
runtimes can be compared with one client:

| server | runtime |
|---|---|
| `co_echo` | this library (`co` + `co-io`, io_uring on Linux) |
| `async_echo` | `moonbitlang/async` (`TcpServer` + task group) |

## Run

```sh
# build the load generator once
cc -O2 -o bench/net/loadgen/echo_bench bench/net/loadgen/echo_bench.c

# start a server (pin it: see "methodology")
./_build/native/release/build/tonyfettes/co-bench/net/co_echo/co_echo.exe     # or async_echo

# request/response, 64 connections, 32-byte messages, 200k exchanges
bench/net/loadgen/echo_bench 8080 64 32 200000

# pipelined: keep `window` messages in flight per connection
bench/net/loadgen/echo_bench 8080 64 32 200000 pipe 0 32

# bulk: stream `bytes` per connection and measure bandwidth
bench/net/loadgen/echo_bench 8080 8 16384 1 stream 268435456
```

`echo_bench` prints aggregate round-trips/s plus p50/p90/p99/p999 latency.

## Baseline (i5-1130G7, 4 cores / 8 threads @ 1.1 GHz, loopback, release)

Server pinned to cpu0, clients pinned to other physical cores.

Strict request/response, one message in flight per connection:

| server | 64 conns | server CPU/message |
|---|---|---|
| `co_echo` | 372k rt/s | 1.70 µs (63% of one core) |
| `async_echo` | 281k rt/s | 2.60 µs (73%) |

Pipelined (32 in flight per connection), 4 clients × 64 conns:

| server | aggregate | server CPU/message |
|---|---|---|
| `co_echo` | 997k rt/s | 0.63 µs |
| `async_echo` | 1.05M rt/s | 0.63 µs |

Six clients: `co_echo` 1.52M rt/s, `async_echo` 1.50M rt/s.

Bulk, 16 KiB writes: `co_echo` 3.4 GB/s payload (6.8 GB/s on the wire),
`async_echo` 2.9 GB/s.

## Methodology notes

These matter more than the numbers:

- **The client is usually the bottleneck, not the server.** A single-threaded
  client needs ~2 µs CPU per exchange (`epoll_wait` + `read` + `write`) while the
  server needs 0.4–0.6 µs of CPU once requests batch, so the server idles 35–40%
  of the time waiting for work. Do not read server CPU% as headroom.
- **Pin client and server to different *physical* cores.** Server and client on
  the two hyperthreads of one core cost ~20% (410k → 330k rt/s here).
- **Strict request/response measures per-message latency, not throughput.** With
  one message in flight per connection, each `io_uring_enter` carries a single
  completion, so per-message syscall overhead dominates: server CPU/message is
  1.7 µs instead of 0.6 µs. Adding *more* strict-RR clients makes aggregate
  throughput *worse* (262k at 4 clients) because batches get smaller.
- **Adding clients stops helping once they saturate the physical cores.** Six
  client processes already use ~410% CPU on this 4-core machine.
- `ksoftirqd` stays at ~0%: loopback TX/RX is processed inline inside the
  sending syscall, so its cost is already inside the server's and client's CPU.
- Latency percentiles are end-to-end round trips measured in the C client, so
  they include the client's own ~2 µs.
