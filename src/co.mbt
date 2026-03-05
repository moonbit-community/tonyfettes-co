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
pub fn Routine::new(
  stack_size? : UInt64 = 65536,
  f : (Routine) -> Unit,
) -> Routine {
  let stack = Stack::new(stack_size)
  let caller = Context::new()
  let callee = Context::new()
  let self : Routine = { state: Running, caller, callee, stack }
  co_reset(caller, stack, f => f(), () => {
    f(self)
    guard self.state is Running else {
      abort("Coroutine not in Running state at completion")
    }
    self.state = Stopped
  })
  self
}

///|
pub fn Routine::resume_(self : Routine) -> Unit {
  guard self.state is Yielded else {
    abort("Cannot resume a running coroutine")
  }
  self.state = Running
  co_shift(self.caller, self.callee)
  ignore(self.stack)
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
