///|
priv type Context

///|
extern "c" fn Context::new() -> Context = "moonbit_co_context_make"

///|
#borrow(from, to)
extern "c" fn co_shift(from : Context, to : Context) = "moonbit_co_shift"

///|
#borrow(context, stack, data)
extern "c" fn co_reset(
  context : Context,
  stack : Stack,
  func : FuncRef[(() -> Context) -> Context],
  data : () -> Context,
) = "moonbit_co_reset"

///|
priv type Stack

///|
extern "c" fn Stack::new(size : UInt64) -> Stack = "moonbit_co_stack_make"

///|
priv enum State {
  Running
  Yielded
  Stopped
} derive(Show)

///|
struct Routine {
  name : String
  mut caller : Routine?
  mut state : State
  context : Context
  stack : Stack?
}

///|
fn Routine::new(
  name~ : String,
  caller? : Routine,
  state~ : State,
  stack? : Stack,
) -> Routine {
  Routine::{ name, caller, state, context: Context::new(), stack }
}

///|
let main : Routine = Routine::new(name="main", state=Running)

///|
// fn init {
//   @stdlib.atexit(() => {
//     while main.ready.pop_front() is Some(co) {
//       main.switch(co)
//     }
//     main.state = Stopped
//   })
//   |> ignore()
// }

///|
let current : Ref[Routine] = Ref::new(main)

///|
#callsite(autofill(loc))
pub fn create(
  loc~ : SourceLoc,
  name? : String = loc.to_string(),
  stack_size? : UInt64 = 65536,
  f : () -> Unit,
) -> Unit {
  let caller = current.val
  let stack = Stack::new(stack_size)
  let callee : Routine = Routine::new(name~, caller~, state=Running, stack~)
  caller.state = Yielded
  current.val = callee
  co_reset(caller.context, stack, f => f(), () => {
    println("create: \{callee.name} start")
    f()
    println("create: \{callee.name} end")
    guard callee.state is Running else {
      abort("Coroutine not in Running state at completion")
    }
    guard callee.caller is Some(caller) else {
      abort("@tonyfettes/co: Coroutine is not resumed from anywhere")
    }
    callee.state = Stopped
    caller.state = Running
    current.val = caller
    println(
      "create: \{callee.name}(\{callee.state}) -> \{caller.name}(\{caller.state})",
    )
    caller.context
  })
}

///|
fn Routine::switch(self : Routine, other : Routine) -> Unit {
  guard (self.state, other.state) is (Running, Yielded) else {
    abort(
      "@tonyfettes/co: Cannot switch from \{self.name}(\{self.state}) to \{other.name}(\{other.state})",
    )
  }
  self.state = Yielded
  other.state = Running
  current.val = other
  co_shift(self.context, other.context)
  // Extend the lifetime of self.stack past co_shift.
  //
  // MoonBit uses reference counting. Without this ignore, the compiler
  // sees that self is unused after reading self.caller/self.callee, so
  // it emits decref(self) *before* co_shift. This is critical on the
  // last resume, where f runs to completion on the coroutine stack:
  //
  //   resume_                         coroutine (on mmap'd stack)
  //   -------                         ----------------------------
  //   read self.caller, self.callee
  //   decref(self)
  //   co_shift ─────────────────────► f(self) runs...
  //                                   f(self) returns
  //                                   decref(self) ← last ref, RC → 0
  //                                     → Stack finalizer: munmap!
  //                                   self.state = Stopped ← CRASH
  //                                   (still on munmap'd stack)
  //                                   co_reset.S restores caller ctx
  //
  // With ignore(self.stack), resume_ keeps a reference to self across
  // co_shift. When f(self) returns and the closure decrefs self, the
  // refcount stays > 0. The assembly in co_reset.S restores the caller
  // context (back to resume_), and only then is the stack released:
  //
  //   resume_                         coroutine (on mmap'd stack)
  //   -------                         ----------------------------
  //   read self.caller, self.callee
  //   co_shift ─────────────────────► f(self) runs...
  //                                   f(self) returns
  //                                   decref(self) ← RC > 0, safe
  //                                   self.state = Stopped
  //   co_shift ◄──────────────────── co_reset.S restores caller ctx
  //   ignore(self.stack)
  //   decref(self)          ← safe: back on caller's stack
  ignore(other.stack)
}

///|
fn Routine::resume_(self : Routine) -> Unit {
  let caller = current.val
  self.caller = Some(caller)
  println(
    "resume: \{caller.name}(\{caller.state}) -> \{self.name}(\{self.state})",
  )
  caller.switch(self)
  println(
    "resume: \{caller.name}(\{caller.state}) <- \{self.name}(\{self.state})",
  )
}

///|
fn yield_() -> Unit {
  let callee = current.val
  guard callee.caller is Some(caller) else {
    abort("@tonyfettes/co(\{callee.name}): No coroutine to yield to")
  }
  callee.switch(caller)
}

///|
pub struct Channel[T] {
  values : @deque.Deque[T]
  readers : @deque.Deque[Routine]
}

///|
pub fn[T] Channel::new() -> Channel[T] {
  Channel::{ values: @deque.Deque::new(), readers: @deque.Deque::new() }
}

///|
pub fn[T] Channel::send(self : Channel[T], value : T) -> Unit {
  self.values.push_back(value)
  if self.readers.pop_front() is Some(reader) {
    reader.resume_()
  }
}

///|
pub fn[T] Channel::recv(self : Channel[T]) -> T {
  if self.values.pop_front() is Some(value) {
    return value
  }
  self.readers.push_back(current.val)
  yield_()
  guard self.values.pop_front() is Some(value) else { abort("No value sent") }
  value
}
