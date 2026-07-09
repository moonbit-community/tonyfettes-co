///|
priv type Context

///|
extern "c" fn Context::new() -> Context = "moonbit_co_context_make"

///|
// `to` is owned: the switch hands the resumed coroutine a +1 reference on its own
// context so it survives the switch even if the caller's reference to `to` is
// its last one; the resumed coroutine drops it via `Context::release` once awake.
#borrow(from)
#owned(to)
extern "c" fn co_shift(from : Context, to : Context) = "moonbit_co_shift"

///|
/// Drop the +1 reference the switch handed us, now that we are running again on
/// our own stack. Balances the owned `to` of `co_shift` and the context a
/// coroutine returns from `co_reset` on completion.
#borrow(self)
extern "c" fn Context::release(self : Context) = "moonbit_co_context_release"

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
  Scheduled
  Suspended
  Stopped
}

///|
fn State::to_string(self : State) -> String {
  match self {
    Running => "Running"
    Scheduled => "Scheduled"
    Suspended => "Suspended"
    Stopped => "Stopped"
  }
}

///|
struct Coroutine {
  mut name : String
  mut state : State
  context : Context
  stack : Stack?
  // The coroutine body. Held here so it stays alive for the whole lifetime of
  // the coroutine: `co_reset` returns to the creator on the *first suspend* (not just
  // on completion), which would otherwise decref the only remaining reference to
  // `f` — and with it any values `f` captured — while the coroutine is still
  // suspended and about to resume. See Coroutine::Coroutine.
  mut func : (() -> Unit)?
}

///|
fn Coroutine::new(
  name~ : String,
  state~ : State,
  stack? : Stack,
  func? : () -> Unit,
) -> Coroutine {
  Coroutine::{ name, state, context: Context::new(), stack, func }
}

///|
priv struct Scheduler {
  mut current : Coroutine
  ready : @deque.Deque[Coroutine]
  recycled : Array[Coroutine]
}

///|
fn Scheduler::new() -> Scheduler {
  let main = Coroutine::new(name="main", state=Running)
  Scheduler::{ current: main, ready: @deque.Deque([]), recycled: [] }
}

///|
fn Scheduler::allocate(
  self : Scheduler,
  name~ : String,
  state~ : State,
  func~ : () -> Unit,
) -> Coroutine {
  if self.recycled.pop() is Some(coroutine) {
    coroutine.name = name
    coroutine.state = state
    coroutine.func = Some(func)
    return coroutine
  }
  let stack = Stack::new(DEFAULT_STACK_SIZE)
  Coroutine::new(name~, state~, stack~, func~)
}

///|
const RECYCLED_COROUTINE_LIMIT : Int = 16

///|
fn Scheduler::recycle(self : Scheduler, coroutine : Coroutine) -> Unit {
  guard self.recycled.length() < RECYCLED_COROUTINE_LIMIT else { return }
  coroutine.state = Stopped
  coroutine.func = None
  self.recycled.push(coroutine)
}

///|
/// Pick the next ready coroutine, polling the runtime if none are available.
fn Scheduler::next(self : Scheduler) -> Coroutine {
  for candidate = self.ready.pop_front() {
    match candidate {
      Some(next) => break next
      None => {
        @runtime.suspend()
        continue self.ready.pop_front()
      }
    }
  }
}

///|
let scheduler : Scheduler = Scheduler::new()

///|
fn Scheduler::schedule(self : Scheduler, coroutine : Coroutine) -> Unit {
  self.ready.push_back(coroutine)
}

///|
/// Get the currently running routine.
#as_free_fn
#deprecated("Use @coroutine.current()")
pub fn Coroutine::current() -> Coroutine {
  scheduler.current
}

///|
/// Suspend the current routine until someone calls `unpark` on it.
/// The caller must ensure this routine's handle has been stored somewhere
/// (ready queue, channel readers, IO pending, etc.) before calling park,
/// otherwise it will never be woken up.
#as_free_fn
#deprecated("Use @coroutine.suspend()")
pub fn Coroutine::suspend() -> Unit {
  let prev = scheduler.current
  prev.state = Suspended
  let next = scheduler.next()
  next.state = Running
  co_shift(prev.context, next.context)
  // We just woke up. Drop the +1 reference the resume handed us (see co_shift).
  // Done AFTER the switch, on our own stack.
  prev.context.release()
  // Set current to ourselves — also done AFTER co_shift (on our own stack)
  // rather than BEFORE (on the switcher's stack), so that the decref of the old
  // current.val never happens on a stack that's about to be freed.
  scheduler.current = prev
  ignore(next.stack)
}

///|
/// Make a parked routine runnable by pushing it to the ready queue.
pub fn Coroutine::schedule(self : Coroutine) -> Unit {
  guard self.state is Suspended else { return }
  self.state = Scheduled
  scheduler.schedule(self)
}

///|
const DEFAULT_STACK_SIZE : UInt64 = 65536

///|
#callsite(autofill(loc))
pub fn Coroutine::Coroutine(
  loc~ : SourceLoc,
  name? : String = loc.to_string(),
  f : () -> Unit,
) -> Coroutine {
  let creator = scheduler.current
  let coroutine = scheduler.allocate(name~, state=Running, func=f)
  creator.state = Scheduled
  scheduler.schedule(creator)
  scheduler.current = coroutine
  // Note: unlike co_shift in schedule(), we don't need ignore(callee.stack)
  // here because #borrow(stack) on co_reset keeps the `stack` parameter alive
  // across the call, preventing munmap even if `callee` is decreffed early.
  co_reset(creator.context, coroutine.stack.unwrap(), f => f(), () => {
    // Run the body through the coroutine, which owns it: the parameter `f` is
    // decref'd when co_reset returns to the creator on the first suspend, so the
    // coroutine must be the reference that keeps the body (and its captures) alive.
    guard coroutine.func is Some(body) else {
      abort(
        "@tonyfettes/co/coroutine: coroutine \{coroutine.name} started with no body",
      )
    }
    body()
    guard coroutine.state is Running else {
      abort(
        "@tonyfettes/co/coroutine: coroutine \{coroutine.name} not Running at completion (\{coroutine.state.to_string()})",
      )
    }
    let next = scheduler.next()
    scheduler.recycle(coroutine)
    next.state = Running
    next.context
  })
  // Creator resumes here (via co_shift → co_reset restore). Whether resumed by
  // the coroutine's first suspend or by its completion returning creator.context
  // from co_reset, that resume handed us a +1 reference — drop it, on our own
  // stack, same as after co_shift in suspend().
  creator.context.release()
  // Set current to ourselves — same logic as after co_shift in suspend().
  scheduler.current = creator
  coroutine
}
