; moonbit_co__reset(ctx, stack_top, func, arg)
; Win64 ABI: rcx=ctx, rdx=stack_top, r8=func, r9=arg
;
; Saves the current context into ctx, switches sp to stack_top,
; calls func(arg) on the new stack. func returns a pointer to a
; context. When func returns, restores the saved context from
; the returned pointer and returns to the caller.

_TEXT SEGMENT

moonbit_co__reset PROC
  ; Save callee-saved registers into ctx
  mov [rcx], rsp
  mov [rcx+8], rbp
  mov [rcx+16], rbx
  mov [rcx+24], r12
  mov [rcx+32], r13
  mov [rcx+40], r14
  mov [rcx+48], r15
  ; Save return address
  mov rax, [rsp]
  mov [rcx+56], rax
  ; Save Win64 extra callee-saved registers
  mov [rcx+64], rdi
  mov [rcx+72], rsi
  movdqu [rcx+80], xmm6
  movdqu [rcx+96], xmm7
  movdqu [rcx+112], xmm8
  movdqu [rcx+128], xmm9
  movdqu [rcx+144], xmm10
  movdqu [rcx+160], xmm11
  movdqu [rcx+176], xmm12
  movdqu [rcx+192], xmm13
  movdqu [rcx+208], xmm14
  movdqu [rcx+224], xmm15

  ; Switch to the new stack
  mov rsp, rdx

  ; Allocate 32-byte shadow space (Win64 ABI requirement)
  sub rsp, 32

  ; Call func(arg): rcx=arg (first param on Win64), func is in r8
  ; func returns a context pointer in rax
  mov rcx, r9
  call r8

  ; Restore context from the pointer returned by func (in rax)
  mov rsp, [rax]
  mov rbp, [rax+8]
  mov rbx, [rax+16]
  mov r12, [rax+24]
  mov r13, [rax+32]
  mov r14, [rax+40]
  mov r15, [rax+48]
  mov rcx, [rax+56]
  mov [rsp], rcx
  ; Restore Win64 extra callee-saved registers
  mov rdi, [rax+64]
  mov rsi, [rax+72]
  movdqu xmm6, [rax+80]
  movdqu xmm7, [rax+96]
  movdqu xmm8, [rax+112]
  movdqu xmm9, [rax+128]
  movdqu xmm10, [rax+144]
  movdqu xmm11, [rax+160]
  movdqu xmm12, [rax+176]
  movdqu xmm13, [rax+192]
  movdqu xmm14, [rax+208]
  movdqu xmm15, [rax+224]

  ret
moonbit_co__reset ENDP

_TEXT ENDS
END
