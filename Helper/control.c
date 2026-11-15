/* Local, per-user network control service. No arbitrary commands or paths.
 * Build: clang -std=c11 -Wall -Wextra -O2 control.c -o control
 * Security boundary: installing UID (not code-signing identity).
 */
#define _GNU_SOURCE
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <sys/select.h>
#include <sys/wait.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <errno.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#ifdef __APPLE__
#include <libproc.h>
#endif

#define PROTOCOL "1"
#define MAX_REQUEST 128
#define MAX_REPLY 4096
static volatile sig_atomic_t stopping;
static void terminate_service(int sig) { (void)sig; stopping = 1; }

static int number(const char *s, unsigned long *out) {
    if (!s || !*s) return 0;
    for (const char *p = s; *p; p++) if (*p < '0' || *p > '9') return 0;
    errno = 0;
    unsigned long n = strtoul(s, NULL, 10);
    if (errno || n <= 1 || n > INT_MAX) return 0;
    *out = n;
    return 1;
}

enum action { INVALID, STATUS, STOP, FULL, PROXY };
struct request { enum action action; pid_t pid; char ip[INET_ADDRSTRLEN]; };

static struct request parse(char *line) {
    struct request r = { INVALID, 0, "" };
    char *words[5], *save = NULL;
    int count = 0;
    for (char *p = strtok_r(line, " ", &save); p; p = strtok_r(NULL, " ", &save)) {
        if (count == 5) return r;
        words[count++] = p;
    }
    if (count == 1 && !strcmp(words[0], "status")) r.action = STATUS;
    if (count == 1 && !strcmp(words[0], "stop")) r.action = STOP;
    unsigned long pid;
    if (count == 2 && !strcmp(words[0], "start-proxy") && number(words[1], &pid)) {
        r.action = PROXY; r.pid = (pid_t)pid;
    }
    struct in_addr ip;
    if (count == 3 && !strcmp(words[0], "start-full") && number(words[1], &pid)
        && inet_pton(AF_INET, words[2], &ip) == 1) {
        r.action = FULL; r.pid = (pid_t)pid;
        snprintf(r.ip, sizeof(r.ip), "%s", words[2]);
    }
    return r;
}

static int peer_uid(int fd, uid_t *uid) {
#ifdef __APPLE__
    gid_t gid;
    return getpeereid(fd, uid, &gid);
#else
    struct ucred cred; socklen_t len = sizeof(cred);
    int rc = getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cred, &len);
    if (!rc) *uid = cred.uid;
    return rc;
#endif
}

/* PID plus start time prevents considering a reused PID the original app. */
static uint64_t process_identity(pid_t pid, uid_t uid) {
#ifdef __APPLE__
    struct proc_bsdinfo info;
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != (int)sizeof(info)
        || info.pbi_uid != uid) return 0;
    return info.pbi_start_tvsec * 1000000ULL + info.pbi_start_tvusec;
#else
    char path[64]; struct stat st;
    /* Linux-only test fallback; /proc may expose host rather than container PIDs. */
    if (pid == getpid()) snprintf(path, sizeof(path), "/proc/self");
    else snprintf(path, sizeof(path), "/proc/%ld", (long)pid);
    if (stat(path, &st) || st.st_uid != uid) return 0;
    return (uint64_t)st.st_ino;
#endif
}

