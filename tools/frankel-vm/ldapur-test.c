#include <stdio.h>
#include <stdint.h>
int main(void) {
    uint32_t buf[256];
    for (int i = 0; i < 256; i++) buf[i] = 0x1000 + i;
    uint32_t *p = &buf[128];          /* p - 24 bytes == buf[122] */
    uint32_t v;
    __asm__ volatile("ldapur %w0, [%1, #-24]" : "=r"(v) : "r"(p) : "memory");
    printf("ldapur [p,#-24] = %#x (expected %#x) -> %s\n", v, buf[122], v == buf[122] ? "OK" : "WRONG");
    return v != buf[122];
}
