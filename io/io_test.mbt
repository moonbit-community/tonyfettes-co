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
  let f1 = @future.Promise::new()
  let f2 = @future.Promise::new()
  let buf1 = FixedArray::make(64, b'\x00')
  let buf2 = FixedArray::make(64, b'\x00')
  let _ = @coroutine.spawn(() => {
    let fd = @io.open(path) catch {
      error => {
        f1.reject(error)
        return
      }
    }
    try @io.read(fd, buf1) catch {
      error => {
        @io.close(fd) catch {
          _ => ()
        }
        f1.reject(error)
        return
      }
    } noraise {
      n => f1.resolve(n)
    }
  })
  let _ = @coroutine.spawn(() => {
    let fd = @io.open(path) catch {
      error => {
        f2.reject(error)
        return
      }
    }
    try @io.read(fd, buf2) catch {
      error => {
        @io.close(fd) catch {
          _ => ()
        }
        f2.reject(error)
      }
    } noraise {
      n => f2.resolve(n)
    }
  })
  let n1 = f1.wait()
  let n2 = f2.wait()
  assert_eq(n1, src.length())
  assert_eq(n2, src.length())
  @debug.assert_eq(buf1[:n1], buf2[:n2])
}

///|
test "read into a buffer with no surviving reference" {
  let path = b"/tmp/co-io-test-temp-buf\x00"
  let fd = @io.open(path, write=true, create=true, truncate=true)
  let _ = @io.write(fd, b"payload")
  @io.close(fd)
  let fd = @io.open(path)
  // The buffer is a temporary with no binding outliving the call. If the FFI
  // only borrowed it, MoonBit would free it right after submit_read and the
  // kernel would write into freed memory during io_poll (ASan-detectable UAF).
  let n = @io.read(fd, FixedArray::make(64, b'\x00'))
  @io.close(fd)
  assert_eq(n, 7)
}

///|
test "read rejects out-of-range offset" {
  let path = b"/tmp/co-io-test-badoffset\x00"
  let fd = @io.open(path, write=true, create=true, truncate=true)
  @io.close(fd)
  let fd = @io.open(path)
  let buf = FixedArray::make(8, b'\x00')
  // offset past the end makes the default length negative; must be rejected
  // before it reaches the native backend, not turned into a huge transfer.
  let raised = try {
    @io.read(fd, buf, offset=buf.length() + 1) |> ignore
    false
  } catch {
    _ => true
  }
  @io.close(fd)
  assert_true(raised)
}

///|
test "open non-existent file" {
  let path = b"/tmp/co-io-test-nonexistent-file-that-should-not-exist\x00"
  assert_true(@test.expect_error(() => @io.open(path)) is @io.Errno(_))
}
