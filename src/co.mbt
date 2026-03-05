///|
priv type Context

///|
extern "c" fn Context::new() -> Context = "moonbit_co_context_make"

///|
#borrow(from, to)
extern "c" fn co_shift(from : Context, to : Context) = "moonbit_co_shift"

///|
#borrow(context, stack_base, func, data)
extern "c" fn co_reset(
  context : Context,
  stack_base : Stack,
  stack_size : UInt64,
  func : FuncRef[(() -> Unit) -> Unit],
  data : () -> Unit,
) = "moonbit_co_reset"

///|
priv type Stack

///|
extern "c" fn Stack::new(size : UInt64) -> Stack = "moonbit_co_stack_make"

///|
priv enum RoutineState {
  Running(caller~ : Context, callee~ : Context, stack~ : Stack)
  Yielded(caller~ : Context, callee~ : Context, stack~ : Stack)
  Stopped
}

///|
struct Routine {
  mut state : RoutineState
}

///|
pub fn Routine::new(
  stack_size? : UInt64 = 4096,
  f : (Routine) -> Unit,
) -> Routine {
  let stack = Stack::new(stack_size)
  let caller = Context::new()
  let callee = Context::new()
  let self : Routine = { state: Running(caller~, callee~, stack~) }
  co_reset(caller, stack, stack_size, f => f(), () => {
    f(self)
    self.state = Stopped
  })
  self
}

///|
pub fn Routine::resume_(self : Routine) -> Unit {
  guard self.state is Yielded(caller~, callee~, stack~) else {
    abort("Cannot resume a running coroutine")
  }
  ignore(stack)
  self.state = Running(caller~, callee~, stack~)
  co_shift(caller, callee)
}

///|
pub fn Routine::yield_(self : Routine) -> Unit {
  guard self.state is Running(caller~, callee~, stack~) else {
    abort("Cannot yield from a yielded coroutine")
  }
  ignore(stack)
  self.state = Yielded(caller~, callee~, stack~)
  co_shift(callee, caller)
}

///|
pub fn Routine::stopped(self : Routine) -> Bool {
  self.state is Stopped
}
