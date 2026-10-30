#ifndef MOONBIT_CO_IO_H
#define MOONBIT_CO_IO_H

#include <fcntl.h>
#include <moonbit.h>
#include <stdint.h>

typedef moonbit_bytes_t moonbit_co_os_string_t;

typedef int moonbit_co_io_handle_t;

struct moonbit_co_io;

struct moonbit_co_coroutine;

typedef enum moonbit_co_io_create_mode {
  MoonbitCoIoCreateOpenExisting = 0,
  MoonbitCoIoCreateTruncateExisting = 1,
  MoonbitCoIoCreateOpenOrCreate = 2,
  MoonbitCoIoCreateCreateOrTruncate = 3,
  MoonbitCoIoCreateCreateNew = 4,
} moonbit_co_io_create_mode_t;

typedef enum moonbit_co_io_access_mode {
  MoonbitCoIoAccessReadOnly = 0,
  MoonbitCoIoAccessWriteOnly = 1,
  MoonbitCoIoAccessReadWrite = 2,
} moonbit_co_io_access_mode_t;

typedef enum moonbit_co_io_sync_mode {
  MoonbitCoIoSyncNone = 0,
  MoonbitCoIoSyncData = 1,
  MoonbitCoIoSyncFull = 2,
} moonbit_co_io_sync_mode_t;

struct moonbit_co_io_result {
  uint64_t value;
  uint64_t error;
};

// Allocate an uninitialized I/O context. Never fails; the returned object is
// safe to finalize as-is.
MOONBIT_FFI_EXPORT
struct moonbit_co_io *
moonbit_co_io_alloc(void);

// Initialize an allocated I/O context in place. Returns 0 on success or a
// positive errno; a failed context is left in a state the finalizer can clean
// up.
MOONBIT_FFI_EXPORT
int32_t
moonbit_co_io_init(struct moonbit_co_io *io);

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
);

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
);

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
);

MOONBIT_FFI_EXPORT
void
moonbit_co_io_submit_close(
  struct moonbit_co_io *io,
  moonbit_co_io_handle_t handle,
  struct moonbit_co_io_result *result,
  struct moonbit_co_coroutine *coroutine
);

// Accept a connection on a listening socket. `peer` is an owned 132-byte buffer:
// [0..128) receives the peer `sockaddr`, [128..132) is the sockaddr length, both
// written by the kernel before completion.
MOONBIT_FFI_EXPORT
void
moonbit_co_io_submit_accept(
  struct moonbit_co_io *io,
  moonbit_co_io_handle_t handle,
  moonbit_bytes_t peer,
  struct moonbit_co_io_result *result,
  struct moonbit_co_coroutine *coroutine
);

// Receive from a socket: like read(), but records a zero-length result as EOF
// rather than moving a file offset.
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
);

// Send to a socket with MSG_NOSIGNAL, so a peer that closed its end yields EPIPE
// instead of killing the process with SIGPIPE.
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
);

// Connect `handle` to the `sockaddr` held in `addr` (a 16-byte `sockaddr_in`),
// without blocking the thread that submits it.
MOONBIT_FFI_EXPORT
void
moonbit_co_io_submit_connect(
  struct moonbit_co_io *io,
  moonbit_co_io_handle_t handle,
  moonbit_bytes_t addr,
  struct moonbit_co_io_result *result,
  struct moonbit_co_coroutine *coroutine
);

MOONBIT_FFI_EXPORT
int32_t
moonbit_co_io_poll(
  struct moonbit_co_io *io,
  struct moonbit_co_coroutine **tasks,
  int64_t timeout
);

#endif // MOONBIT_CO_IO_H
