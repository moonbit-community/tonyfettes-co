///|
test "open and close" {
  let path = b"/tmp/co-io-test-open\x00"
  let fd = @io.open(path, write=true, create=true, truncate=true)
  @io.close(fd)
}

///|
test "write and read" {
  let path = b"/tmp/co-io-test-rw\x00"
  let fd = @io.open(path, read=false, write=true, create=true, truncate=true)
  let src = b"hello, io_uring!"
  let written = @io.write(fd, src)
  assert_eq(written, src.length())
  @io.close(fd)
  let fd = @io.open(path)
  let buf = FixedArray::make(64, b'\x00')
  let n = @io.read(fd, buf)
  @io.close(fd)
  assert_eq(n, src.length())
  let dst = buf.unsafe_reinterpret_as_bytes()
  assert_eq(dst[:n], src[:n])
}

///|
test "concurrent IO" {
  let path = b"/tmp/co-io-test-concurrent\x00"
  let fd = @io.open(path, read=false, write=true, create=true, truncate=true)
  let src = b"concurrent test"
  let _ = @io.write(fd, src)
  @io.close(fd)
  let f1 = @co.Promise::new()
  let f2 = @co.Promise::new()
  let buf1 = FixedArray::make(64, b'\x00')
  let buf2 = FixedArray::make(64, b'\x00')
  let _ = @co.Task::new(() => {
    f1.set(
      try? ({
        let fd = @io.open(path)
        try @io.read(fd, buf1) catch {
          error => {
            @io.close(fd)
            raise error
          }
        } noraise {
          n => n
        }
      }),
    )
  })
  let _ = @co.Task::new(() => {
    f2.set(
      try? ({
        let fd = @io.open(path)
        try @io.read(fd, buf2) catch {
          error => {
            @io.close(fd)
            raise error
          }
        } noraise {
          n => n
        }
      }),
    )
  })
  let n1 = f1.wait()
  let n2 = f2.wait()
  assert_eq(n1, src.length())
  assert_eq(n2, src.length())
  assert_eq(buf1[:n1], buf2[:n2])
}

///|
test "open non-existent file" {
  let path = b"/tmp/co-io-test-nonexistent-file-that-should-not-exist\x00"
  let result = try? @io.open(path)
  assert_true(result is Err(_))
}
