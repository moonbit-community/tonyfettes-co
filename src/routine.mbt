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
struct Task {
  name : String
  mut state : State
  context : Context
  stack : Stack?
}

///|
fn Task::raw(name~ : String, state~ : State, stack? : Stack) -> Task {
  Task::{ name, state, context: Context::new(), stack }
}

///|
let main : Task = Task::raw(name="main", state=Running)

///|
let curr : Ref[Task] = Ref::new(main)

///|
priv struct Scheduler {
  ready : @deque.Deque[Task]
}

///|
fn Scheduler::new() -> Scheduler {
  Scheduler::{ ready: @deque.Deque::new() }
}

///|
/// Pick the next ready coroutine, polling the runtime if none are available.
fn Scheduler::next(self : Scheduler) -> Task {
  loop self.ready.pop_front() {
    Some(next) => next
    None => {
      @runtime.yield_()
      continue self.ready.pop_front()
    }
  }
}

///|
let scheduler : Scheduler = Scheduler::new()

///|
fn Scheduler::schedule(self : Scheduler, task : Task) -> Unit {
  self.ready.push_back(task)
}

///|
/// Get the currently running routine.
pub fn Task::current() -> Task {
  curr.val
}

///|
/// Suspend the current routine until someone calls `unpark` on it.
/// The caller must ensure this routine's handle has been stored somewhere
/// (ready queue, channel readers, IO pending, etc.) before calling park,
/// otherwise it will never be woken up.
pub fn Task::suspend() -> Unit {
  let prev = curr.val
  prev.state = Yielded
  let next = scheduler.next()
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
/// Make a parked routine runnable by pushing it to the ready queue.
pub fn Task::schedule(self : Task) -> Unit {
  scheduler.schedule(self)
}

///|
#callsite(autofill(loc))
#as_free_fn(create)
pub fn Task::new(
  loc~ : SourceLoc,
  name? : String = loc.to_string(),
  stack_size? : UInt64 = 65536,
  f : () -> Unit,
) -> Task {
  let creator = curr.val
  let stack = Stack::new(stack_size)
  let task = Task::raw(name~, state=Running, stack~)
  creator.state = Yielded
  scheduler.schedule(creator)
  curr.val = task
  // Note: unlike co_shift in schedule(), we don't need ignore(callee.stack)
  // here because #borrow(stack) on co_reset keeps the `stack` parameter alive
  // across the call, preventing munmap even if `callee` is decreffed early.
  co_reset(creator.context, stack, f => f(), () => {
    f()
    guard task.state is Running else {
      abort(
        "@tonyfettes/co: coroutine \{task.name} not Running at completion (\{task.state})",
      )
    }
    task.state = Stopped
    let next = scheduler.next()
    next.state = Running
    next.context
  })
  // Creator resumes here (via co_shift → co_reset restore).
  // Set current to ourselves — same logic as after co_shift in park().
  curr.val = creator
  task
}

///|
#callsite(autofill(loc))
pub fn launch(
  loc~ : SourceLoc,
  name? : String,
  stack_size? : UInt64,
  f : () -> Unit,
) -> Unit {
  ignore(create(loc~, name?, stack_size?, f))
}
