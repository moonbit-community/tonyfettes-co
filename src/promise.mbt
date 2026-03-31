///|
struct Promise[T, E](Future[Result[T, E]])

///|
pub fn[T, E] Promise::new() -> Promise[T, E] {
  Future::new()
}

///|
pub fn[T, E] Promise::resolve(self : Promise[T, E], value : T) -> Unit {
  self.0.set(Ok(value))
}

///|
pub fn[T, E] Promise::reject(self : Promise[T, E], error : E) -> Unit {
  self.0.set(Err(error))
}

///|
pub fn[T, E] Promise::set(self : Promise[T, E], result : Result[T, E]) -> Unit {
  self.0.set(result)
}

///|
pub fn[T, E : Error] Promise::wait(self : Promise[T, E]) -> T raise E {
  self.0.wait().unwrap_or_error()
}
