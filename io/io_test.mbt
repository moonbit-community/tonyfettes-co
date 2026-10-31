///|
test "open and close" {
  let path = @os_string.from_string("/tmp/co-io-test-open")
  let file = @io.File::open(path, create=CreateOrTruncate)
  file.close()
}

///|
test "write and read" {
  let path = @os_string.from_string("/tmp/co-io-test-rw")
  let file = @io.File::open(path, access=WriteOnly, create=CreateOrTruncate)
  let text = b"hello, io_uring!"
  let written = file.write(text)
  assert_eq(written, text.length())
  file.close()
  let file = @io.File::open(path)
  let buf = FixedArray::make(64, b'\x00')
  let n = file.read(buf)
  file.close()
  assert_eq(n, text.length())
  let dst = buf.unsafe_reinterpret_as_bytes()
  assert_eq(dst[:n], text[:n])
}

///|
test "concurrent IO" {
  let path = @os_string.from_string("/tmp/co-io-test-concurrent")
  let file = @io.File::open(path, access=WriteOnly, create=CreateOrTruncate)
  let text = b"concurrent test"
  assert_eq(file.write(text), text.length())
  file.close()
  let f1 = @future.Promise::new()
  let f2 = @future.Promise::new()
  let buf1 = FixedArray::make(64, b'\x00')
  let buf2 = FixedArray::make(64, b'\x00')
  let _ = @coroutine.Coroutine(() => {
    let file = @io.File::open(path) catch {
      error => {
        f1.reject(error)
        return
      }
    }
    try file.read(buf1) catch {
      error => {
        file.close() catch {
          _ => ()
        }
        f1.reject(error)
        return
      }
    } noraise {
      n => f1.resolve(n)
    }
  })
  let _ = @coroutine.Coroutine(() => {
    let file = @io.File::open(path) catch {
      error => {
        f2.reject(error)
        return
      }
    }
    try file.read(buf2) catch {
      error => {
        file.close() catch {
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
  assert_eq(n1, text.length())
  assert_eq(n2, text.length())
  @debug.assert_eq(buf1[:n1], buf2[:n2])
}

///|
test "read into a buffer with no surviving reference" {
  let path = @os_string.from_string("/tmp/co-io-test-temp-buf")
  let file = @io.File::open(path, access=ReadWrite, create=CreateOrTruncate)
  let text = b"payload"
  assert_eq(file.write(text), text.length())
  file.close()
  let file = @io.File::open(path)
  // The buffer is a temporary with no binding outliving the call. If the FFI
  // only borrowed it, MoonBit would free it right after submit_read and the
  // kernel would write into freed memory during io_poll (ASan-detectable UAF).
  let n = file.read(FixedArray::make(64, b'\x00'))
  file.close()
  assert_eq(n, 7)
}

///|
test "read rejects out-of-range offset" {
  let path = @os_string.from_string("/tmp/co-io-test-badoffset")
  let fd = @io.File::open(path, access=ReadWrite, create=CreateOrTruncate)
  fd.close()
  let file = @io.File::open(path)
  let buf = FixedArray::make(8, b'\x00')
  // offset past the end makes the default length negative; must be rejected
  // before it reaches the native backend, not turned into a huge transfer.
  debug_inspect(
    @test.expect_error(() => file.read(buf, offset=buf.length() + 1)),
    content=(
      #|Errno(22)
    ),
  )
  file.close()
}

///|
test "open non-existent file" {
  let path = @os_string.from_string(
    "/tmp/co-io-test-nonexistent-file-that-should-not-exist",
  )
  assert_true(@test.expect_error(() => @io.File::open(path)) is @io.Errno(_))
}

///|
test "read at an explicit position" {
  let path = @os_string.from_string("/tmp/co-io-test-pread")
  let file = @io.File::open(path, access=WriteOnly, create=CreateOrTruncate)
  let text = b"hello, io_uring!"
  assert_eq(file.write(text), text.length())
  file.close()
  let file = @io.File::open(path)
  let buf = FixedArray::make(16, b'\x00')
  // `position` addresses the file, `offset` addresses the buffer: read "io_ur"
  // into buf[4..9].
  assert_eq(file.read(buf, offset=4, length=5, position=7), 5)
  let dst = buf.unsafe_reinterpret_as_bytes()
  assert_eq(dst[4:9], text[7:12])
  // Re-reading the same position yields the same bytes: the file offset is
  // untouched, unlike the streaming `read`.
  assert_eq(file.read(buf, length=5, position=7), 5)
  assert_eq(dst[:5], text[7:12])
  file.close()
}

///|
test "concurrent reads at fixed positions" {
  let path = @os_string.from_string("/tmp/co-io-test-pread-concurrent")
  let file = @io.File::open(path, access=WriteOnly, create=CreateOrTruncate)
  let text = b"0123456789abcdef"
  assert_eq(file.write(text), text.length())
  file.close()
  let file = @io.File::open(path)
  // Two coroutines reading the same handle at different positions must each get
  // their own bytes; this is the case the streaming `read` cannot do, because it
  // shares (and advances) the kernel's file offset.
  let buf0 = FixedArray::make(4, b'\x00')
  let buf1 = FixedArray::make(4, b'\x00')
  let f0 : @future.Promise[Int32, Error] = @future.Promise::new()
  let f1 : @future.Promise[Int32, Error] = @future.Promise::new()
  let _ = @coroutine.Coroutine(() => {
    try file.read(buf0, position=0) catch {
      error => f0.reject(error)
    } noraise {
      n => f0.resolve(n)
    }
  })
  let _ = @coroutine.Coroutine(() => {
    try file.read(buf1, position=4) catch {
      error => f1.reject(error)
    } noraise {
      n => f1.resolve(n)
    }
  })
  let n0 = f0.wait()
  let n1 = f1.wait()
  assert_eq(n0, 4)
  assert_eq(n1, 4)
  assert_eq(
    buf0.unsafe_reinterpret_as_bytes()[:4].to_owned(),
    text[:4].to_owned(),
  )
  assert_eq(
    buf1.unsafe_reinterpret_as_bytes()[:4].to_owned(),
    text[4:8].to_owned(),
  )
  file.close()
}
