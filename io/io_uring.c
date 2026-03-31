#if defined(__linux__)
#include <moonbit.h>

#include <errno.h>
#include <fcntl.h>
#include <linux/io_uring.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <unistd.h>

// -- syscall wrappers --

static int
io_uring_setup(uint32_t entries, struct io_uring_params *p) {
  return (int)syscall(SYS_io_uring_setup, entries, p);
}

static int
io_uring_enter(
  int fd,
  uint32_t to_submit,
  uint32_t min_complete,
  uint32_t flags,
  void *sig,
  size_t sigsz
) {
  return (int)syscall(
    SYS_io_uring_enter, fd, to_submit, min_complete, flags, sig, sigsz
  );
}

// -- ring state --

struct moonbit_co_io {
  int ring_fd;

  // Submission queue
  uint32_t *sq_head;
  uint32_t *sq_tail;
  uint32_t *sq_ring_mask;
  uint32_t *sq_ring_entries;
  uint32_t *sq_array;
  struct io_uring_sqe *sqes;
  void *sq_ring_ptr;
  size_t sq_ring_size;
  size_t sqes_size;

  // Completion queue
  uint32_t *cq_head;
  uint32_t *cq_tail;
  uint32_t *cq_ring_mask;
  uint32_t *cq_ring_entries;
  struct io_uring_cqe *cqes;
  void *cq_ring_ptr;
  size_t cq_ring_size;

  // Pending submission count
  uint32_t sq_pending;

  // Per-slot request state (value/error/task pointers)
  struct {
    uint64_t *value;
    int32_t *error;
    void *task;
  } reqs[256];
};

static void
moonbit_co_io_finalize(void *ptr) {
  struct moonbit_co_io *io = (struct moonbit_co_io *)ptr;
  if (io->sq_ring_ptr)
    munmap(io->sq_ring_ptr, io->sq_ring_size);
  if (io->sqes)
    munmap(io->sqes, io->sqes_size);
  if (io->cq_ring_ptr)
    munmap(io->cq_ring_ptr, io->cq_ring_size);
  if (io->ring_fd >= 0)
    close(io->ring_fd);
}

struct moonbit_co_io *
moonbit_co_io_create(void) {
  struct moonbit_co_io *io =
    (struct moonbit_co_io *)moonbit_make_external_object(
      moonbit_co_io_finalize, sizeof(struct moonbit_co_io)
    );
  memset(io, 0, sizeof(*io));
  io->ring_fd = -1;

  struct io_uring_params params;
  memset(&params, 0, sizeof(params));

  int fd = io_uring_setup(256, &params);
  if (fd < 0)
    abort();

  io->ring_fd = fd;

  // Map SQ ring
  io->sq_ring_size = params.sq_off.array + params.sq_entries * sizeof(uint32_t);
  io->sq_ring_ptr = mmap(
    NULL, io->sq_ring_size, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE,
    fd, IORING_OFF_SQ_RING
  );
  if (io->sq_ring_ptr == MAP_FAILED)
    abort();

  io->sq_head = (uint32_t *)((char *)io->sq_ring_ptr + params.sq_off.head);
  io->sq_tail = (uint32_t *)((char *)io->sq_ring_ptr + params.sq_off.tail);
  io->sq_ring_mask =
    (uint32_t *)((char *)io->sq_ring_ptr + params.sq_off.ring_mask);
  io->sq_ring_entries =
    (uint32_t *)((char *)io->sq_ring_ptr + params.sq_off.ring_entries);
  io->sq_array = (uint32_t *)((char *)io->sq_ring_ptr + params.sq_off.array);

  // Map SQEs
  io->sqes_size = params.sq_entries * sizeof(struct io_uring_sqe);
  void *sqes_ptr = mmap(
    NULL, io->sqes_size, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE, fd,
    IORING_OFF_SQES
  );
  if (sqes_ptr == MAP_FAILED)
    abort();

  io->sqes = (struct io_uring_sqe *)sqes_ptr;

  // Map CQ ring
  io->cq_ring_size =
    params.cq_off.cqes + params.cq_entries * sizeof(struct io_uring_cqe);
  io->cq_ring_ptr = mmap(
    NULL, io->cq_ring_size, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE,
    fd, IORING_OFF_CQ_RING
  );
  if (io->cq_ring_ptr == MAP_FAILED)
    abort();

  io->cq_head = (uint32_t *)((char *)io->cq_ring_ptr + params.cq_off.head);
  io->cq_tail = (uint32_t *)((char *)io->cq_ring_ptr + params.cq_off.tail);
  io->cq_ring_mask =
    (uint32_t *)((char *)io->cq_ring_ptr + params.cq_off.ring_mask);
  io->cq_ring_entries =
    (uint32_t *)((char *)io->cq_ring_ptr + params.cq_off.ring_entries);
  io->cqes =
    (struct io_uring_cqe *)((char *)io->cq_ring_ptr + params.cq_off.cqes);

  return io;
}

// -- submission helpers --

