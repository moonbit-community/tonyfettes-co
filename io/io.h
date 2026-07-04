#ifndef MOONBIT_CO_IO_H
#define MOONBIT_CO_IO_H

#include <moonbit.h>
#include <fcntl.h>
#include <stdint.h>

struct moonbit_co_io;

// Decode a MoonBit FixedArray[Byte] of boolean flags into POSIX O_* flags.
// Layout: [read, write, append, create, truncate, exclusive]
static inline int
decode_open_flags(const uint8_t *flags) {
  int has_read = flags[0];
  int has_write = flags[1];
  int posix_flags = (has_read && has_write) ? O_RDWR
                    : has_write              ? O_WRONLY
                                             : O_RDONLY;
  if (flags[2]) posix_flags |= O_APPEND;
  if (flags[3]) posix_flags |= O_CREAT;
  if (flags[4]) posix_flags |= O_TRUNC;
  if (flags[5]) posix_flags |= O_EXCL;
  return posix_flags;
}

MOONBIT_FFI_EXPORT
struct moonbit_co_io *
moonbit_co_io_create(void);

MOONBIT_FFI_EXPORT
void
moonbit_co_io_submit_open(
  struct moonbit_co_io *io,
  const char *path,
  const uint8_t *flags,
  uint64_t *value,
  int32_t *error,
  void *task
);

MOONBIT_FFI_EXPORT
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
);

MOONBIT_FFI_EXPORT
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
);

MOONBIT_FFI_EXPORT
void
moonbit_co_io_submit_close(
  struct moonbit_co_io *io,
  uint64_t handle,
  uint64_t *value,
  int32_t *error,
  void *task
);

MOONBIT_FFI_EXPORT
void
moonbit_co_io_poll(
  struct moonbit_co_io *io,
  void **tasks,
  int32_t *count,
  int64_t timeout
);

#endif // MOONBIT_CO_IO_H
