// Minimal PID 1 for the frankel kernel in QEMU: load SELinux policies the way
// Android init (or magiskinit) does and report what the kernel says.
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/klog.h>
#include <unistd.h>

static void cat(const char *path) {
    char buf[4096];
    int fd = open(path, O_RDONLY);
    if (fd < 0) { printf("  [%s: %s]\n", path, strerror(errno)); return; }
    ssize_t n;
    while ((n = read(fd, buf, sizeof(buf) - 1)) > 0) { buf[n] = 0; fputs(buf, stdout); }
    close(fd);
}

static int load(const char *file) {
    int in = open(file, O_RDONLY);
    if (in < 0) { printf("open %s: %s\n", file, strerror(errno)); return -1; }
    struct stat st; fstat(in, &st);
    char *data = malloc(st.st_size);
    ssize_t got = 0;
    while (got < st.st_size) { ssize_t r = read(in, data + got, st.st_size - got); if (r <= 0) break; got += r; }
    close(in);
    int out = open("/sys/fs/selinux/load", O_RDWR);
    if (out < 0) { printf("open load: %s\n", strerror(errno)); return -1; }
    ssize_t w = write(out, data, got);
    int e = errno;
    close(out);
    free(data);
    if (w != got) { printf("LOAD %s (%zd bytes): FAILED, write returned %zd: %s\n", file, got, w, strerror(e)); return -1; }
    printf("LOAD %s (%zd bytes): OK\n", file, got);
    return 0;
}

static void dmesg_grep(const char *needle) {
    static char buf[1 << 20];
    int n = klogctl(3, buf, sizeof(buf) - 1);
    if (n < 0) return;
    buf[n] = 0;
    for (char *line = strtok(buf, "\n"); line; line = strtok(NULL, "\n"))
        if (strcasestr(line, needle)) printf("  dmesg: %s\n", line);
}

int main(void) {
    mkdir("/proc", 0755); mkdir("/sys", 0755); mkdir("/dev", 0755);
    mount("proc", "/proc", "proc", 0, NULL);
    mount("sysfs", "/sys", "sysfs", 0, NULL);
    mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);
    mount("selinuxfs", "/sys/fs/selinux", "selinuxfs", 0, NULL);
    int fd = open("/dev/console", O_RDWR);
    if (fd >= 0) { dup2(fd, 1); dup2(fd, 2); }
    setvbuf(stdout, NULL, _IONBF, 0);

    printf("\n===== poltest =====\n");
    cat("/proc/version");
    printf("policyvers: "); cat("/sys/fs/selinux/policyvers"); printf("\n");

    char cmdline[4096] = {0};
    int c = open("/proc/cmdline", O_RDONLY); read(c, cmdline, sizeof(cmdline) - 1); close(c);
    const char *order = strstr(cmdline, "poltest=") ? strstr(cmdline, "poltest=") + 8 : "magisk";

    if (!strncmp(order, "stock", 5)) {
        load("/stock.pol");
        load("/magisk.pol");
    } else {
        load("/magisk.pol");
        load("/stock.pol");
    }
    dmesg_grep("selinux");
    printf("===== poltest done =====\n");
    sync();
    reboot(RB_POWER_OFF);
    return 0;
}