static void socket_timeout(int fd, int seconds) {
    struct timeval tv = { seconds, 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    fcntl(fd, F_SETFD, FD_CLOEXEC);
}

static int send_all(int fd, const char *s, size_t n) {
    while (n) {
        ssize_t k = send(fd, s, n, 0);
        if (k < 0 && errno == EINTR) continue;
        if (k <= 0) return -1;
        s += k; n -= (size_t)k;
    }
    return 0;
}

static int read_request(int fd, char *line) {
    size_t n = 0;
    time_t deadline = time(NULL) + 3;
    while (n < MAX_REQUEST - 1) {
        if (time(NULL) >= deadline) return -1;
        unsigned char c;
        if (recv(fd, &c, 1, 0) != 1) return -1;
        if (c == '\n') { line[n] = 0; return 0; }
        if (c < 32 || c > 126) return -1;
        line[n++] = (char)c;
    }
    return -1;
}

static void socket_address(struct sockaddr_un *sa, uid_t uid) {
    memset(sa, 0, sizeof(*sa)); sa->sun_family = AF_UNIX;
    snprintf(sa->sun_path, sizeof(sa->sun_path), "/var/run/mojaveray-control-%u.sock", uid);
#ifdef __APPLE__
    sa->sun_len = sizeof(*sa);
#endif
}

static int protected_file(const char *path, int directory) {
    struct stat st;
    return lstat(path, &st) == 0 && st.st_uid == 0 && !(st.st_mode & 0022)
        && (directory ? S_ISDIR(st.st_mode) : S_ISREG(st.st_mode));
}

/* Fixed root-owned script, argv (never sh -c), minimal environment.
 * Bound runtime and drain output while waiting to avoid pipe deadlocks.
 */
static int run_action(const char *base, uid_t uid, struct request r, char *output) {
    char script[PATH_MAX], uid_s[24], pid_s[24];
    snprintf(script, sizeof(script), "%s/network.sh", base);
    snprintf(uid_s, sizeof(uid_s), "%u", uid);
    snprintf(pid_s, sizeof(pid_s), "%ld", (long)r.pid);
    if (!protected_file(base, 1) || !protected_file(script, 0)) {
        snprintf(output, MAX_REPLY, "Unsafe helper installation"); return -1;
    }
    if (r.action == FULL) {
        char tun[PATH_MAX]; snprintf(tun, sizeof(tun), "%s/tun2socks", base);
        if (!protected_file(tun, 0)) {
            snprintf(output, MAX_REPLY, "Unsafe tun2socks installation"); return -1;
        }
    }
    char *argv[] = { "/bin/bash", script, "stop", uid_s, NULL, NULL, NULL };
    if (r.action == FULL) {
        argv[2] = "service-start-full"; argv[4] = pid_s; argv[5] = r.ip;
    } else if (r.action == PROXY) {
        argv[2] = "start-proxy"; argv[4] = pid_s;
    }
    char *env[] = { "PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL=C",
                    "LANG=C", "MOJAVERAY_SERVICE=1", NULL };
    int pipes[2];
    if (pipe(pipes)) return -1;
    fcntl(pipes[0], F_SETFD, FD_CLOEXEC);
    fcntl(pipes[1], F_SETFD, FD_CLOEXEC);
    pid_t child = fork();
    if (child == 0) {
        setpgid(0, 0);
        int input = open("/dev/null", O_RDONLY);
        if (input < 0) _exit(126);
        dup2(input, STDIN_FILENO); close(input);
        dup2(pipes[1], STDOUT_FILENO); dup2(pipes[1], STDERR_FILENO);
        close(pipes[0]); close(pipes[1]);
        execve("/bin/bash", argv, env); _exit(127);
    }
    close(pipes[1]);
    if (child < 0) { close(pipes[0]); return -1; }
    setpgid(child, child);
    fcntl(pipes[0], F_SETFL, O_NONBLOCK);
    size_t used = 0; int status = 0, finished = 0, timed_out = 0;
    time_t deadline = time(NULL) + 60;
    for (;;) {
        char chunk[1024]; ssize_t n;
        while ((n = read(pipes[0], chunk, sizeof(chunk))) > 0) {
            size_t take = (size_t)n;
            if (take > MAX_REPLY - 1 - used) take = MAX_REPLY - 1 - used;
            memcpy(output + used, chunk, take); used += take;
        }
        if (finished) break;
        pid_t w = waitpid(child, &status, WNOHANG);
        if (w == child || (w < 0 && errno != EINTR)) { finished = 1; continue; }
        if (time(NULL) >= deadline) {
            kill(-child, SIGKILL); waitpid(child, &status, 0); timed_out = 1; break;
        }
        struct timeval tv = { 0, 100000 };
        select(0, NULL, NULL, NULL, &tv);
    }
    output[used] = 0; close(pipes[0]);
    if (timed_out) snprintf(output, MAX_REPLY, "Network helper timed out; recovery requested");
    return !timed_out && WIFEXITED(status) && WEXITSTATUS(status) == 0 ? 0 : -1;
}

static int client(uid_t uid, int argc, char **argv) {
    struct sockaddr_un sa; socket_address(&sa, uid);
    char request[MAX_REQUEST] = "";
    size_t used = 0;
    for (int i = 0; i < argc; i++) {
        size_t n = strlen(argv[i]);
        if (used + n + 2 >= sizeof(request)) return 2;
        if (i) request[used++] = ' ';
        memcpy(request + used, argv[i], n); used += n;
    }
    char copy[MAX_REQUEST]; strcpy(copy, request);
    if (parse(copy).action == INVALID) return 2;
    request[used++] = '\n';
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return 3;
    socket_timeout(fd, 90);
    if (connect(fd, (struct sockaddr *)&sa, sizeof(sa))) {
        fprintf(stderr, "Системный помощник недоступен: %s\n", strerror(errno)); close(fd); return 3;
    }
    uid_t peer;
    if (peer_uid(fd, &peer) || peer != 0) { close(fd); return 4; }
    if (send_all(fd, request, used)) { close(fd); return 3; }
    shutdown(fd, SHUT_WR);
    char reply[MAX_REPLY + 32]; size_t n = 0;
    for (;;) {
        ssize_t got = recv(fd, reply + n, sizeof(reply) - 1 - n, 0);
        if (got < 0 && errno == EINTR) continue;
        if (got < 0) { close(fd); return 3; }
        if (!got) break;
        n += (size_t)got;
        if (n >= sizeof(reply) - 1) { close(fd); return 3; }
    }
    reply[n] = 0; close(fd);
    fputs(reply, stdout);
    return strncmp(reply, "OK ", 3) == 0 ? 0 : 1;
}

static int server(uid_t uid) {
    if (geteuid() != 0) return 2;
    char base[PATH_MAX], state[PATH_MAX], output[MAX_REPLY] = "";
    snprintf(base, sizeof(base), "/Library/PrivilegedHelperTools/com.denisbekker.MojaveRay.%u", uid);
    snprintf(state, sizeof(state), "/var/run/mojaveray-%u/mode", uid);
    if (!protected_file(base, 1)) return 2;
    struct request stop = { STOP, 0, "" };
    /* After a crash/restart, never keep routes pointing into an orphan tunnel. */
    if (run_action(base, uid, stop, output)) return 2;
    struct sockaddr_un sa; socket_address(&sa, uid);
    struct stat existing;
    if (!lstat(sa.sun_path, &existing)) {
        if (!S_ISSOCK(existing.st_mode) || existing.st_uid != uid) return 2;
        if (unlink(sa.sun_path)) return 2;
    } else if (errno != ENOENT) return 2;
    int listener = socket(AF_UNIX, SOCK_STREAM, 0);
    if (listener < 0) return 2;
    fcntl(listener, F_SETFD, FD_CLOEXEC);
    umask(0077);
    if (bind(listener, (struct sockaddr *)&sa, sizeof(sa)) || chmod(sa.sun_path, 0600)
        || chown(sa.sun_path, uid, (gid_t)-1) || listen(listener, 4)) {
        close(listener); return 2;
    }
    pid_t owner = 0; uint64_t identity = 0;
    while (!stopping) {
        if (owner && process_identity(owner, uid) != identity) {
            run_action(base, uid, stop, output); owner = 0;
        }
        fd_set set; FD_ZERO(&set); FD_SET(listener, &set);
        struct timeval tv = { 1, 0 };
        if (select(listener + 1, &set, NULL, NULL, &tv) <= 0) continue;
        int fd = accept(listener, NULL, NULL);
        if (fd < 0) continue;
        socket_timeout(fd, 3);
        uid_t peer = (uid_t)-1;
        char line[MAX_REQUEST], reply[MAX_REPLY + 32];
        struct request r = { INVALID, 0, "" };
        if (!peer_uid(fd, &peer) && (peer == uid || peer == 0) && !read_request(fd, line)) r = parse(line);
        if (r.action == INVALID) snprintf(reply, sizeof(reply), "ERR Invalid or unauthorized request\n");
        else if (r.action == STATUS) snprintf(reply, sizeof(reply), "OK " PROTOCOL " %s\n", access(state, F_OK) == 0 ? "active" : "idle");
        else if ((r.action == FULL || r.action == PROXY) &&
                 (peer != uid || !process_identity(r.pid, uid))) {
            snprintf(reply, sizeof(reply), "ERR Invalid application owner\n");
        } else {
            uint64_t next_identity = r.action == STOP ? 0 : process_identity(r.pid, uid);
            output[0] = 0;
            if (!run_action(base, uid, r, output)) {
                owner = r.action == STOP ? 0 : r.pid; identity = next_identity;
                snprintf(reply, sizeof(reply), "OK %s\n", output);
            } else {
                snprintf(reply, sizeof(reply), "ERR %s\n", output);
                char recovery[MAX_REPLY]; run_action(base, uid, stop, recovery); owner = 0;
            }
        }
        send_all(fd, reply, strlen(reply)); close(fd);
    }
    run_action(base, uid, stop, output);
    close(listener); unlink(sa.sun_path); return 0;
}

#ifndef CONTROL_TEST
int main(int argc, char **argv) {
    signal(SIGPIPE, SIG_IGN);
    unsigned long uid;
    if (argc < 3 || !number(argv[2], &uid)) return 2;
    if (!strcmp(argv[1], "serve") && argc == 3) {
        signal(SIGTERM, terminate_service); signal(SIGINT, terminate_service);
        return server((uid_t)uid);
    }
    if (!strcmp(argv[1], "client") && argc >= 4) return client((uid_t)uid, argc - 3, argv + 3);
    return 2;
}
#endif
