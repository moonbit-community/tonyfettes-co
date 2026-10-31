// Minimal epoll echo load generator: request-response or bulk stream.
//   echo_bench <port> <conns> <msg_size> <total_round_trips> [rr|stream] [bytes_per_conn]
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

static double now(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec + ts.tv_nsec / 1e9;
}

typedef struct {
  int fd;
  char *buf;
  size_t sent, got, target;
  double t0;
  int in_flight;
  int done;
} conn_t;

static int cmp_double(const void *a, const void *b) {
  double x = *(const double *)a, y = *(const double *)b;
  return x < y ? -1 : x > y;
}

int main(int argc, char **argv) {
  if (argc < 5) {
    fprintf(stderr, "usage: %s port conns msg_size rr_count [rr|stream] [bytes]\n", argv[0]);
    return 2;
  }
  int port = atoi(argv[1]);
  int nconn = atoi(argv[2]);
  size_t msgsz = (size_t)atol(argv[3]);
  long rrcount = atol(argv[4]);
  int stream = argc > 5 && strcmp(argv[5], "stream") == 0;
  int pipelined = argc > 5 && strcmp(argv[5], "pipe") == 0;
  int window = argc > 7 ? atoi(argv[7]) : 1;
  long long budget = argc > 6 ? atoll(argv[6]) : 0;

  int ep = epoll_create1(0);
  conn_t *cs = calloc(nconn, sizeof(conn_t));
  double *lat = malloc(sizeof(double) * (stream ? 1 : rrcount));
  char *payload = malloc(msgsz);
  memset(payload, 'x', msgsz);
  char *rx = malloc(msgsz * 2);

  for (int i = 0; i < nconn; i++) {
    int fd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0);
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    struct sockaddr_in a;
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_port = htons(port);
    a.sin_addr.s_addr = htonl(0x7F000001);
    connect(fd, (struct sockaddr *)&a, sizeof(a));
    cs[i].fd = fd;
    cs[i].buf = rx;
    struct epoll_event ev = { .events = EPOLLOUT | EPOLLIN, .data.u32 = (uint32_t)i };
    epoll_ctl(ep, EPOLL_CTL_ADD, fd, &ev);
  }

  long long rr_done = 0, bytes_done = 0;
  int active = nconn;
  double t_start = now();
  struct epoll_event evs[256];
  while (active > 0) {
    int n = epoll_wait(ep, evs, 256, 1000);
    for (int k = 0; k < n; k++) {
      conn_t *c = &cs[evs[k].data.u32];
      if (c->done) continue;
      if (evs[k].events & (EPOLLOUT | EPOLLIN)) {
        if (pipelined) {
          // Fill the window first, then keep it full.
          for (;;) {
            if (c->in_flight >= window) break;
            ssize_t w = write(c->fd, payload, msgsz);
            if (w != (ssize_t)msgsz) break;
            c->in_flight++;
            if (c->in_flight == 1) c->t0 = now();
          }
          ssize_t r = read(c->fd, c->buf, msgsz);
          if (r == (ssize_t)msgsz) {
            double dt = now() - c->t0;
            if (rr_done < rrcount) lat[rr_done] = dt;
            rr_done++;
            c->in_flight--;
            c->t0 = now();
            if (rr_done >= rrcount) {
              for (int j = 0; j < nconn; j++) cs[j].done = 1;
              active = 0;
              goto finished;
            }
          } else if (r == 0) {
            c->done = 1; active--;
          }
          continue;
        }
        // try to complete a pending exchange
        ssize_t r = read(c->fd, c->buf + c->got, msgsz - c->got);
        if (r > 0) {
          c->got += (size_t)r;
          if (c->got == msgsz) {
            double dt = now() - c->t0;
            if (stream) {
              bytes_done += (long long)msgsz;
              if (budget && bytes_done >= budget) {
                for (int j = 0; j < nconn; j++) cs[j].done = 1;
                active = 0;
                goto finished;
              }
            } else {
              if (rr_done < rrcount) lat[rr_done] = dt;
              rr_done++;
              if (rr_done >= rrcount || (budget && rr_done >= budget)) {
                for (int j = 0; j < nconn; j++) cs[j].done = 1;
                active = 0;
                goto finished;
              }
            }
            c->got = 0;
            c->in_flight = 0;
          }
        } else if (r == 0) {
          c->done = 1; active--; continue;
        } else if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINPROGRESS) {
          c->done = 1; active--; continue;
        }
        if (!c->in_flight) {
          ssize_t w = write(c->fd, payload, msgsz);
          if (w == (ssize_t)msgsz) {
            c->in_flight = 1;
            c->t0 = now();
          }
        }
      }
    }
  }
finished:
  double dt = now() - t_start;
  long long n = stream ? (bytes_done / (long long)msgsz) : rr_done;
  printf("conns=%d msgsz=%zu mode=%s  exchanges=%lld in %.3fs -> %.0f rt/s\n",
         nconn, msgsz, stream ? "stream" : "rr", n, dt, n / dt);
  if (!stream) {
    qsort(lat, (size_t)(n < rrcount ? n : rrcount), sizeof(double), cmp_double);
    size_t m = (size_t)(n < rrcount ? n : rrcount);
    if (m) {
      printf("  latency us: p50=%.1f p90=%.1f p99=%.1f p999=%.1f max=%.1f\n",
             lat[m / 2] * 1e6, lat[(size_t)(m * 0.9)] * 1e6, lat[(size_t)(m * 0.99)] * 1e6,
             lat[(size_t)(m * 0.999)] * 1e6, lat[m - 1] * 1e6);
    }
  } else {
    printf("  payload %.1f MB/s one-way, %.1f MB/s on the wire\n",
           bytes_done / dt / 1e6, 2.0 * bytes_done / dt / 1e6);
  }
  return 0;
}
