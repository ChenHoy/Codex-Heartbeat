#include "HeartbeatSystem.h"
#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <stdlib.h>
#include <unistd.h>
#include <signal.h>
#include <spawn.h>
#include <errno.h>
extern char **environ;

uint64_t hb_process_stamp(pid_t pid) {
    struct proc_bsdinfo info = {0};
    if (pid <= 1 || proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)
        || info.pbi_uid != getuid() || info.pbi_status == 5) return 0;
    return info.pbi_start_tvsec * 1000000ULL + info.pbi_start_tvusec;
}
int hb_process_path(pid_t pid, char *buffer, int size) { return proc_pidpath(pid, buffer, size); }
int hb_owns_listener(pid_t pid, uint16_t port) {
    int bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
    if (bytes <= 0 || bytes > 16 * 1024 * 1024) return 0;
    struct proc_fdinfo *fds = calloc(1, bytes + 4096);
    if (!fds) return 0;
    bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds, bytes + 4096);
    int found = 0;
    for (int i = 0; i < bytes / (int)sizeof(*fds); i++) {
        if (fds[i].proc_fdtype != PROX_FDTYPE_SOCKET) continue;
        struct socket_fdinfo socket = {0};
        if (proc_pidfdinfo(pid, fds[i].proc_fd, PROC_PIDFDSOCKETINFO, &socket, sizeof(socket)) != sizeof(socket)) continue;
        struct socket_info *s = &socket.psi;
        struct tcp_sockinfo *tcp = &s->soi_proto.pri_tcp;
        if (s->soi_family == AF_INET && s->soi_kind == SOCKINFO_TCP && tcp->tcpsi_state == TSI_S_LISTEN
            && ntohs((uint16_t)tcp->tcpsi_ini.insi_lport) == port
            && tcp->tcpsi_ini.insi_laddr.ina_46.i46a_addr4.s_addr == htonl(INADDR_LOOPBACK)) found = 1;
    }
    free(fds);
    return found;
}
int hb_free_port(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_in addr = {.sin_len = sizeof(addr), .sin_family = AF_INET, .sin_port = 0};
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    socklen_t size = sizeof(addr);
    int port = -1;
    if (bind(fd, (struct sockaddr *)&addr, size) == 0 && getsockname(fd, (struct sockaddr *)&addr, &size) == 0)
        port = ntohs(addr.sin_port);
    close(fd);
    return port;
}
static volatile sig_atomic_t received = 0;
static void capture_signal(int value) { received = value; }
void hb_install_signals(void) {
    signal(SIGTERM, capture_signal); signal(SIGHUP, capture_signal);
    // Ctrl-C belongs to the interactive TUI; it must not tear down its server.
    signal(SIGINT, SIG_IGN); signal(SIGPIPE, SIG_IGN);
}
int hb_received_signal(void) { return received; }
pid_t hb_spawn_terminal(const char *path, char *const argv[]) {
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    sigset_t defaults, mask;
    sigemptyset(&defaults); sigemptyset(&mask);
    sigaddset(&defaults, SIGINT); sigaddset(&defaults, SIGTERM); sigaddset(&defaults, SIGHUP); sigaddset(&defaults, SIGPIPE);
    posix_spawnattr_setsigdefault(&attr, &defaults);
    posix_spawnattr_setsigmask(&attr, &mask);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK);
    pid_t pid = 0;
    int error = posix_spawn(&pid, path, NULL, &attr, argv, environ);
    posix_spawnattr_destroy(&attr);
    if (error) { errno = error; return -1; }
    return pid;
}
int hb_poll_child(pid_t pid, int *exit_code) {
    int status = 0;
    pid_t result = waitpid(pid, &status, WNOHANG);
    if (result == 0 || (result < 0 && errno == EINTR)) return 0;
    if (result < 0) { *exit_code = 1; return 1; }
    *exit_code = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
    return 1;
}
