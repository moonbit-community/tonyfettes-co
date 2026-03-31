#if defined(__APPLE__)
#include <moonbit.h>

#include <dispatch/dispatch.h>
#include <errno.h>
#include <fcntl.h>
#include <stdatomic.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>

// -- state --

struct moonbit_co_io {
  dispatch_queue_t queue;
  dispatch_semaphore_t sem;

  // Completion ring buffer
  // Producer: GCD worker threads (one per block)
  // Consumer: scheduler thread (poll)
  struct {
    void *task;
  } completions[256];
  _Atomic uint32_t cq_head;
  _Atomic uint32_t cq_tail;
};

static void
moonbit_co_io_finalize(void *ptr) {
  struct moonbit_co_io *io = (struct moonbit_co_io *)ptr;
  if (io->queue)
    dispatch_release(io->queue);
  if (io->sem)
    dispatch_release(io->sem);
}

struct moonbit_co_io *
moonbit_co_io_create(void) {
  struct moonbit_co_io *io =
    (struct moonbit_co_io *)moonbit_make_external_object(
      moonbit_co_io_finalize, sizeof(struct moonbit_co_io)
    );
  memset(io, 0, sizeof(*io));
  io->queue = dispatch_queue_create("co.io", DISPATCH_QUEUE_CONCURRENT);
  io->sem = dispatch_semaphore_create(0);
  return io;
}

// -- completion ring --

static void
push_completion(struct moonbit_co_io *io, void *task) {
  uint32_t tail = atomic_load_explicit(&io->cq_tail, memory_order_relaxed);
  io->completions[tail & 255].task = task;
  atomic_store_explicit(&io->cq_tail, tail + 1, memory_order_release);
  dispatch_semaphore_signal(io->sem);
}

// -- public API --

void
moonbit_co_io_submit_open(
  struct moonbit_co_io *io,
  const char *path,
  int32_t flags,
  int32_t mode,
  uint64_t *value,
  int32_t *error,
  void *task
) {
  dispatch_async(io->queue, ^{
    int fd = open(path, flags, mode);
    if (fd < 0) {
      *value = 0;
      *error = errno;
    } else {
      *value = (uint64_t)fd;
      *error = 0;
    }
    moonbit_decref(io);
    moonbit_decref((void *)path);
    moonbit_decref(value);
    moonbit_decref(error);
    push_completion(io, task);
    moonbit_decref(task);
  });
}

void
moonbit_co_io_submit_read(
  struct moonbit_co_io *io,
  uint64_t handle,
  void *bytes,
  int32_t length,
  uint64_t *value,
  int32_t *error,
  void *task
) {
  dispatch_async(io->queue, ^{
    ssize_t n = read((int)handle, bytes, length);
    if (n < 0) {
      *value = 0;
      *error = errno;
    } else {
      *value = (uint64_t)n;
      *error = 0;
    }
    moonbit_decref(io);
    moonbit_decref(bytes);
    moonbit_decref(value);
    moonbit_decref(error);
    push_completion(io, task);
    moonbit_decref(task);
  });
}

void
moonbit_co_io_submit_write(
  struct moonbit_co_io *io,
  uint64_t handle,
  void *bytes,
  int32_t length,
  uint64_t *value,
  int32_t *error,
  void *task
) {
  dispatch_async(io->queue, ^{
    ssize_t n = write((int)handle, bytes, length);
    if (n < 0) {
      *value = 0;
      *error = errno;
    } else {
      *value = (uint64_t)n;
      *error = 0;
    }
    moonbit_decref(io);
    moonbit_decref(bytes);
    moonbit_decref(value);
    moonbit_decref(error);
    push_completion(io, task);
    moonbit_decref(task);
  });
}

void
moonbit_co_io_submit_close(
  struct moonbit_co_io *io,
  uint64_t handle,
  uint64_t *value,
  int32_t *error,
  void *task
) {
  dispatch_async(io->queue, ^{
    int r = close((int)handle);
    if (r < 0) {
      *value = 0;
      *error = errno;
    } else {
      *value = 0;
      *error = 0;
    }
    moonbit_decref(io);
    moonbit_decref(value);
    moonbit_decref(error);
    push_completion(io, task);
    moonbit_decref(task);
  });
}

void
moonbit_co_io_poll(
  struct moonbit_co_io *io,
  void **tasks,
  int32_t *count,
  int64_t timeout
) {
  // Block until at least one completion
  dispatch_semaphore_wait(io->sem, DISPATCH_TIME_FOREVER);

  uint32_t head = atomic_load_explicit(&io->cq_head, memory_order_relaxed);
  uint32_t tail = atomic_load_explicit(&io->cq_tail, memory_order_acquire);
  int32_t max = *count;
  int32_t n = 0;

  while (head != tail && n < max) {
    tasks[n] = io->completions[head & 255].task;
    head++;
    n++;
    // Drain extra semaphore signals for batched completions
    if (head != tail)
      dispatch_semaphore_wait(io->sem, DISPATCH_TIME_NOW);
  }

  atomic_store_explicit(&io->cq_head, head, memory_order_release);
  *count = n;
}

#endif // __APPLE__
