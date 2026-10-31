// Baselines for the `co` filesystem benchmark: the same three workloads driven
// with plain blocking syscalls, so the io_uring path has something honest to be
// compared against.
//
//   cc -O2 -pthread -o baseline baseline.c
//
//   baseline seq   <path> <block> <mib>
//   baseline pread1 <path> <block> <ops> <file_mib>
//   baseline preadT <path> <block> <threads> <ops> <file_mib>
//
// Each mode prints the same shape as `fs_bench` (throughput, us/op, p50/p99),
// plus the process CPU time, so both numbers can be read the same way.

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>

#define NS_PER_S 1000000000LL
#define MIB 1048576LL

typedef struct {
  int fd;
  int block;
  int ops;
  int blocks;
  int64_t *latency;
  int64_t ok;
  uint64_t state;
} worker_arg;

static int64_t
now_ns(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (int64_t)ts.tv_sec * NS_PER_S + ts.tv_nsec;
}

static double
cpu_seconds(void) {
  struct rusage ru;
  getrusage(RUSAGE_SELF, &ru);
  return (double)ru.ru_utime.tv_sec + (double)ru.ru_utime.tv_usec / 1e6 +
         (double)ru.ru_stime.tv_sec + (double)ru.ru_stime.tv_usec / 1e6;
}

static int
cmp_i64(const void *a, const void *b) {
  int64_t x = *(const int64_t *)a, y = *(const int64_t *)b;
  return x < y ? -1 : x > y;
}

static int64_t
pct(const int64_t *sorted, int n, int p) {
  if (n <= 0) {
    return 0;
  }
  return sorted[(int64_t)(n - 1) * p / 100];
}

static void *
pread_worker(void *raw) {
  worker_arg *w = raw;
  char *buf = malloc((size_t)w->block);
  w->state = 0x2545F4914F6CDD1DULL + (uint64_t)(uintptr_t)raw;
  for (int i = 0; i < w->ops; i++) {
    w->state ^= w->state >> 12;
    w->state ^= w->state << 25;
    w->state ^= w->state >> 27;
    int block_index =
        (int)(((w->state * 2685821657736338717ULL) >> 32) % (uint64_t)w->blocks);
    off_t pos = (off_t)block_index * w->block;
    int64_t t0 = now_ns();
    ssize_t n = pread(w->fd, buf, (size_t)w->block, pos);
    w->latency[i] = now_ns() - t0;
    if (n <= 0) {
      break;
    }
    w->ok++;
  }
  free(buf);
  return NULL;
}

static void
report(const char *label, int64_t ops, int64_t bytes, int64_t ns,
       int64_t *latency, int n, double cpu0) {
  qsort(latency, (size_t)n, sizeof(int64_t), cmp_i64);
  double cpu = cpu_seconds() - cpu0;
  printf("%s: %.0f IOPS  %.2f us/op  %.1f MiB/s  p50=%.1f p99=%.1f max=%.1f us  "
         "cpu=%.0f%%  %.0f ns CPU/op\n",
         label, (double)ops / ((double)ns / 1e9),
         (double)ns / (double)ops / 1000.0,
         (double)bytes / (double)MIB / ((double)ns / 1e9),
         (double)pct(latency, n, 50) / 1000.0,
         (double)pct(latency, n, 99) / 1000.0,
         (double)latency[n - 1] / 1000.0, cpu / ((double)ns / 1e9) * 100.0,
         cpu * 1e9 / (double)ops);
}

int
main(int argc, char **argv) {
  if (argc < 2) {
    fprintf(stderr, "usage: baseline <seq|pread1|preadT> ...\n");
    return 2;
  }
  if (!strcmp(argv[1], "seq")) {
    const char *path = argv[2];
    int block = atoi(argv[3]);
    int mib = atoi(argv[4]);
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
      perror("open");
      return 1;
    }
    char *buf = malloc((size_t)block);
    int64_t blocks = (int64_t)mib * MIB / block;
    double cpu0 = cpu_seconds();
    int64_t t0 = now_ns(), bytes = 0;
    for (int64_t i = 0; i < blocks; i++) {
      ssize_t n = pread(fd, buf, (size_t)block, (off_t)(i * block));
      if (n <= 0) {
        break;
      }
      bytes += n;
    }
    int64_t ns = now_ns() - t0;
    int64_t *lat = malloc(sizeof(int64_t));
    lat[0] = ns / blocks;
    report("seq", blocks, bytes, ns, lat, 1, cpu0);
    free(lat);
    free(buf);
    close(fd);
    return 0;
  }

  int threaded = !strcmp(argv[1], "preadT");
  const char *path = argv[2];
  int block = atoi(argv[3]);
  int threads = threaded ? atoi(argv[4]) : 1;
  int ops = atoi(argv[threaded ? 5 : 4]);
  int file_mib = atoi(argv[threaded ? 6 : 5]);
  int blocks = (int)((int64_t)file_mib * MIB / block);
  int per = ops / threads;
  int evict = argc > 0 && !strcmp(argv[argc - 1], "evict");

  worker_arg *args = calloc((size_t)threads, sizeof(worker_arg));
  pthread_t *tids = calloc((size_t)threads, sizeof(pthread_t));
  for (int i = 0; i < threads; i++) {
    args[i].fd = open(path, O_RDONLY);
    if (args[i].fd < 0) {
      perror("open");
      return 1;
    }
    args[i].block = block;
    args[i].ops = per;
    args[i].blocks = blocks;
    args[i].latency = malloc(sizeof(int64_t) * (size_t)per);
  }

  if (evict) {
    for (int i = 0; i < threads; i++) {
      posix_fadvise(args[i].fd, 0, 0, POSIX_FADV_DONTNEED);
    }
  }
  double cpu0 = cpu_seconds();
  int64_t t0 = now_ns();
  for (int i = 0; i < threads; i++) {
    if (threaded) {
      pthread_create(&tids[i], NULL, pread_worker, &args[i]);
    } else {
      pread_worker(&args[i]);
    }
  }
  for (int i = 0; i < threads; i++) {
    if (threaded) {
      pthread_join(tids[i], NULL);
    }
  }
  int64_t ns = now_ns() - t0;

  int64_t total = 0;
  int64_t *latency = malloc(sizeof(int64_t) * (size_t)per * (size_t)threads);
  for (int i = 0; i < threads; i++) {
    memcpy(
        latency + total, args[i].latency, sizeof(int64_t) * (size_t)args[i].ok);
    total += args[i].ok;
  }
  char label[64];
  snprintf(label, sizeof(label), "%s block=%d qd=%d",
           threaded ? "preadT" : "pread1", block, threads);
  report(label, total, total * block, ns, latency, (int)total, cpu0);

  for (int i = 0; i < threads; i++) {
    close(args[i].fd);
    free(args[i].latency);
  }
  free(latency);
  free(args);
  free(tids);
  return 0;
}
