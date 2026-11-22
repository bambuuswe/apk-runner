/*
 * apkfetch: runs inside the Android guest and asks the iOS app for the next
 * queued APK over the emulated network (10.0.2.2 is the host in QEMU user
 * networking).
 *
 * Protocol (host side lives in Platform/iOS/UTMAPKRunner.swift):
 *   guest connects, host sends an 8 byte big-endian length followed by that
 *   many bytes of APK data, then closes. A length of 0 means nothing queued.
 *
 * Usage: apkfetch HOST PORT OUTFILE
 * Exit:  0 = APK written, 1 = nothing queued / host unreachable, 2 = error
 */
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

static int read_full(int fd, void *buf, size_t len) {
    size_t got = 0;
    while (got < len) {
        ssize_t n = read(fd, (char *)buf + got, len - got);
        if (n < 0 && errno == EINTR) {
            continue;
        }
        if (n <= 0) {
            return -1;
        }
        got += (size_t)n;
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc != 4) {
        fprintf(stderr, "usage: %s HOST PORT OUTFILE\n", argv[0]);
        return 2;
    }
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)atoi(argv[2]));
    if (inet_pton(AF_INET, argv[1], &addr.sin_addr) != 1) {
        fprintf(stderr, "bad host\n");
        return 2;
    }
    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) {
        return 1;
    }
    /* generous timeouts: the guest is emulated and can be very slow */
    struct timeval tv = { .tv_sec = 120, .tv_usec = 0 };
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    if (connect(sock, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(sock);
        return 1;
    }
    unsigned char header[8];
    if (read_full(sock, header, sizeof(header)) != 0) {
        close(sock);
        return 1;
    }
    uint64_t len = 0;
    for (int i = 0; i < 8; i++) {
        len = (len << 8) | header[i];
    }
    if (len == 0) {
        close(sock);
        return 1;
    }
    char tmp[4096];
    snprintf(tmp, sizeof(tmp), "%s.part", argv[3]);
    int out = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (out < 0) {
        close(sock);
        return 2;
    }
    static char buf[1 << 16];
    uint64_t remaining = len;
    while (remaining > 0) {
        size_t want = remaining < sizeof(buf) ? (size_t)remaining : sizeof(buf);
        ssize_t n = read(sock, buf, want);
        if (n < 0 && errno == EINTR) {
            continue;
        }
        if (n <= 0) {
            close(out);
            close(sock);
            unlink(tmp);
            return 2;
        }
        size_t written = 0;
        while (written < (size_t)n) {
            ssize_t w = write(out, buf + written, (size_t)n - written);
            if (w < 0 && errno == EINTR) {
                continue;
            }
            if (w <= 0) {
                close(out);
                close(sock);
                unlink(tmp);
                return 2;
            }
            written += (size_t)w;
        }
        remaining -= (uint64_t)n;
    }
    close(sock);
    if (fsync(out) != 0 || close(out) != 0 || rename(tmp, argv[3]) != 0) {
        unlink(tmp);
        return 2;
    }
    return 0;
}
