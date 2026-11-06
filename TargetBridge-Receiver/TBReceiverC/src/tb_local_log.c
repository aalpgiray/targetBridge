/* tb_local_log.c — keep a copy of the receiver's stderr on disk.
 *
 * stderr is the receiver's diagnostic stream. A launch that goes through
 * `open -a` does not leave that stream anywhere a later failure can be
 * read. This copies it to ~/Library/Logs/TargetBridge/receiver-local.log
 * without taking the bytes off the original stderr.
 *
 * The write end is non-blocking so a full pipe cannot stall the render
 * loop. Lines that do not fit are dropped. */

#include "tb_local_log.h"

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define TB_LOCAL_LOG_LIMIT (16 * 1024 * 1024)

static int g_local_fd = -1;
static int g_saved_stderr = -1;
static int g_pipe_r = -1;
static int g_started = 0;

static void write_all(int fd, const char *buf, size_t n) {
    size_t off = 0;
    while (off < n) {
        ssize_t w = write(fd, buf + off, n - off);
        if (w < 0 && errno == EINTR) continue;
        if (w <= 0) return;
        off += (size_t)w;
    }
}

static void *copy_main(void *unused) {
    (void)unused;
    char buf[4096];
    for (;;) {
        ssize_t n = read(g_pipe_r, buf, sizeof buf);
        if (n > 0) {
            write_all(g_saved_stderr, buf, (size_t)n);
            if (g_local_fd >= 0) write_all(g_local_fd, buf, (size_t)n);
            continue;
        }
        if (n < 0 && errno == EINTR) continue;
        break;
    }
    return NULL;
}

static int open_log_file(void) {
    const char *home = getenv("HOME");
    if (!home || !*home) return -1;

    char dir[512];
    char path[600];
    snprintf(dir, sizeof dir, "%s/Library/Logs/TargetBridge", home);
    if (mkdir(dir, 0755) != 0 && errno != EEXIST) return -1;
    snprintf(path, sizeof path, "%s/receiver-local.log", dir);

    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return -1;

    struct stat st;
    if (fstat(fd, &st) == 0 && st.st_size > TB_LOCAL_LOG_LIMIT) {
        close(fd);
        fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd < 0) return -1;
    }

    const char *banner = "\n=== receiver started ===\n";
    write_all(fd, banner, strlen(banner));
    return fd;
}

void tb_local_log_start(void) {
    if (g_started) return;
    g_started = 1;

    int fd = open_log_file();
    if (fd < 0) return;

    int fds[2];
    if (pipe(fds) != 0) {
        close(fd);
        return;
    }
    int flags = fcntl(fds[1], F_GETFL, 0);
    int saved = dup(STDERR_FILENO);
    if (flags < 0 || fcntl(fds[1], F_SETFL, flags | O_NONBLOCK) != 0 ||
        saved < 0 || dup2(fds[1], STDERR_FILENO) < 0) {
        if (saved >= 0) close(saved);
        close(fds[0]);
        close(fds[1]);
        close(fd);
        return;
    }
    close(fds[1]);
    g_local_fd = fd;
    g_saved_stderr = saved;
    g_pipe_r = fds[0];
    setvbuf(stderr, NULL, _IONBF, 0);

    pthread_t thread;
    if (pthread_create(&thread, NULL, copy_main, NULL) != 0) {
        dup2(saved, STDERR_FILENO);
        close(saved);
        close(fds[0]);
        close(fd);
        g_local_fd = g_saved_stderr = g_pipe_r = -1;
        return;
    }
    pthread_detach(thread);
}
