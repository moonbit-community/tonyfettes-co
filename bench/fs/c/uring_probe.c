// Attribution probe for the filesystem benchmark: run the exact same 4 KiB read
// three ways, with no MoonBit and no coroutines involved, so the gap between
// `co` and `pread` can be split into "kernel path" and "framework".
//
//   cc -O2 -o uring_probe uring_probe.c
//   uring_probe <path> <block> <iters> <pread|uring|syscall>
//
//   pread   - one pread(2) per read (what the C baseline does)
//   uring   - raw io_uring: fill one SQE, one io_uring_enter(submit=1,
//             wait>=1), reap the CQE. This is what co does minus the framework.
//   syscall - open/close the same file every iteration, to price the syscall
//             round trip itself (a floor for anything that enters the kernel).

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

#include <linux/io_uring.h>

#define NS_PER_S 1000000000LL

static int64_t
now_ns(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (int64_t)ts.tv_sec * NS_PER_S + ts.tv_nsec;
}

struct ring {
  int fd;
  unsigned *sq_head, *sq_tail, *sq_ring_mask, *sq_ring_entries, *sq_flags;
  unsigned *sq_array;
  struct io_uring_sqe *sqes;
  unsigned *cq_head, *cq_tail, *cq_ring_mask;
  struct io_uring_cqe *cqes;
  unsigned *cq_overflow;
  struct io_uring_sqe *sqe;
};

static void
ring_init(struct ring *r, unsigned entries) {
  struct io_uring_params p;
  memset(&p, 0, sizeof(p));
  r->fd = (int)syscall(SYS_io_uring_setup, entries, &p);
  if (r->fd < 0) {
    perror("io_uring_setup");
    exit(1);
  }
  size_t sq_sz = p.sq_off.array + p.sq_entries * sizeof(unsigned);
  size_t cq_sz = p.cq_off.cqes + p.cq_entries * sizeof(struct io_uring_cqe);
  if (p.features & IORING_FEAT_SINGLE_MMAP) {
    if (cq_sz > sq_sz) {
      sq_sz = cq_sz;
    }
    cq_sz = sq_sz;
  }
  void *sq = mmap(NULL, sq_sz, PROT_READ | PROT_WRITE,
                  MAP_SHARED | MAP_POPULATE, r->fd, IORING_OFF_SQ_RING);
  void *cq = sq;
  if (!(p.features & IORING_FEAT_SINGLE_MMAP)) {
    cq = mmap(NULL, cq_sz, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE,
              r->fd, IORING_OFF_CQ_RING);
  }
  r->sqes = mmap(NULL, p.sq_entries * sizeof(struct io_uring_sqe),
                 PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE, r->fd,
                 IORING_OFF_SQES);
  r->sq_head = sq + p.sq_off.head;
  r->sq_tail = sq + p.sq_off.tail;
  r->sq_ring_mask = sq + p.sq_off.ring_mask;
  r->sq_ring_entries = sq + p.sq_off.ring_entries;
  r->sq_flags = sq + p.sq_off.flags;
  r->sq_array = sq + p.sq_off.array;
  r->cq_head = cq + p.cq_off.head;
  r->cq_tail = cq + p.cq_off.tail;
  r->cq_ring_mask = cq + p.cq_off.ring_mask;
  r->cqes = cq + p.cq_off.cqes;
  r->cq_overflow = cq + p.cq_off.overflow;
}

int
main(int argc, char **argv) {
  if (argc < 3) {
    fprintf(stderr, "usage: uring_probe <path> <block> <iters> <pread|uring>\n");
    return 2;
  }
  const char *path = argv[1];
  int block = atoi(argv[2]);
  int iters = argc > 3 ? atoi(argv[3]) : 200000;
  const char *mode = argc > 4 ? argv[4] : "pread";
  int batch = argc > 5 ? atoi(argv[5]) : 1;

  int fd = open(path, O_RDONLY);
  if (fd < 0) {
    perror("open");
    return 1;
  }
  char *buf = malloc((size_t)block);
  memset(buf, 0, (size_t)block);

  // Warm the page cache for the first block so we measure the hot path.
  if (pread(fd, buf, (size_t)block, 0) <= 0) {
    perror("pread warm");
    return 1;
  }

  if (!strcmp(mode, "pread")) {
    int64_t t0 = now_ns();
    for (int i = 0; i < iters; i++) {
      if (pread(fd, buf, (size_t)block, 0) <= 0) {
        perror("pread");
        break;
      }
    }
    int64_t ns = now_ns() - t0;
    printf("pread  4 KiB hot: %.0f ns/op  %.0f IOPS\n", (double)ns / iters,
           (double)iters / ((double)ns / 1e9));
    return 0;
  }

  if (!strcmp(mode, "uring")) {
    struct ring r;
    ring_init(&r, 64);
    int64_t t0 = now_ns();
    for (int i = 0; i < iters; i += batch) {
      for (int b = 0; b < batch; b++) {
      // Fill one SQE: read `block` bytes at offset 0 (same as the pread loop).
      unsigned tail = *r.sq_tail;
      unsigned index = tail & *r.sq_ring_mask;
      struct io_uring_sqe *sqe = &r.sqes[index];
      memset(sqe, 0, sizeof(*sqe));
      sqe->opcode = IORING_OP_READ;
      sqe->fd = fd;
      sqe->addr = (uint64_t)(uintptr_t)buf;
      sqe->len = (uint32_t)block;
      sqe->off = 0;
      sqe->user_data = (uint64_t)i;
      r.sq_array[index] = index;
      *r.sq_tail = tail + 1;
      }

      if (syscall(SYS_io_uring_enter, r.fd, batch, batch, IORING_ENTER_GETEVENTS,
                  NULL, 0) < 0) {
        perror("io_uring_enter");
        break;
      }
      unsigned head = *r.cq_head;
      int reaped = 0;
      while (reaped < batch) {
        head = *r.cq_head;
        while (head == *r.cq_tail) {
          syscall(SYS_io_uring_enter, r.fd, 0, batch - reaped,
                  IORING_ENTER_GETEVENTS, NULL, 0);
          head = *r.cq_head;
        }
        while (head != *r.cq_tail && reaped < batch) {
          struct io_uring_cqe *cqe = &r.cqes[head & *r.cq_ring_mask];
          if (cqe->res < 0) {
            fprintf(stderr, "cqe error %d\n", cqe->res);
            return 1;
          }
          head++;
          reaped++;
        }
        *r.cq_head = head;
      }
      *r.sq_head = *r.sq_tail;
    }
    int64_t ns = now_ns() - t0;
    printf("io_uring batch=%d: %.0f ns/op  %.0f IOPS\n", batch, (double)ns / iters,
           (double)iters / ((double)ns / 1e9));
    return 0;
  }

  fprintf(stderr, "unknown mode %s\n", mode);
  return 2;
}
