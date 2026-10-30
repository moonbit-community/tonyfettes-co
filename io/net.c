// Raw socket setup. These calls never block for long (bind/listen return
// immediately); the blocking-wait part of every operation goes through the
// io_uring / GCD backends in io.c.
#include <moonbit.h>

#include <errno.h>
#include <stdint.h>
#include <string.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <unistd.h>

static void
fill_v4(struct sockaddr_in *addr, uint32_t ip_be, uint32_t port) {
  memset(addr, 0, sizeof(*addr));
  addr->sin_family = AF_INET;
  addr->sin_addr.s_addr = htonl(ip_be);
  addr->sin_port = htons((uint16_t)port);
}

// Create a listening socket bound to ip:port (port 0 picks an ephemeral port).
// Returns the fd, or -errno.
MOONBIT_FFI_EXPORT
int32_t
moonbit_co_net_listen(uint32_t ip_be, uint32_t port, int32_t backlog) {
  int fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (fd < 0) {
    return -errno;
  }
  int one = 1;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
  struct sockaddr_in addr;
  fill_v4(&addr, ip_be, port);
  if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
    int err = errno;
    close(fd);
    return -err;
  }
  if (listen(fd, backlog) < 0) {
    int err = errno;
    close(fd);
    return -err;
  }
  return fd;
}

// The port actually bound (useful when port 0 was requested).
MOONBIT_FFI_EXPORT
int32_t
moonbit_co_net_local_port(int32_t fd) {
  struct sockaddr_in addr;
  socklen_t len = sizeof(addr);
  if (getsockname(fd, (struct sockaddr *)&addr, &len) < 0) {
    return -errno;
  }
  return (int32_t)ntohs(addr.sin_port);
}

// A fresh unconnected stream socket. Returns the fd, or -errno.
MOONBIT_FFI_EXPORT
int32_t
moonbit_co_net_socket(void) {
  int fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (fd < 0) {
    return -errno;
  }
  return fd;
}

// Encode ip:port as a 16-byte `sockaddr_in` for the CONNECT operation. Owned by
// the caller; the backend retains it until the completion arrives.
MOONBIT_FFI_EXPORT
moonbit_bytes_t
moonbit_co_net_sockaddr_v4(uint32_t ip_be, uint32_t port) {
  moonbit_bytes_t bytes = moonbit_make_bytes(sizeof(struct sockaddr_in), 0);
  struct sockaddr_in addr;
  fill_v4(&addr, ip_be, port);
  memcpy(bytes, &addr, sizeof(addr));
  return bytes;
}

MOONBIT_FFI_EXPORT
void
moonbit_co_net_set_nodelay(int32_t fd) {
  int one = 1;
  setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
}

MOONBIT_FFI_EXPORT
void
moonbit_co_net_close(int32_t fd) {
  close(fd);
}

// Decode a peer sockaddr captured by accept into ip (host order) and port.
// Returns 1 for IPv4, 0 for anything else.
MOONBIT_FFI_EXPORT
int32_t
moonbit_co_net_decode_peer(
  moonbit_bytes_t peer,
  uint32_t *ip_out,
  uint32_t *port_out
) {
  struct sockaddr_in addr;
  uint32_t len = *(uint32_t *)(peer + 128);
  if (len > sizeof(addr)) {
    len = sizeof(addr);
  }
  memcpy(&addr, peer, len);
  if (addr.sin_family != AF_INET) {
    *ip_out = 0;
    *port_out = 0;
    return 0;
  }
  *ip_out = ntohl(addr.sin_addr.s_addr);
  *port_out = ntohs(addr.sin_port);
  return 1;
}
