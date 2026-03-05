# tonyfettes/co

Stackful coroutines for [MoonBit](https://www.moonbitlang.com/), implemented with hand-written assembly context switching on x86_64 and arm64 (aarch64).

Each coroutine gets its own `mmap`'d stack (64 KiB by default) with a guard page, and context switches save/restore only callee-saved registers — no syscalls in the hot path.

**Native target only.** This package requires the MoonBit native backend.

## Install

```
moon add tonyfettes/co
```

## Quick start

```moonbit
fn main {
  let co = @co.Routine::new(co => {
    println("hello")
    co.yield_()
    println("world")
  })
  println("---")
  co.resume_()
  println("---")
}
// Output:
// hello
// ---
// world
// ---
```

## API

### `Routine::new`

```
fn Routine::new(stack_size? : UInt64, (Routine) -> Unit) -> Routine
```

Creates a coroutine that will run the given function. The coroutine starts executing immediately and runs until it calls `yield_()` or returns. Also available as the free function `@co.create`.

### `Routine::resume_`

```
fn Routine::resume_(Routine) -> Unit
```

Resumes a yielded coroutine. Aborts if the coroutine is not in the `Yielded` state.

### `Routine::yield_`

```
fn Routine::yield_(Routine) -> Unit
```

Suspends the current coroutine, returning control to whoever called `resume_`. Aborts if the coroutine is not in the `Running` state.

### `Routine::stopped`

```
fn Routine::stopped(Routine) -> Bool
```

Returns `true` if the coroutine's function has returned.

### `Routine::try_resume`

```
fn Routine::try_resume(Routine) -> Bool
```

Resumes the coroutine if it is yielded, returning `true`. Returns `false` if the coroutine is not in the `Yielded` state (already stopped or running).

## Supported platforms

| Architecture | OS            |
|-------------|---------------|
| x86_64      | Linux, macOS  |
| aarch64     | Linux, macOS  |

## License

Apache-2.0
