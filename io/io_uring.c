#if defined(__linux__)
#include <moonbit.h>

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <linux/io_uring.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <unistd.h>

#include "io.h"

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

struct moonbit_co_io_completion {
  struct moonbit_co_coroutine *coroutine;
  void *request;
  struct moonbit_co_io_result *result;
};

// Concurrent in-flight operations this backend can track. Each parked coroutine
// owns one slot (a pending accept/read/write), so this is also the connection
// ceiling for the io_uring path.
enum { MoonbitCoIoSlots = 4096 };

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

  // Per-slot request state (value/error/task pointers). `retain` holds an owned
  // MoonBit object the kernel still accesses after submit returns (the open
  // path, or the read/write buffer) so it is not freed before completion; NULL
  // when there is nothing to retain.
  //
  // Slots are NOT the submission-queue index: the kernel frees an SQ index as
  // soon as it consumes the SQE, long before the request completes, so using it
  // as the slot id lets a new submission overwrite a table entry whose request
  // is still in flight (and then the completion wakes the wrong coroutine).
  // Slots come from `slot_free` and are recycled only by `poll`.
  struct moonbit_co_io_completion completion[MoonbitCoIoSlots];
  uint32_t slot_free[MoonbitCoIoSlots];
  uint32_t slot_free_len;
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

MOONBIT_FFI_EXPORT
struct moonbit_co_io *
moonbit_co_io_alloc(void) {
  struct moonbit_co_io *io = moonbit_make_external_object(
    moonbit_co_io_finalize, sizeof(struct moonbit_co_io)
  );
  memset(io, 0, sizeof(*io));
  io->ring_fd = -1;
  return io;
}

MOONBIT_FFI_EXPORT
int32_t
moonbit_co_io_init(struct moonbit_co_io *io) {
  struct io_uring_params params;
  memset(&params, 0, sizeof(params));

  int fd = io_uring_setup(MoonbitCoIoSlots, &params);
  if (fd < 0) {
    return errno;
  }

  io->ring_fd = fd;

  for (uint32_t i = 0; i < MoonbitCoIoSlots; i++) {
    io->slot_free[i] = MoonbitCoIoSlots - 1 - i;
  }
  io->slot_free_len = MoonbitCoIoSlots;

  // Map SQ ring
  io->sq_ring_size = params.sq_off.array + params.sq_entries * sizeof(uint32_t);
  io->sq_ring_ptr = mmap(
    NULL, io->sq_ring_size, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE,
    fd, IORING_OFF_SQ_RING
  );
  if (io->sq_ring_ptr == MAP_FAILED) {
    // Reset to NULL so the finalizer's non-NULL check does not munmap
    // MAP_FAILED; the fd is closed by the finalizer via ring_fd.
    io->sq_ring_ptr = NULL;
    return errno;
  }

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
  if (sqes_ptr == MAP_FAILED) {
    return errno;
  }

  io->sqes = (struct io_uring_sqe *)sqes_ptr;

  // Map CQ ring
  io->cq_ring_size =
    params.cq_off.cqes + params.cq_entries * sizeof(struct io_uring_cqe);
  io->cq_ring_ptr = mmap(
    NULL, io->cq_ring_size, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE,
    fd, IORING_OFF_CQ_RING
  );
  if (io->cq_ring_ptr == MAP_FAILED) {
    io->cq_ring_ptr = NULL;
    return errno;
  }

  io->cq_head = (uint32_t *)((char *)io->cq_ring_ptr + params.cq_off.head);
  io->cq_tail = (uint32_t *)((char *)io->cq_ring_ptr + params.cq_off.tail);
  io->cq_ring_mask =
    (uint32_t *)((char *)io->cq_ring_ptr + params.cq_off.ring_mask);
  io->cq_ring_entries =
    (uint32_t *)((char *)io->cq_ring_ptr + params.cq_off.ring_entries);
  io->cqes =
    (struct io_uring_cqe *)((char *)io->cq_ring_ptr + params.cq_off.cqes);

  return 0;
}

// -- submission helpers --

static struct io_uring_sqe *
get_sqe(struct moonbit_co_io *io) {
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

  return sqe;
}

