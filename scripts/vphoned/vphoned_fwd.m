#import "vphoned_fwd.h"

#include <arpa/inet.h>
#include <netdb.h>
#include <netinet/in.h>
#include <pthread.h>
#include <sys/socket.h>
#include <unistd.h>

#ifndef AF_VSOCK
#define AF_VSOCK 40
#endif
#define VMADDR_CID_HOST 2

struct sockaddr_vm {
  __uint8_t svm_len;
  sa_family_t svm_family;
  __uint16_t svm_reserved1;
  __uint32_t svm_port;
  __uint32_t svm_cid;
};

static BOOL gStarted = NO;
static uint32_t gVsockPort = 1338;

static void *pipe_fds(void *arg) {
  int *fds = (int *)arg; // fds[0] -> fds[1]
  char buf[65536];
  for (;;) {
    ssize_t n = read(fds[0], buf, sizeof(buf));
    if (n <= 0)
      break;
    ssize_t off = 0;
    while (off < n) {
      ssize_t w = write(fds[1], buf + off, n - off);
      if (w <= 0)
        goto done;
      off += w;
    }
  }
done:
  shutdown(fds[0], SHUT_RDWR);
  shutdown(fds[1], SHUT_RDWR);
  return NULL;
}

/// Pipe both directions; frees the arg and closes both fds when done.
static void tunnel(int a, int b) {
  int *ab = malloc(sizeof(int) * 2);
  int *ba = malloc(sizeof(int) * 2);
  ab[0] = a;
  ab[1] = b;
  ba[0] = b;
  ba[1] = a;
  pthread_t t;
  pthread_create(&t, NULL, pipe_fds, ba);
  pipe_fds(ab);
  pthread_join(t, NULL);
  free(ab);
  free(ba);
  close(a);
  close(b);
}

static void *handle_client(void *arg) {
  int client = (int)(intptr_t)arg;

  int vs = socket(AF_VSOCK, SOCK_STREAM, 0);
  if (vs < 0) {
    close(client);
    return NULL;
  }
  struct sockaddr_vm addr = {0};
  addr.svm_len = sizeof(struct sockaddr_vm);
  addr.svm_family = AF_VSOCK;
  addr.svm_port = gVsockPort;
  addr.svm_cid = VMADDR_CID_HOST;
  if (connect(vs, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
    close(vs);
    close(client);
    return NULL;
  }
  tunnel(client, vs);
  return NULL;
}

static void *accept_loop(void *arg) {
  int listenFD = (int)(intptr_t)arg;
  for (;;) {
    int client = accept(listenFD, NULL, NULL);
    if (client < 0) {
      sleep(1);
      continue;
    }
    pthread_t t;
    pthread_create(&t, NULL, handle_client, (void *)(intptr_t)client);
    pthread_detach(t);
  }
  return NULL;
}

BOOL vp_forward_start(int tcpPort, uint32_t vsockPort) {
  static dispatch_once_t onceToken;
  __block BOOL ok = NO;
  dispatch_once(&onceToken, ^{
    gVsockPort = vsockPort;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0)
      return;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in addr = {
        .sin_family = AF_INET,
        .sin_addr.s_addr = htonl(INADDR_LOOPBACK),
        .sin_port = htons((uint16_t)tcpPort),
    };
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0 ||
        listen(fd, 16) < 0) {
      close(fd);
      return;
    }
    pthread_t t;
    pthread_create(&t, NULL, accept_loop, (void *)(intptr_t)fd);
    pthread_detach(t);
    ok = YES;
    gStarted = YES;
  });
  return ok || gStarted;
}
