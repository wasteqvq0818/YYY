// ============================================================================
//  XiuGou · 精简版（只做「直接胜利」）
//
//  为什么砍到只剩这一个功能：
//    上一版加了盘面探测 + 清场测试，里面有直接解引用未验证指针的地方，导致闪退。
//    这一版的原则是「宁可什么都不做，也绝不崩」：
//      · 所有内存读取走 vm_read_overwrite（返回错误码，不会 SIGSEGV）
//      · 所有内存写入前先确认落在可写区域内
//      · 拿不到数据就静默跳过，不重试、不祈祷
//
//  直接胜利的实现思路（不依赖游戏内部结构）：
//    不遍历 WaveData / 不猜容器布局，而是直接扫描进程内存，找所有
//    「对象头 == EnemyData 类指针」的对象，把它的 HP 写 0、isDead 写 1。
//    游戏自己的全灭判定会让它走正常胜利流程。
// ============================================================================

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <dlfcn.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#include "TOSBoard.h"
#import "XGConfig.h"
#import "XGOverlay.h"
#import "XGIl2Cpp.h"

#ifndef PAGE_SIZE
#define PAGE_SIZE 4096UL
#endif

// ============================================================================
//  1. 绝对安全的内存读写（不会崩）
// ============================================================================
static BOOL SafeRead(uintptr_t addr, void *out, size_t len) {
    if (!addr || !out || len == 0) return NO;
    if (addr < 0x10000000ULL) return NO;                 // 低地址肯定不是对象
    mach_vm_size_t got = 0;
    kern_return_t kr = vm_read_overwrite(mach_task_self(), (vm_address_t)addr,
                                         (vm_size_t)len, (vm_address_t)out,
                                         (vm_size_t *)&got);
    return kr == KERN_SUCCESS && got == len;
}

static BOOL SafeWrite(uintptr_t addr, const void *data, size_t len) {
    if (!addr || !data || len == 0) return NO;
    if (addr < 0x10000000ULL) return NO;
    // 写入前先确认这块地址读得到（说明是已映射的合法内存）
    uint8_t probe[8];
    if (!SafeRead(addr, probe, len >= 8 ? 8 : len)) return NO;

    uintptr_t page = addr & ~(uintptr_t)(PAGE_SIZE - 1);
    vm_protect(mach_task_self(), (vm_address_t)page, PAGE_SIZE,
               FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    return vm_write(mach_task_self(), (vm_address_t)addr,
                    (vm_offset_t)data, (mach_msg_type_number_t)len) == KERN_SUCCESS;
}

static int32_t SafeReadI32(uintptr_t addr) {
    int32_t v = 0;
    SafeRead(addr, &v, sizeof(v));
    return v;
}

// ============================================================================
//  2. 直接胜利：扫描内存找 EnemyData 实例，HP 清零
// ============================================================================

// 上一次扫描结果（面板显示用）
static int g_lastHit = 0;

typedef struct {
    uintptr_t start;
    uintptr_t end;
} HeapRegion;

/// 收集所有「可读写、非可执行」的堆区域（栈/代码段/映射文件都跳过）
static int CollectHeap(vm_address_t *out, size_t maxN) {
    mach_vm_address_t addr = 0;
    int n = 0;
    while (n < (int)maxN) {
        mach_vm_size_t size = 0;
        vm_region_basic_info_data_64_t info;
        mach_port_t object_name = MACH_PORT_NULL;
        mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;

        kern_return_t kr = mach_vm_region(mach_task_self(), &addr, &size,
                                          VM_REGION_BASIC_INFO_64,
                                          (vm_region_info_t)&info, &count,
                                          &object_name);
        if (kr != KERN_SUCCESS) break;

        BOOL readable = (info.protection & VM_PROT_READ) != 0;
        BOOL writable = (info.protection & VM_PROT_WRITE) != 0;
        BOOL executable = (info.protection & VM_PROT_EXECUTE) != 0;

        // 只扫「可读写且不可执行」的块 —— 游戏对象只可能在堆/数据段里
        if (readable && writable && !executable && size >= 0x1000 && size <= 0x40000000ULL) {
            out[n * 2]     = addr;
            out[n * 2 + 1] = addr + size;
            n++;
        }
        if (object_name != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), object_name);
        addr += size;
    }
    return n;
}

#define MAX_REGIONS 4096
#define CHUNK       (2 * 1024 * 1024)     // 每次读 2MB 再本地比对