// Slots are recycled by `poll` only, so a slot owned by an in-flight request is
// never handed out again.
static uint32_t
alloc_slot(struct moonbit_co_io *io) {
  if (io->slot_free_len == 0) {
    // Every slot is in flight: more concurrent operations than the table can
    // track. Raising MoonbitCoIoSlots raises the ceiling.
    fprintf(
      stderr,
      "co-io: all %d io_uring request slots are in flight\n",
      (int)MoonbitCoIoSlots
    );
    abort();
  }
  return io->slot_free[--io->slot_free_len];
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
  int32_t at,
  moonbit_co_io_handle_t directory,
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
  switch (sync) {
  case MoonbitCoIoSyncNone:
    break;
  case MoonbitCoIoSyncData:
    flags |= O_DSYNC;
    break;
  case MoonbitCoIoSyncFull:
    flags |= O_SYNC;
    break;
  }
  if (append) {
    flags |= O_APPEND;
  }
  if (directory) {
    flags |= O_DIRECTORY;
  }
  int mode = (flags & O_CREAT) ? 0666 : 0;
  uint32_t slot = alloc_slot(io);
  struct io_uring_sqe *sqe = get_sqe(io);
  sqe->opcode = IORING_OP_OPENAT;
  sqe->fd = at;
  sqe->addr = (uint64_t)(uintptr_t)path;
  sqe->len = (uint32_t)mode;
  sqe->open_flags = (uint32_t)flags;
  sqe->user_data = slot;
  io->completion[slot].request = path;
  io->completion[slot].result = result;
  io->completion[slot].coroutine = coroutine;
  moonbit_decref(io);
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
  uint32_t slot = alloc_slot(io);
  struct io_uring_sqe *sqe = get_sqe(io);
  sqe->opcode = IORING_OP_READ;
  sqe->fd = (int32_t)handle;
  sqe->addr = (uint64_t)(uintptr_t)((uint8_t *)buffer + offset);
  sqe->len = (uint32_t)length;
  sqe->off = (uint64_t)-1; // use current file offset
  sqe->user_data = slot;
  io->completion[slot].request = buffer;
  io->completion[slot].result = result;
  io->completion[slot].coroutine = coroutine;
  moonbit_decref(io);
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
  uint32_t slot = alloc_slot(io);
  struct io_uring_sqe *sqe = get_sqe(io);
  sqe->opcode = IORING_OP_WRITE;
  sqe->fd = (int32_t)handle;
  sqe->addr = (uint64_t)(uintptr_t)((const uint8_t *)buffer + offset);
  sqe->len = (uint32_t)length;
  sqe->off = (uint64_t)-1; // use current file offset
  sqe->user_data = slot;
  io->completion[slot].request = buffer;
  io->completion[slot].result = result;
  io->completion[slot].coroutine = coroutine;
  moonbit_decref(io);
}

MOONBIT_FFI_EXPORT
void
moonbit_co_io_submit_close(
  struct moonbit_co_io *io,
  moonbit_co_io_handle_t handle,
  struct moonbit_co_io_result *result,
  struct moonbit_co_coroutine *coroutine
) {
  uint32_t slot = alloc_slot(io);
  struct io_uring_sqe *sqe = get_sqe(io);
  sqe->opcode = IORING_OP_CLOSE;
  sqe->fd = (int32_t)handle;
  sqe->user_data = slot;
  io->completion[slot].request = NULL; // close has no payload to keep alive
  io->completion[slot].result = result;
  io->completion[slot].coroutine = coroutine;
  moonbit_decref(io);
}

MOONBIT_FFI_EXPORT
void
moonbit_co_io_submit_accept(
  struct moonbit_co_io *io,
  moonbit_co_io_handle_t handle,
  moonbit_bytes_t peer,
  struct moonbit_co_io_result *result,
  struct moonbit_co_coroutine *coroutine
) {
  uint32_t slot = alloc_slot(io);
  struct io_uring_sqe *sqe = get_sqe(io);
  // The kernel writes the peer address into `peer` before the CQE arrives, so
  // the buffer must stay alive until completion: it is retained as `request`.
  *(uint32_t *)(peer + 128) = 128;
  sqe->opcode = IORING_OP_ACCEPT;
  sqe->fd = (int32_t)handle;
  sqe->addr = (uint64_t)(uintptr_t)peer;
  sqe->addr2 = (uint64_t)(uintptr_t)(peer + 128);
  sqe->accept_flags = 0;
  sqe->user_data = slot;
  io->completion[slot].request = peer;
  io->completion[slot].result = result;
  io->completion[slot].coroutine = coroutine;
  moonbit_decref(io);
}

