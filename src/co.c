#include <moonbit.h>
#include <stdint.h>
#include <stdlib.h>

#if defined(__unix__) || defined(__APPLE__)
#include <sys/mman.h>
#include <unistd.h>
#endif

typedef struct moonbit_co_context {
#if defined(__x86_64__) || defined(_M_X64)
  uint64_t rsp;
  uint64_t rbp;
  uint64_t rbx;
  uint64_t r12;
  uint64_t r13;
  uint64_t r14;
  uint64_t r15;
  uint64_t rax;
#ifdef _WIN32
  uint64_t rdi;
  uint64_t rsi;
  uint8_t xmm6[16];
  uint8_t xmm7[16];
  uint8_t xmm8[16];
  uint8_t xmm9[16];
  uint8_t xmm10[16];
  uint8_t xmm11[16];
  uint8_t xmm12[16];
  uint8_t xmm13[16];
  uint8_t xmm14[16];
  uint8_t xmm15[16];
#endif
#elif defined(__aarch64__)
  uint64_t sp;
  uint64_t x29; // fp
  uint64_t x30; // lr
  uint64_t x19;
  uint64_t x20;
  uint64_t x21;
  uint64_t x22;
  uint64_t x23;
  uint64_t x24;
  uint64_t x25;
  uint64_t x26;
  uint64_t x27;
  uint64_t x28;
#else
#error "Unsupported architecture"
#endif
} moonbit_co_context_t;

MOONBIT_FFI_EXPORT
moonbit_co_context_t *
moonbit_co_context_make(void) {
  return (moonbit_co_context_t *)moonbit_make_bytes(
    sizeof(moonbit_co_context_t), 0
  );
}

typedef struct {
  void *base;
  uint64_t size;
} co_stack_t;

#if defined(__unix__) || defined(__APPLE__)

static void
co_stack_finalize(void *self) {
  co_stack_t *stack = (co_stack_t *)self;
  long page_size = sysconf(_SC_PAGESIZE);
  void *mmap_base = (char *)stack->base - page_size;
  munmap(mmap_base, page_size + stack->size);
}

MOONBIT_FFI_EXPORT
co_stack_t *
moonbit_co_stack_make(uint64_t size) {
  long page_size = sysconf(_SC_PAGESIZE);
  size = (size + page_size - 1) & ~(page_size - 1);
  size_t total = page_size + size;
  void *base = mmap(
    NULL, total, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0
  );
  if (base == MAP_FAILED) {
    abort();
  }
  mprotect(base, page_size, PROT_NONE);
  co_stack_t *stack = (co_stack_t *)moonbit_make_external_object(
    co_stack_finalize, sizeof(co_stack_t)
  );
  stack->base = (char *)base + page_size;
  stack->size = size;
  return stack;
}

#else

static void
co_stack_finalize(void *self) {
  (void)self;
}

MOONBIT_FFI_EXPORT
co_stack_t *
moonbit_co_stack_make(uint64_t size) {
  co_stack_t *stack = (co_stack_t *)moonbit_make_external_object(
    co_stack_finalize, sizeof(co_stack_t)
  );
  stack->base = (void *)moonbit_make_bytes((int32_t)size, 0);
  stack->size = size;
  return stack;
}

#endif

extern void
moonbit_co__shift(moonbit_co_context_t *from, moonbit_co_context_t *to);

MOONBIT_FFI_EXPORT
void
moonbit_co_shift(moonbit_co_context_t *from, moonbit_co_context_t *to) {
  moonbit_co__shift(from, to);
}

extern void
moonbit_co__reset(
  moonbit_co_context_t *context,
  void *stack_top,
  moonbit_co_context_t *(*func)(void *),
  void *data
);

MOONBIT_FFI_EXPORT
void
moonbit_co_reset(
  moonbit_co_context_t *context,
  co_stack_t *stack,
  moonbit_co_context_t *(*func)(void *),
  void *data
) {
  uintptr_t sp = (uintptr_t)stack->base + stack->size;
  sp &= ~(uintptr_t)0xF;
  moonbit_co__reset(context, (void *)sp, func, data);
}
