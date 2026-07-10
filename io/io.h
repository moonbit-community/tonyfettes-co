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

MOONBIT_FFI_EXPORT
struct moonbit_co_io *
moonbit_co_io_create(void);

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

MOONBIT_FFI_EXPORT
int32_t
moonbit_co_io_poll(
  struct moonbit_co_io *io,
  struct moonbit_co_coroutine **tasks,
  int64_t timeout
);

#endif // MOONBIT_CO_IO_H
