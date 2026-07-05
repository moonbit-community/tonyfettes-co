///|
async fn[T] with_tmpdir(prefix~ : String, f : async (@path.Path) -> T) -> T {
  let tmpdir = @fs.tmpdir(prefix~)
  try f(@path.Path(tmpdir)) catch {
    error => {
      @async.protect_from_cancel() <| () => {
        @async.with_timeout_opt(1000, () => @fs.rmdir(tmpdir, recursive=true))
        |> ignore()
      }
      raise error
    }
  } noraise {
    value => {
      @fs.rmdir(tmpdir, recursive=true)
      return value
    }
  }
}