static struct io_uring_sqe *
get_sqe(struct moonbit_co_io *io, uint32_t *out_slot) {
  uint32_t tail = *io->sq_tail;
  uint32_t head =
    atomic_load_explicit((_Atomic uint32_t *)io->sq_head, memory_order_acquire);
  uint32_t mask = *io->sq_ring_mask;

  if (tail - head >= *io->sq_ring_entries) {
    // SQ full — flush pending submissions and retry
    io_uring_enter(io->ring_fd, io->sq_pending, 0, 0, NULL, 0);
    io->sq_pending = 0;
    head = atomic_load_explicit(
      (_Atomic uint32_t *)io->sq_head, memory_order_acquire
    );
    if (tail - head >= *io->sq_ring_entries)
      abort();
  }

  uint32_t index = tail & mask;
  io->sq_array[index] = index;

  struct io_uring_sqe *sqe = &io->sqes[index];
  memset(sqe, 0, sizeof(*sqe));

  *io->sq_tail = tail + 1;
  atomic_thread_fence(memory_order_release);
  io->sq_pending++;

  *out_slot = index;
  return sqe;
}

// -- public API --

void
moonbit_co_io_submit_open(
  struct moonbit_co_io *io,
  const char *path,
  const uint8_t *flags,
  uint64_t *value,
  int32_t *error,
  void *task
) {
  int posix_flags = decode_open_flags(flags);
  int mode = (posix_flags & O_CREAT) ? 0666 : 0;
  uint32_t slot;
  struct io_uring_sqe *sqe = get_sqe(io, &slot);
  sqe->opcode = IORING_OP_OPENAT;
  sqe->fd = AT_FDCWD;
  sqe->addr = (uint64_t)(uintptr_t)path;
  sqe->len = (uint32_t)mode;
  sqe->open_flags = (uint32_t)posix_flags;
  sqe->user_data = slot;
  io->reqs[slot].value = value;
  io->reqs[slot].error = error;
  io->reqs[slot].task = task;
  moonbit_decref(io);
}

void
moonbit_co_io_submit_read(
  struct moonbit_co_io *io,
  uint64_t handle,
  void *buffer,
  int32_t offset,
  int32_t length,
  uint64_t *value,
  int32_t *error,
  void *task
) {
  uint32_t slot;
  struct io_uring_sqe *sqe = get_sqe(io, &slot);
  sqe->opcode = IORING_OP_READ;
  sqe->fd = (int32_t)handle;
  sqe->addr = (uint64_t)(uintptr_t)((uint8_t *)buffer + offset);
  sqe->len = (uint32_t)length;
  sqe->off = (uint64_t)-1; // use current file offset
  sqe->user_data = slot;
  io->reqs[slot].value = value;
  io->reqs[slot].error = error;
  io->reqs[slot].task = task;
  moonbit_decref(io);
}

void
moonbit_co_io_submit_write(
  struct moonbit_co_io *io,
  uint64_t handle,
  const void *buffer,
  int32_t offset,
  int32_t length,
  uint64_t *value,
  int32_t *error,
  void *task
) {
  uint32_t slot;
  struct io_uring_sqe *sqe = get_sqe(io, &slot);
  sqe->opcode = IORING_OP_WRITE;
  sqe->fd = (int32_t)handle;
  sqe->addr = (uint64_t)(uintptr_t)((const uint8_t *)buffer + offset);
  sqe->len = (uint32_t)length;
  sqe->off = (uint64_t)-1; // use current file offset
  sqe->user_data = slot;
  io->reqs[slot].value = value;
  io->reqs[slot].error = error;
  io->reqs[slot].task = task;
  moonbit_decref(io);
}

void
moonbit_co_io_submit_close(
  struct moonbit_co_io *io,
  uint64_t handle,
  uint64_t *value,
  int32_t *error,
  void *task
) {
  uint32_t slot;
  struct io_uring_sqe *sqe = get_sqe(io, &slot);
  sqe->opcode = IORING_OP_CLOSE;
  sqe->fd = (int32_t)handle;
  sqe->user_data = slot;
  io->reqs[slot].value = value;
  io->reqs[slot].error = error;
  io->reqs[slot].task = task;
  moonbit_decref(io);
}

void
moonbit_co_io_poll(
  struct moonbit_co_io *io,
  void **tasks,
  int32_t *count,
  int64_t timeout
) {
  // Flush any pending submissions and wait for at least one completion
  int flags = IORING_ENTER_GETEVENTS;
  int ret;
  do {
    ret = io_uring_enter(io->ring_fd, io->sq_pending, 1, flags, NULL, 0);
  } while (ret < 0 && errno == EINTR);
  if (ret < 0)
    abort();
  io->sq_pending = 0;

  // Drain completions
  uint32_t head = *io->cq_head;
  uint32_t tail =
    atomic_load_explicit((_Atomic uint32_t *)io->cq_tail, memory_order_acquire);
  uint32_t mask = *io->cq_ring_mask;

  int32_t capacity = *count;
  int32_t n = 0;
  while (head != tail && n < capacity) {
    struct io_uring_cqe *cqe = &io->cqes[head & mask];
    uint32_t slot = (uint32_t)cqe->user_data;

    if (cqe->res >= 0) {
      *io->reqs[slot].value = (uint64_t)cqe->res;
      *io->reqs[slot].error = 0;
    } else {
      *io->reqs[slot].value = 0;
      *io->reqs[slot].error = -cqe->res; // positive errno
    }

    moonbit_decref(io->reqs[slot].value);
    moonbit_decref(io->reqs[slot].error);
    tasks[n] = io->reqs[slot].task;
    moonbit_decref(io->reqs[slot].task);

    n++;
    head++;
  }

  atomic_store_explicit(
    (_Atomic uint32_t *)io->cq_head, head, memory_order_release
  );

  *count = n;
}
#endif // __linux__