/// 在内存里找「对象头 == 指定类指针」的对象，对每个命中的 EnemyData 做清零
static int ScanAndKillEnemies(void) {
    if (!XGI2Init()) return -1;

    void *klass = XGI2Class(XG_ENEMY_CLASS);
    if (!klass) return -1;

    static vm_address_t regions[MAX_REGIONS * 2];
    int nreg = CollectHeap(regions, MAX_REGIONS);
    if (nreg <= 0) return -1;

    uint8_t *buf = (uint8_t *)malloc(CHUNK);
    if (!buf) return -1;

    int hits = 0, killed = 0;

    for (int r = 0; r < nreg; r++) {
        uintptr_t start = regions[r * 2];
        uintptr_t end   = regions[r * 2 + 1];
        if (end <= start) continue;

        // 对象头 8 字节对齐
        for (uintptr_t p = (start + 7) & ~(uintptr_t)7; p + 0x40 < end; ) {
            size_t want = CHUNK;
            if (p + want > end) want = (size_t)(end - p);
            if (want < 0x40) break;

            mach_vm_size_t got = 0;
            kern_return_t kr = vm_read_overwrite(mach_task_self(), (vm_address_t)p,
                                                 (vm_size_t)want, (vm_address_t)buf,
                                                 (vm_size_t *)&got);
            if (kr != KERN_SUCCESS || got < 0x40) {
                // 这块读不了，跳到下一个 region
                break;
            }

            for (size_t off = 0; off + 0x40 < (size_t)got; off += 8) {
                void *head = *(void **)(buf + off);
                if (head != klass) continue;

                uintptr_t obj = p + off;
                hits++;

                // 6 字段版 EnemyData：isDead@0x20  currentHP@0x24
                int32_t dead = SafeReadI32(obj + XG_OFF_ENEMY_DEAD);
                int32_t hp   = SafeReadI32(obj + XG_OFF_ENEMY_HP_SIMPLE);

                // 合理性：HP 必须在 (0, 1e9) 之间，否则说明这不是真正的 EnemyData
                if (hp > 0 && hp < 1000000000) {
                    int32_t zero = 0;
                    if (SafeWrite(obj + XG_OFF_ENEMY_HP_SIMPLE, &zero, 4)) killed++;
                }
                // 顺手标死（dead==0 才写，已经是 1 就不动）
                if (dead == 0) {
                    int32_t one = 1;
                    SafeWrite(obj + XG_OFF_ENEMY_DEAD, &one, 4);
                }
            }
            p += got;
        }
    }
    free(buf);
    g_lastHit = killed;
    if (killed) NSLog(@"[XG] 直接胜利：命中 %d 个 EnemyData，清掉 %d 个 HP", hits, killed);
    return killed;
}

// ============================================================================
//  3. 面板用的接口
// ============================================================================
int XGSolvePreview(char *out, int cap) {
    // 精简版里这个按钮改成「立即清场」
    int n = ScanAndKillEnemies();
    if (out) {
        if (n < 0) snprintf(out, cap, "扫描失败：EnemyData 类没找到，或还没进战斗");
        else snprintf(out, cap, "命中 %d 个敌人对象，清掉 %d 个 HP", g_lastHit, n);
    }
    return n;
}

int XGLastKillCount(void) { return g_lastHit; }

// ============================================================================
//  4. 主循环：开关开着就定时扫描
// ============================================================================
static NSTimer *g_tick = nil;
static CFAbsoluteTime g_lastScan = 0;

static void XGTick(void) {
    @autoreleasepool {
        if (!XG.on[F_FAST_WIN]) return;

        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - g_lastScan < 1.5) return;      // 1.5 秒一次，别把 CPU 打死
        g_lastScan = now;

        int n = ScanAndKillEnemies();
        if (n > 0) NSLog(@"[XG] 已清场 %d", n);
    }
}

// ============================================================================
//  5. 入口
// ============================================================================
__attribute__((constructor))
static void XGBoot(void) {
    @autoreleasepool {
        NSLog(@"[XG] ===== XiuGou 精简版加载（只做直接胜利）=====");
        XGLoadConfig();

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [XGOverlay install];
            g_tick = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                     repeats:YES
                                                       block:^(NSTimer *t) { XGTick(); }];
            NSLog(@"[XG] 主循环启动（1.5s 扫描一次，仅当「直接胜利」开关打开）");
        });
    }
}
