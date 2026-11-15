#define CONTROL_TEST
#include "../Helper/control.c"
#include <assert.h>

static void check_parse(const char *text, enum action expected) {
    char line[256]; snprintf(line, sizeof(line), "%s", text);
    assert(parse(line).action == expected);
}

int main(void) {
    (void)terminate_service; (void)server; (void)client;
    unsigned long n;
    assert(number("501", &n) && n == 501);
    assert(!number("0", &n)); assert(!number("1", &n));
    assert(!number("-1", &n)); assert(!number("501;id", &n));
    assert(!number("2147483648", &n)); assert(!number("", &n));
    check_parse("status", STATUS); check_parse("stop", STOP);
    check_parse("start-full 123 203.0.113.7", FULL);
    check_parse("start-proxy 123", PROXY);
    const char *bad[] = {
        "", "shell id", "stop 501", "status extra", "start-full 123 999.1.1.1",
        "start-full -123 203.0.113.7", "start-full 1 203.0.113.7",
        "start-full 123 example.com", "start-full 123 203.0.113.7 /tmp/evil",
        "start-full 123 203.0.113.7;id", "start-full 123 $(id)",
        "start-proxy 123 /tmp/evil", "start-full 123 203.0.113.7 a b c d",
        "uninstall", "install /tmp/helper", "start-full 123 ::1"
    };
    for (size_t i = 0; i < sizeof(bad)/sizeof(bad[0]); i++) check_parse(bad[i], INVALID);
    int sv[2]; assert(socketpair(AF_UNIX, SOCK_STREAM, 0, sv) == 0);
    uid_t peer; assert(peer_uid(sv[0], &peer) == 0 && peer == geteuid());
    char line[MAX_REQUEST];
    assert(send_all(sv[0], "status\n", 7) == 0);
    assert(read_request(sv[1], line) == 0 && !strcmp(line, "status"));
    assert(send_all(sv[0], "st\0op\n", 6) == 0);
    assert(read_request(sv[1], line) != 0);
    close(sv[0]); close(sv[1]);
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, sv) == 0);
    char huge[MAX_REQUEST + 32]; memset(huge, 'a', sizeof(huge));
    assert(send_all(sv[0], huge, sizeof(huge)) == 0);
    assert(read_request(sv[1], line) != 0);
    close(sv[0]); close(sv[1]);
    assert(process_identity(getpid(), geteuid()) != 0);
    assert(process_identity(getpid(), geteuid() + 1) == 0);
    assert(process_identity(INT_MAX, geteuid()) == 0);
    char file[] = "/tmp/mojaveray-control-test.XXXXXX";
    int testfd = mkstemp(file); assert(testfd >= 0);
    assert(fchmod(testfd, 0600) == 0);
    assert(protected_file(file, 0) == (geteuid() == 0));
    assert(fchmod(testfd, 0666) == 0);
    assert(!protected_file(file, 0));
    close(testfd); unlink(file);
    if (geteuid() == 0) {
        char dir[] = "/tmp/mojaveray-action-test.XXXXXX";
        assert(mkdtemp(dir));
        char script[256], tun[256];
        snprintf(script, sizeof(script), "%s/network.sh", dir);
        snprintf(tun, sizeof(tun), "%s/tun2socks", dir);
        FILE *f = fopen(script, "w"); assert(f);
        fputs("#!/bin/bash\nprintf '%s|%s|%s|%s|%s' \"$1\" \"$2\" \"${3:-}\" \"${4:-}\" \"$MOJAVERAY_SERVICE\"\n", f);
        fclose(f); assert(chmod(script, 0600) == 0);
        f = fopen(tun, "w"); assert(f); fclose(f); assert(chmod(tun, 0600) == 0);
        char output[MAX_REPLY];
        struct request full = { FULL, 123, "203.0.113.7" };
        assert(run_action(dir, 501, full, output) == 0);
        assert(!strcmp(output, "service-start-full|501|123|203.0.113.7|1"));
        struct request stop = { STOP, 0, "" };
        assert(run_action(dir, 501, stop, output) == 0);
        assert(!strcmp(output, "stop|501|||1"));
        unlink(tun);
        assert(symlink(script, tun) == 0);
        assert(run_action(dir, 501, full, output) != 0);
        unlink(tun); unlink(script); rmdir(dir);
    }
    struct sockaddr_un sa; socket_address(&sa, 501);
    assert(!strcmp(sa.sun_path, "/var/run/mojaveray-control-501.sock"));
    puts("control: parser, bounds, NUL, peer credentials, PID ownership, file permissions, fixed argv and environment: PASS");
    return 0;
}
