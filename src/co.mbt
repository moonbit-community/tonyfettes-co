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
  func : FuncRef[(() -> Unit) -> Unit],
  data : () -> Unit,
) = "moonbit_co_reset"

///|
priv type Stack

///|
extern "c" fn Stack::new(size : UInt64) -> Stack = "moonbit_co_stack_make"

///|
priv enum RoutineState {
  Running
  Yielded
  Stopped
}

///|
struct Routine {
  mut state : RoutineState
  caller : Context
  callee : Context
  stack : Stack
}

///|
#as_free_fn(create)
pub fn Routine::new(
  stack_size? : UInt64 = 65536,
  f : (Routine) -> Unit,
) -> Routine {
  let stack = Stack::new(stack_size)
  let caller = Context::new()
  let callee = Context::new()
  let self : Routine = { state: Running, caller, callee, stack }
  co_reset(caller, stack, f => f(), () => {
    self.yield_()
    f(self)
    guard self.state is Running else {
      abort("Coroutine not in Running state at completion")
    }
    self.state = Stopped
  })
  self
}

///|
pub fn Routine::try_resume(self : Routine) -> Bool {
  guard self.state is Yielded else { return false }
  self.state = Running
  co_shift(self.caller, self.callee)
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
  ignore(self.stack)
  true
}

///|
pub fn Routine::yield_(self : Routine) -> Unit {
  guard self.state is Running else {
    abort("Cannot yield from a yielded coroutine")
  }
  self.state = Yielded
  co_shift(self.callee, self.caller)
}

///|
pub fn Routine::stopped(self : Routine) -> Bool {
  self.state is Stopped
}

///|
pub fn Routine::resume_(self : Routine) -> Unit {
  if !self.try_resume() {
    abort("Cannot resume a running coroutine")
  }
}
