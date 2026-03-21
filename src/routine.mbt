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
  mut state : State
  context : Context
  stack : Stack?
}

///|
fn Routine::new(name~ : String, state~ : State, stack? : Stack) -> Routine {
  Routine::{ name, state, context: Context::new(), stack }
}

///|
let main : Routine = Routine::new(name="main", state=Running)

///|
let curr : Ref[Routine] = Ref::new(main)

///|
let ready : @deque.Deque[Routine] = @deque.Deque::new()

///|
/// Pop the next ready coroutine and switch to it.
/// The caller must have already set current's state and enqueued it
/// (to ready queue or a channel's readers) before calling this.
fn schedule() -> Unit {
  guard ready.pop_front() is Some(next) else {
    abort("@tonyfettes/co: deadlock — all coroutines are blocked")
  }
  let prev = curr.val
  next.state = Running
  co_shift(prev.context, next.context)
  // We just woke up — set current to ourselves.
  // This is done AFTER co_shift (on our own stack) rather than BEFORE
  // (on the switcher's stack), so that the decref of the old current.val
  // never happens on a stack that's about to be freed.
  curr.val = prev
  ignore(next.stack)
}

///|
#callsite(autofill(loc))
pub fn create(
  loc~ : SourceLoc,
  name? : String = loc.to_string(),
  stack_size? : UInt64 = 65536,
  f : () -> Unit,
) -> Unit {
  let creator = curr.val
  let stack = Stack::new(stack_size)
  let callee : Routine = Routine::new(name~, state=Running, stack~)
  creator.state = Yielded
  ready.push_back(creator)
  curr.val = callee
  // Note: unlike co_shift in schedule(), we don't need ignore(callee.stack)
  // here because #borrow(stack) on co_reset keeps the `stack` parameter alive
  // across the call, preventing munmap even if `callee` is decreffed early.
  co_reset(creator.context, stack, f => f(), () => {
    f()
    guard callee.state is Running else {
      abort(
        "@tonyfettes/co: coroutine \{callee.name} not Running at completion (\{callee.state})",
      )
    }
    callee.state = Stopped
    guard ready.pop_front() is Some(next) else {
      abort("@tonyfettes/co: deadlock — all coroutines are blocked")
    }
    next.state = Running
    next.context
  })
  // Creator resumes here (via co_shift → co_reset restore).
  // Set current to ourselves — same logic as after co_shift in schedule().
  curr.val = creator
}

///|
pub fn yield_() -> Unit {
  let self = curr.val
  self.state = Yielded
  ready.push_back(self)
  schedule()
}
