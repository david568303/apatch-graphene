// Minimal PID 1: mount an f2fs partition read-write (the kernel replays any fsync log),
// write one file into it, unmount cleanly and power off. Used to place the VM-only
// sepolicy.rule into Magisk's preinit dir on a disk carried over from a previous run.
// Kernel cmdline: fixdev=/dev/sda10 fixpath=watchdog/magisk/sepolicy.rule
// The file content comes from /payload in the initramfs.
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <unistd.h>

static char *arg(const char *cmdline, const char *key, char *out, size_t n) {
    const char *p = strstr(cmdline, key);
    if (!p) return NULL;
    p += strlen(key);
    size_t i = 0;
    while (p[i] && p[i] != ' ' && p[i] != '\n' && i + 1 < n) { out[i] = p[i]; i++; }
    out[i] = 0;
    return out;
}

static void mkdirs(char *path) {
    for (char *s = path + 1; *s; s++)
        if (*s == '/') { *s = 0; mkdir(path, 0700); *s = '/'; }
}

int main(void) {
    mkdir("/proc", 0755); mkdir("/dev", 0755); mkdir("/mnt", 0755);
    mount("proc", "/proc", "proc", 0, NULL);
    mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);
    int c = open("/dev/console", O_RDWR);
    if (c >= 0) { dup2(c, 1); dup2(c, 2); }
    setvbuf(stdout, NULL, _IONBF, 0);

    char cmdline[4096] = {0}, dev[256], rel[256], dst[600], buf[65536];
    int fd = open("/proc/cmdline", O_RDONLY);
    if (fd >= 0) { ssize_t r = read(fd, cmdline, sizeof(cmdline) - 1); (void)r; close(fd); }
    if (!arg(cmdline, "fixdev=", dev, sizeof dev) || !arg(cmdline, "fixpath=", rel, sizeof rel)) {
        printf("FIX: missing fixdev=/fixpath=\n"); goto out;
    }
    // GKI has no devtmpfs: create the node from sysfs once the partition shows up
    mkdir("/sys", 0755);
    mount("sysfs", "/sys", "sysfs", 0, NULL);
    char sysdev[300], majmin[32] = {0};
    snprintf(sysdev, sizeof sysdev, "/sys/class/block/%s/dev", strrchr(dev, '/') + 1);
    for (int i = 0; i < 900 && access(sysdev, F_OK); i++) usleep(100000);
    int sd = open(sysdev, O_RDONLY);
    if (sd >= 0) {
        ssize_t r = read(sd, majmin, sizeof(majmin) - 1); (void)r; close(sd);
        unsigned ma = 0, mi = 0;
        sscanf(majmin, "%u:%u", &ma, &mi);
        mknod(dev, S_IFBLK | 0600, makedev(ma, mi));
    }
    if (mount(dev, "/mnt", "f2fs", 0, NULL)) { printf("FIX: mount %s: %s\n", dev, strerror(errno)); goto out; }
    snprintf(dst, sizeof dst, "/mnt/%s", rel);
    mkdirs(dst);
    int in = open("/payload", O_RDONLY), o = open(dst, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    ssize_t n = in >= 0 ? read(in, buf, sizeof buf) : -1;
    if (o < 0 || n < 0 || write(o, buf, n) != n) { printf("FIX: write %s failed: %s\n", dst, strerror(errno)); }
    else printf("FIX: wrote %zd bytes to %s on %s\n", n, rel, dev);
    if (o >= 0) { fsync(o); close(o); }
    sync();
    if (umount("/mnt")) printf("FIX: umount: %s\n", strerror(errno));
    else printf("FIX: unmounted cleanly\n");
out:
    sync();
    reboot(RB_POWER_OFF);
    return 0;
}
