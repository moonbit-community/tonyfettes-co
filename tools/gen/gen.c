// Minimal file I/O FFI for the byte-table generator. MoonBit's native standard
// library has no filesystem package, so the generator reads the extracted
// `.bin` blobs and writes the generated `.c` through these two shims.
#include <moonbit.h>
#include <stdio.h>
#include <stdlib.h>

// Read the whole file at `path` (a NUL-terminated byte string) into a fresh
// moonbit_bytes_t. Aborts if the file cannot be opened or read.
MOONBIT_FFI_EXPORT
moonbit_bytes_t
co_gen_read(moonbit_bytes_t path) {
  FILE *f = fopen((const char *)path, "rb");
  if (!f) {
    fprintf(stderr, "co-gen: cannot open '%s' for reading\n", (const char *)path);
    abort();
  }
  fseek(f, 0, SEEK_END);
  long n = ftell(f);
  fseek(f, 0, SEEK_SET);
  moonbit_bytes_t bytes = moonbit_make_bytes(n, 0);
  if (n > 0 && fread(bytes, 1, (size_t)n, f) != (size_t)n) {
    fprintf(stderr, "co-gen: short read on '%s'\n", (const char *)path);
    abort();
  }
  fclose(f);
  return bytes;
}

// Write `data` verbatim to the file at `path` (a NUL-terminated byte string).
MOONBIT_FFI_EXPORT
void
co_gen_write(moonbit_bytes_t path, moonbit_bytes_t data) {
  FILE *f = fopen((const char *)path, "wb");
  if (!f) {
    fprintf(stderr, "co-gen: cannot open '%s' for writing\n", (const char *)path);
    abort();
  }
  int32_t n = Moonbit_array_length(data);
  if (n > 0 && fwrite(data, 1, (size_t)n, f) != (size_t)n) {
    fprintf(stderr, "co-gen: short write on '%s'\n", (const char *)path);
    abort();
  }
  fclose(f);
}
