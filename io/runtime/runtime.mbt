///|
pub fn suspend() -> Result[Unit, Error] {
  try @io.suspend() catch {
    error => Err(error)
  } noraise {
    _ => Ok(())
  }
}
