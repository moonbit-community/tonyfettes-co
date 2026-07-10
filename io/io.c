#if defined(__linux__)
#include "io_uring.c"
#elif defined(_WIN32)
// TODO: IOCP backend
#error "Windows IOCP backend not yet implemented"
#elif defined(__APPLE__)
#include "io_gcd.c"
#else
#error "Unsupported platform"
#endif
