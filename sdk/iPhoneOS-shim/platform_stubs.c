/* zig 的 compiler_rt 会引用这两个 Mach-O 符号，它们平时由设备上的 libSystem 提供：
 *   __availability_version_check  —— 供 __isPlatformVersionAtLeast 做运行时版本判断
 *   _sys_icache_invalidate        —— 清指令缓存（JIT 用）
 *
 * 注意 Mach-O 的 C 符号会再加一个下划线，所以：
 *   Mach-O `__availability_version_check`  <=>  C 里写 `_availability_version_check`
 *   Mach-O `_sys_icache_invalidate`        <=>  C 里写 `sys_icache_invalidate`
 *
 * 实现取等价语义：版本检查恒为「满足」（目标本来就只有 iOS 17+）；
 * Apple Silicon 上非 JIT 代码不需要手工刷指令缓存，no-op 即可。
 */
#include <stddef.h>

int _availability_version_check(int major, int minor, int patch, int unused) {
    (void)major; (void)minor; (void)patch; (void)unused;
    return 1;
}

void sys_icache_invalidate(void *start, size_t len) {
    (void)start; (void)len;
}