// moonbit_co__reset(ctx, stack_top, func, arg)
//
// Saves the current context into ctx, switches sp to stack_top,
// calls func(arg) on the new stack. func returns a pointer to a
// context. When func returns, restores the saved context from
// the returned pointer and returns to the caller.

#if defined(__ELF__)
#define SYMBOL(name) name
#define FUNC_TYPE(name) .type name, @function
#define FUNC_SIZE(name) .size name, .-name
#elif defined(__APPLE__)
#define SYMBOL(name) _##name
#define FUNC_TYPE(name)
#define FUNC_SIZE(name)
#else
#define SYMBOL(name) name
#define FUNC_TYPE(name)
#define FUNC_SIZE(name)
#endif

.text
.globl SYMBOL(moonbit_co__reset)
FUNC_TYPE(SYMBOL(moonbit_co__reset))
.p2align 2
SYMBOL(moonbit_co__reset):

#if defined(__x86_64__)

#ifdef _WIN32
  // Win64 ABI: rcx=ctx, rdx=stack_top, r8=func, r9=arg
  // Save callee-saved registers into ctx
  movq %rsp, 0(%rcx)
  movq %rbp, 8(%rcx)
  movq %rbx, 16(%rcx)
  movq %r12, 24(%rcx)
  movq %r13, 32(%rcx)
  movq %r14, 40(%rcx)
  movq %r15, 48(%rcx)
  // Save return address
  movq (%rsp), %rax
  movq %rax, 56(%rcx)
  // Save Win64 extra callee-saved registers
  movq %rdi, 64(%rcx)
  movq %rsi, 72(%rcx)
  movdqu %xmm6,  80(%rcx)
  movdqu %xmm7,  96(%rcx)
  movdqu %xmm8,  112(%rcx)
  movdqu %xmm9,  128(%rcx)
  movdqu %xmm10, 144(%rcx)
  movdqu %xmm11, 160(%rcx)
  movdqu %xmm12, 176(%rcx)
  movdqu %xmm13, 192(%rcx)
  movdqu %xmm14, 208(%rcx)
  movdqu %xmm15, 224(%rcx)

  // Switch to the new stack
  movq %rdx, %rsp

  // Allocate 32-byte shadow space (Win64 ABI requirement)
  subq $32, %rsp

  // Call func(arg): rcx=arg (first param on Win64), func is in r8
  // func returns a context pointer in rax
  movq %r9, %rcx
  callq *%r8

  // Restore context from the pointer returned by func (in rax)
  movq 0(%rax), %rsp
  movq 8(%rax), %rbp
  movq 16(%rax), %rbx
  movq 24(%rax), %r12
  movq 32(%rax), %r13
  movq 40(%rax), %r14
  movq 48(%rax), %r15
  movq 56(%rax), %rcx
  movq %rcx, (%rsp)
  // Restore Win64 extra callee-saved registers
  movq 64(%rax), %rdi
  movq 72(%rax), %rsi
  movdqu 80(%rax),  %xmm6
  movdqu 96(%rax),  %xmm7
  movdqu 112(%rax), %xmm8
  movdqu 128(%rax), %xmm9
  movdqu 144(%rax), %xmm10
  movdqu 160(%rax), %xmm11
  movdqu 176(%rax), %xmm12
  movdqu 192(%rax), %xmm13
  movdqu 208(%rax), %xmm14
  movdqu 224(%rax), %xmm15
#else
  // SysV ABI: rdi=ctx, rsi=stack_top, rdx=func, rcx=arg
  // Save callee-saved registers into ctx
  movq %rsp, 0(%rdi)
  movq %rbp, 8(%rdi)
  movq %rbx, 16(%rdi)
  movq %r12, 24(%rdi)
  movq %r13, 32(%rdi)
  movq %r14, 40(%rdi)
  movq %r15, 48(%rdi)
  // Save return address
  movq (%rsp), %rax
  movq %rax, 56(%rdi)

  // Switch to the new stack
  movq %rsi, %rsp

  // Call func(arg)
  // func returns a context pointer in rax
  movq %rcx, %rdi
  callq *%rdx

  // Restore context from the pointer returned by func (in rax)
  movq 0(%rax), %rsp
  movq 8(%rax), %rbp
  movq 16(%rax), %rbx
  movq 24(%rax), %r12
  movq 32(%rax), %r13
  movq 40(%rax), %r14
  movq 48(%rax), %r15
  movq 56(%rax), %rcx
  movq %rcx, (%rsp)
#endif

  ret

#elif defined(__aarch64__)
  // arm64: x0=ctx, x1=stack_top, x2=func, x3=arg

  // Save callee-saved registers into ctx
  mov x9, sp
  str x9, [x0, #0]        // sp
  stp x29, x30, [x0, #8]  // fp, lr
  stp x19, x20, [x0, #24]
  stp x21, x22, [x0, #40]
  stp x23, x24, [x0, #56]
  stp x25, x26, [x0, #72]
  stp x27, x28, [x0, #88]

  // Switch to the new stack
  mov sp, x1

  // Call func(arg)
  // func returns a context pointer in x0
  mov x0, x3
  blr x2

  // Restore context from the pointer returned by func (in x0)
  ldr x9, [x0, #0]
  mov sp, x9
  ldp x29, x30, [x0, #8]
  ldp x19, x20, [x0, #24]
  ldp x21, x22, [x0, #40]
  ldp x23, x24, [x0, #56]
  ldp x25, x26, [x0, #72]
  ldp x27, x28, [x0, #88]

  ret

#else
#error "Unsupported architecture"
#endif

FUNC_SIZE(SYMBOL(moonbit_co__reset))

#if defined(__ELF__)
.section .note.GNU-stack, "", @progbits
#endif
