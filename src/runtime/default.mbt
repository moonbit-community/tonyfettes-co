///|
pub fn yield_() -> Unit {
  abort("")
}

///|
let defers : Array[() -> Unit] = []

///|
extern "c" fn atexit(f : FuncRef[() -> Unit]) -> Unit = "atexit"

///|
fn init {
  atexit(() => {
    for f in defers {
      f()
    }
  })
}

///|
pub fn defer_(f : () -> Unit) -> Unit {
  defers.push(f)
}
