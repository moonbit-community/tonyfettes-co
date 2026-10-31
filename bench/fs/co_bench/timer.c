#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#include "moonbit.h"

// Monotonic clock in nanoseconds; the benchmark harness needs sub-microsecond
// resolution, which `@bench.monotonic_clock_end` (microseconds) cannot give.
int64_t
co_bench_now_ns(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (int64_t)ts.tv_sec * 1000000000LL + (int64_t)ts.tv_nsec;
}

// Evict a file's pages from the page cache without needing root, so that the
// next read has to hit the disk (`posix_fadvise(..., POSIX_FADV_DONTNEED)`).
//
// MoonBit strings are UTF-16, so encode the path to UTF-8 first.
int32_t
co_bench_evict(moonbit_string_t path) {
  int32_t length = Moonbit_array_length(path);
  char buffer[4096];
  int32_t out = 0;
  for (int32_t i = 0; i < length; i++) {
    uint32_t c = path[i];
    if (c < 0x80) {
      buffer[out++] = (char)c;
    } else if (c < 0x800) {
      buffer[out++] = (char)(0xC0 | (c >> 6));
      buffer[out++] = (char)(0x80 | (c & 0x3F));
    } else {
      buffer[out++] = (char)(0xE0 | (c >> 12));
      buffer[out++] = (char)(0x80 | ((c >> 6) & 0x3F));
      buffer[out++] = (char)(0x80 | (c & 0x3F));
    }
    if (out >= (int32_t)sizeof(buffer) - 1) {
      return -ENAMETOOLONG;
    }
  }
  buffer[out] = '\0';

  int fd = open(buffer, O_RDONLY);
  if (fd < 0) {
    return -errno;
  }
  int r = posix_fadvise(fd, 0, 0, POSIX_FADV_DONTNEED);
  close(fd);
  return r == 0 ? 0 : -r;
}
