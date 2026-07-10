#include <stdint.h>
#if defined(__APPLE__)
#include <moonbit.h>

#include <dispatch/dispatch.h>
#include <errno.h>
#include <fcntl.h>
#include <stdatomic.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>

#include "io.h"

// -- state --

enum { MoonbitCoIoGcdRingMask = 255, MoonbitCoIoGcdRingSize = 256 };

struct moonbit_co_io_completion {
  _Atomic(struct moonbit_co_coroutine *) coroutine;
  void *request;
  struct moonbit_co_io_result *result;
};

struct moonbit_co_io {
  int kq;
  dispatch_queue_t queue;
  dispatch_semaphore_t semaphore;

  struct moonbit_co_io_completion cq[MoonbitCoIoGcdRingSize];
  uint32_t _Atomic cq_head;
  uint32_t _Atomic cq_tail;
};

static void
moonbit_co_io_finalize(void *ptr) {
  struct moonbit_co_io *io = (struct moonbit_co_io *)ptr;
  if (io->queue)
    dispatch_release(io->queue);
  if (io->semaphore)
    dispatch_release(io->semaphore);
}

struct moonbit_co_io *
moonbit_co_io_create(void) {
  struct moonbit_co_io *io =
    (struct moonbit_co_io *)moonbit_make_external_object(
      moonbit_co_io_finalize, sizeof(struct moonbit_co_io)
    );
  memset(io, 0, sizeof(*io));
  io->queue = dispatch_queue_create("co.io", DISPATCH_QUEUE_CONCURRENT);
  io->semaphore = dispatch_semaphore_create(0);
  return io;
}

// -- completion ring --

static void
moonbit_co_io_schedule(
  struct moonbit_co_io *io,
  void *request,
  struct moonbit_co_io_result *result,
  struct moonbit_co_coroutine *coroutine
) {
  uint32_t tail =
    atomic_fetch_add_explicit(&io->cq_tail, 1, memory_order_relaxed);
  struct moonbit_co_io_completion *completion = &io->cq[tail & 255];
  completion->request = request;
  completion->result = result;
  atomic_store_explicit(
    &completion->coroutine, coroutine, memory_order_release
  );
  dispatch_semaphore_signal(io->semaphore);
}

// -- public API --

MOONBIT_FFI_EXPORT
void
moonbit_co_io_submit_open(
  struct moonbit_co_io *io,
  moonbit_co_os_string_t path,
  moonbit_co_io_access_mode_t access,
  moonbit_co_io_create_mode_t create,
  int32_t append,
  moonbit_co_io_sync_mode_t sync,
  moonbit_co_io_handle_t at,
  int32_t directory,
  struct moonbit_co_io_result *result,
  struct moonbit_co_coroutine *coroutine
) {
  if (at == -1) {
    at = AT_FDCWD;
  }
  int flags = 0;
  switch (access) {
  case MoonbitCoIoAccessReadOnly:
    flags |= O_RDONLY;
    break;
  case MoonbitCoIoAccessWriteOnly:
    flags |= O_WRONLY;
    break;
  case MoonbitCoIoAccessReadWrite:
    flags |= O_RDWR;
    break;
  }
  switch (create) {
  case MoonbitCoIoCreateOpenExisting:
    break;
  case MoonbitCoIoCreateTruncateExisting:
    flags |= O_TRUNC;
    break;
  case MoonbitCoIoCreateOpenOrCreate:
    flags |= O_CREAT;
    break;
  case MoonbitCoIoCreateCreateOrTruncate:
    flags |= O_CREAT | O_TRUNC;
    break;
  case MoonbitCoIoCreateCreateNew:
    flags |= O_CREAT | O_EXCL;
    break;
  }
  if (append) {
    flags |= O_APPEND;
  }
  if (directory) {
    flags |= O_DIRECTORY;
  }
  dispatch_async(io->queue, ^{
    int fd = openat(at, (const char *)path, flags);
    if (fd < 0) {
      result->value = 0;
      result->error = errno;
    } else {
      result->value = (uint64_t)fd;
      result->error = 0;
    }
    moonbit_co_io_schedule(io, path, result, coroutine);
  });
}

MOONBIT_FFI_EXPORT
void
moonbit_co_io_submit_read(
  struct moonbit_co_io *io,
  moonbit_co_io_handle_t handle,
  moonbit_bytes_t buffer,
  int32_t offset,
  int32_t length,
  struct moonbit_co_io_result *result,
  struct moonbit_co_coroutine *coroutine
) {
  dispatch_async(io->queue, ^{
    ssize_t n = read(handle, buffer + offset, length);
    if (n < 0) {
      result->value = 0;
      result->error = errno;
    } else {
      result->value = (uint64_t)n;
      result->error = 0;
    }
    moonbit_co_io_schedule(io, buffer, result, coroutine);
  });
}

MOONBIT_FFI_EXPORT
void
moonbit_co_io_submit_write(
  struct moonbit_co_io *io,
  moonbit_co_io_handle_t handle,
  moonbit_bytes_t buffer,
  int32_t offset,
  int32_t length,
  struct moonbit_co_io_result *result,
  struct moonbit_co_coroutine *coroutine
) {
  dispatch_async(io->queue, ^{
    ssize_t n = write(handle, buffer + offset, length);
    if (n < 0) {
      result->value = 0;
      result->error = errno;
    } else {
      result->value = (uint64_t)n;
      result->error = 0;
    }
    moonbit_co_io_schedule(io, buffer, result, coroutine);
  });
}

void
moonbit_co_io_submit_close(
  struct moonbit_co_io *io,
  moonbit_co_io_handle_t handle,
  struct moonbit_co_io_result *result,
  struct moonbit_co_coroutine *coroutine
) {
  dispatch_async(io->queue, ^{
    int r = close((int)handle);
    if (r < 0) {
      result->value = 0;
      result->error = errno;
    } else {
      result->value = 0;
      result->error = 0;
    }
    moonbit_co_io_schedule(io, NULL, result, coroutine);
  });
}

MOONBIT_FFI_EXPORT
int32_t
moonbit_co_io_poll(
  struct moonbit_co_io *io,
  struct moonbit_co_coroutine **tasks,
  int64_t timeout
) {
  // Block until at least one completion
  dispatch_semaphore_wait(io->semaphore, DISPATCH_TIME_FOREVER);

  uint32_t head = atomic_load_explicit(&io->cq_head, memory_order_relaxed);
  uint32_t tail = atomic_load_explicit(&io->cq_tail, memory_order_acquire);
  int32_t length = Moonbit_array_length(tasks);
  int32_t count = 0;

  while (head != tail && count < length) {
    tasks[count] = io->cq[head & 255].coroutine;
    if (io->cq[head & 255].request)
      moonbit_decref(io->cq[head & 255].request);
    moonbit_decref(io->cq[head & 255].result);
    head++;
    count++;
    // Drain extra semaphore signals for batched completions
    if (head != tail)
      dispatch_semaphore_wait(io->semaphore, DISPATCH_TIME_NOW);
  }

  atomic_store_explicit(&io->cq_head, head, memory_order_release);
  return count;
}

#endif // __APPLE__
