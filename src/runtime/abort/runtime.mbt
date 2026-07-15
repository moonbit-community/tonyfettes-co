///|
pub fn suspend() -> Unit raise {
  abort("@tonyfettes/co/runtime: deadlock")
  fail("unreachable")
}
