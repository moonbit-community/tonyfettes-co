// moonbit_co__shift(from, to)
//
// Saves the current context into `from`, then loads the context
// from `to` and returns into it.

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
.globl SYMBOL(moonbit_co__shift)
FUNC_TYPE(SYMBOL(moonbit_co__shift))
.p2align 2
SYMBOL(moonbit_co__shift):

#if defined(__x86_64__)
  // CET landing pad for indirect calls into the embedded code blob
  endbr64

#ifdef _WIN32
  // Win64 ABI: rcx=from, rdx=to
  // Save callee-saved registers into from
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

  // Load callee-saved registers from to
  movq 0(%rdx), %rsp
  movq 8(%rdx), %rbp
  movq 16(%rdx), %rbx
  movq 24(%rdx), %r12
  movq 32(%rdx), %r13
  movq 40(%rdx), %r14
  movq 48(%rdx), %r15
  movq 56(%rdx), %rax
  movq %rax, (%rsp)
  // Restore Win64 extra callee-saved registers
  movq 64(%rdx), %rdi
  movq 72(%rdx), %rsi
  movdqu 80(%rdx),  %xmm6
  movdqu 96(%rdx),  %xmm7
  movdqu 112(%rdx), %xmm8
  movdqu 128(%rdx), %xmm9
  movdqu 144(%rdx), %xmm10
  movdqu 160(%rdx), %xmm11
  movdqu 176(%rdx), %xmm12
  movdqu 192(%rdx), %xmm13
  movdqu 208(%rdx), %xmm14
  movdqu 224(%rdx), %xmm15
#else
  // SysV ABI: rdi=from, rsi=to
  // Save callee-saved registers into from
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

  // Load callee-saved registers from to
  movq 0(%rsi), %rsp
  movq 8(%rsi), %rbp
  movq 16(%rsi), %rbx
  movq 24(%rsi), %r12
  movq 32(%rsi), %r13
  movq 40(%rsi), %r14
  movq 48(%rsi), %r15
  // Load return address
  movq 56(%rsi), %rax
  movq %rax, (%rsp)
#endif

  ret

#elif defined(__aarch64__)
  // arm64: x0=from, x1=to
  // BTI landing pad for indirect calls into the embedded code blob
  bti c

  // Save callee-saved registers into from
  mov x9, sp
  str x9, [x0, #0]        // sp
  stp x29, x30, [x0, #8]  // fp, lr
  stp x19, x20, [x0, #24]
  stp x21, x22, [x0, #40]
  stp x23, x24, [x0, #56]
  stp x25, x26, [x0, #72]
  stp x27, x28, [x0, #88]

  // Load callee-saved registers from to
  ldr x9, [x1, #0]
  mov sp, x9
  ldp x29, x30, [x1, #8]
  ldp x19, x20, [x1, #24]
  ldp x21, x22, [x1, #40]
  ldp x23, x24, [x1, #56]
  ldp x25, x26, [x1, #72]
  ldp x27, x28, [x1, #88]

  ret

#else
#error "Unsupported architecture"
#endif

FUNC_SIZE(SYMBOL(moonbit_co__shift))

#if defined(__ELF__)
.section .note.GNU-stack, "", @progbits
#endif