MOONBIT_FFI_EXPORT
void
moonbit_co_io_submit_recv(
  struct moonbit_co_io *io,
  moonbit_co_io_handle_t handle,
  moonbit_bytes_t buffer,
  int32_t offset,
  int32_t length,
  struct moonbit_co_io_result *result,
  struct moonbit_co_coroutine *coroutine
) {
  uint32_t slot = alloc_slot(io);
  struct io_uring_sqe *sqe = get_sqe(io);
  sqe->opcode = IORING_OP_RECV;
  sqe->fd = (int32_t)handle;
  sqe->addr = (uint64_t)(uintptr_t)((uint8_t *)buffer + offset);
  sqe->len = (uint32_t)length;
  sqe->user_data = slot;
  io->completion[slot].request = buffer;
  io->completion[slot].result = result;
  io->completion[slot].coroutine = coroutine;
  moonbit_decref(io);
}

MOONBIT_FFI_EXPORT
void
moonbit_co_io_submit_send(
  struct moonbit_co_io *io,
  moonbit_co_io_handle_t handle,
  moonbit_bytes_t buffer,
  int32_t offset,
  int32_t length,
  struct moonbit_co_io_result *result,
  struct moonbit_co_coroutine *coroutine
) {
  uint32_t slot = alloc_slot(io);
  struct io_uring_sqe *sqe = get_sqe(io);
  sqe->opcode = IORING_OP_SEND;
  sqe->fd = (int32_t)handle;
  sqe->addr = (uint64_t)(uintptr_t)((const uint8_t *)buffer + offset);
  sqe->len = (uint32_t)length;
  sqe->msg_flags = MSG_NOSIGNAL;
  sqe->user_data = slot;
  io->completion[slot].request = buffer;
  io->completion[slot].result = result;
  io->completion[slot].coroutine = coroutine;
  moonbit_decref(io);
}

MOONBIT_FFI_EXPORT
int32_t
moonbit_co_io_poll(
  struct moonbit_co_io *io,
  struct moonbit_co_coroutine **coroutines,
  int64_t timeout
) {
  // Flush any pending submissions and wait for at least one completion
  int flags = IORING_ENTER_GETEVENTS;
  int ret;
  do {
    ret = io_uring_enter(io->ring_fd, io->sq_pending, 1, flags, NULL, 0);
  } while (ret < 0 && errno == EINTR);
  if (ret < 0) {
    return -errno;
  }
  io->sq_pending = 0;

  // Drain completions
  uint32_t head = *io->cq_head;
  uint32_t tail =
    atomic_load_explicit((_Atomic uint32_t *)io->cq_tail, memory_order_acquire);
  uint32_t mask = *io->cq_ring_mask;
  int32_t capacity = Moonbit_array_length(coroutines);
  int32_t count = 0;
  while (head != tail && count < capacity) {
    struct io_uring_cqe *cqe = &io->cqes[head & mask];
    uint32_t slot = (uint32_t)cqe->user_data;

    if (cqe->res >= 0) {
      io->completion[slot].result->value = (uint64_t)cqe->res;
      io->completion[slot].result->error = 0;
    } else {
      io->completion[slot].result->value = 0;
      io->completion[slot].result->error = -cqe->res; // positive errno
    }

    if (io->completion[slot].request) {
      moonbit_decref(io->completion[slot].request);
    }
    moonbit_decref(io->completion[slot].result);
    coroutines[count] = io->completion[slot].coroutine;
    moonbit_decref(io->completion[slot].coroutine);
    io->completion[slot].request = NULL;
    io->completion[slot].result = NULL;
    io->completion[slot].coroutine = NULL;
    io->slot_free[io->slot_free_len++] = slot;

    count++;
    head++;
  }

  atomic_store_explicit(
    (_Atomic uint32_t *)io->cq_head, head, memory_order_release
  );

  return count;
}
#endif // __linux__
