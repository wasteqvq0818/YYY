// ============================================================================
//  XiuGou v10 · 直接胜利（彻底去掉会崩的调用）
//
//  v9 点扫描就闪退。两个嫌疑：
//    ① vm_region_64 遍历 5.6GB（几千个 region）+ mach_port_deallocate
//    ② il2cpp 类查找被放在后台线程 —— il2cpp 类型系统不是线程安全的
//
//  v10 的铁律：只调用「返回错误码」的 API，绝不调用可能直接崩的 API
//    ✅ vm_read_overwrite   —— 读失败返回 KERN_FAILURE，不会崩
//    ✅ vm_protect / vm_write
//    ❌ vm_region_64 + mach_port_deallocate  —— 去掉
//    ❌ 后台线程碰 il2cpp                    —— 类查找改回主线程
//
//  扫描方式：不做 region 枚举，直接在 [0x1_0000_0000, 0x5_0000_0000) 范围内
//  按 64KB 步进试读。未映射的块 vm_read_overwrite 立即返回失败，开销极小。
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

#import "XGConfig.h"
#import "XGOverlay.h"
#import "XGIl2Cpp.h"

#ifndef PAGE_SIZE
#define PAGE_SIZE 4096UL
#endif

// ---- 安全读写（只用不会崩的 API）----
static BOOL SafeRead(uintptr_t addr, void *out, size_t len) {
    if (!addr || !out || len == 0 || addr < 0x10000ULL) return NO;
    vm_size_t got = 0;
    return vm_read_overwrite(mach_task_self(), (vm_address_t)addr,
                             (vm_size_t)len, (vm_address_t)out, &got) == KERN_SUCCESS
           && got == len;
}

static BOOL SafeWrite(uintptr_t addr, const void *data, size_t len) {
    if (!addr || !data || len == 0 || addr < 0x10000ULL) return NO;
    uint8_t probe[8];
    if (!SafeRead(addr, probe, len >= 8 ? 8 : len)) return NO;
    uintptr_t page = addr & ~(uintptr_t)(PAGE_SIZE - 1);
    vm_protect(mach_task_self(), (vm_address_t)page, PAGE_SIZE,
               FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    return vm_write(mach_task_self(), (vm_address_t)addr,
                    (vm_offset_t)data, (mach_msg_type_number_t)len) == KERN_SUCCESS;
}

static int32_t R32(uintptr_t a) { int32_t v = 0; SafeRead(a, &v, 4); return v; }
static void    W32(uintptr_t a, int32_t v) { SafeWrite(a, &v, 4); }

// ---- 状态 ----
static volatile int g_state = 0;     // 0空闲 1扫描中 2完成 3失败
static volatile int g_nData = 0, g_nInst = 0, g_killed = 0;
static volatile int g_okBlocks = 0, g_totalBlocks = 0;
static char g_msg[320] = "未扫描";

typedef struct { uintptr_t addr; int32_t hp; int isInst; } Sample;
static Sample g_samples[6];
static int    g_sampleN = 0;

int  XGLastKillCount(void) { return g_killed; }
int  XGScanState(void)     { return g_state; }
const char *XGScanMessage(void) { return g_msg; }

const char *XGSampleInfo(void) {
    static char b[320];
    b[0] = 0;
    for (int i = 0; i < g_sampleN; i++) {
        char t[72];
        snprintf(t, sizeof(t), "%s 0x%lx hp=%d\n",
                 g_samples[i].isInst ? "I" : "D",
                 (unsigned long)g_samples[i].addr, g_samples[i].hp);
        strncat(b, t, sizeof(b) - strlen(b) - 1);
    }
    return b;
}

// ---- 扫描参数（保守）----
#define CHUNK        (64 * 1024)
#define SCAN_START   0x100000000ULL       // 4GB 起（iOS 堆一般在上面）
#define SCAN_END     0x500000000ULL       // 20GB 止
#define TIME_BUDGET  15.0

static void ScanWithKlass(void *kData, void *kInst) {
    uint8_t *buf = (uint8_t *)malloc(CHUNK);
    if (!buf) { snprintf(g_msg, sizeof(g_msg), "内存不足"); g_state = 3; return; }

    CFTimeInterval t0 = CFAbsoluteTimeGetCurrent();
    int nData = 0, nInst = 0, killed = 0, okBlocks = 0, totalBlocks = 0;

    for (uintptr_t p = SCAN_START; p + CHUNK < SCAN_END; p += CHUNK) {
        if (CFAbsoluteTimeGetCurrent() - t0 > TIME_BUDGET) break;
        totalBlocks++;

        vm_size_t got = 0;
        kern_return_t kr = vm_read_overwrite(mach_task_self(), (vm_address_t)p,
                                             (vm_size_t)CHUNK, (vm_address_t)buf, &got);
        if (kr != KERN_SUCCESS || got < 0x100) continue;   // 未映射，跳过
        okBlocks++;

        for (size_t off = 0; off + 0x100 < (size_t)got; off += 8) {
            void *head = *(void **)(buf + off);
            if (!head) continue;

            BOOL isData = (kData && head == kData);
            BOOL isInst = (!isData && kInst && head == kInst);
            if (!isData && !isInst) continue;

            uintptr_t o = p + off;
            if (isData) nData++; else nInst++;

            if (isData) {
                int32_t dead = R32(o + XG_OFF_ENEMY_DEAD);
                int32_t hp1  = R32(o + XG_OFF_ENEMY_HP_SIMPLE);
                int32_t hp2  = R32(o + XG_OFF_ENEMY_HP_FULL);

                if (g_sampleN < 6 && (hp1 > 0 || hp2 > 0)) {
                    g_samples[g_sampleN++] = (Sample){ o, hp1 > 0 ? hp1 : hp2, 0 };
                }
                if (hp1 > 0 && hp1 < 1000000000) { W32(o + XG_OFF_ENEMY_HP_SIMPLE, 0); killed++; }
                if (hp2 > 0 && hp2 < 1000000000) { W32(o + XG_OFF_ENEMY_HP_FULL,   0); killed++; }
                if (dead == 0 && (hp1 > 0 || hp2 > 0)) W32(o + XG_OFF_ENEMY_DEAD, 1);
            } else {
                int32_t php  = R32(o + XG_OFF_EI_PREDICT_HP);
                int32_t dead = R32(o + XG_OFF_EI_DEAD);
                if (g_sampleN < 6 && php > 0) {
                    g_samples[g_sampleN++] = (Sample){ o, php, 1 };
                }
                W32(o + XG_OFF_EI_PREVENT_KILL, 0);
                W32(o + XG_OFF_EI_CANNOT_DIE, 0);
                if (php > 0 && php < 1000000000) { W32(o + XG_OFF_EI_PREDICT_HP, 0); killed++; }
                if (dead == 0) { W32(o + XG_OFF_EI_DEAD, 1); killed++; }
            }
        }
    }

    free(buf);
    g_nData = nData; g_nInst = nInst; g_killed = killed;
    g_okBlocks = okBlocks; g_totalBlocks = totalBlocks;
    g_state = 2;

    snprintf(g_msg, sizeof(g_msg),
             "块 %d/%d｜Data %d｜Inst %d｜改动 %d",
             okBlocks, totalBlocks, nData, nInst, killed);
    NSLog(@"[XG] %s", g_msg);
    for (int i = 0; i < g_sampleN; i++) {
        NSLog(@"[XG] 样本%d %s @0x%lx hp=%d", i,
              g_samples[i].isInst ? "Inst" : "Data",
              (unsigned long)g_samples[i].addr, g_samples[i].hp);
    }
}

void XGScanAsync(void) {
    if (g_state == 1) return;
    g_state = 1;
    g_nData = g_nInst = g_killed = g_okBlocks = g_totalBlocks = 0;
    g_sampleN = 0;
    snprintf(g_msg, sizeof(g_msg), "扫描中…（最多 15 秒）");

    // ★ 关键：il2cpp 类查找必须在主线程（类型系统不是线程安全的）
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!XGI2Init()) {
            snprintf(g_msg, sizeof(g_msg), "il2cpp 未就绪");
            g_state = 3;
            return;
        }
        void *kData = XGI2Class(XG_ENEMY_CLASS);
        void *kInst = XGI2Class(XG_ENEMY_INSTANCE_CLASS);
        NSLog(@"[XG] klass: Data=%p Inst=%p", kData, kInst);

        if (!kData && !kInst) {
            snprintf(g_msg, sizeof(g_msg), "两个类都没找到");
            g_state = 3;
            return;
        }

        // 再下到后台做纯内存扫描（不碰 il2cpp）
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            @autoreleasepool {
                ScanWithKlass(kData, kInst);
            }
        });
    });
}

int XGSolvePreview(char *out, int cap) {
    XGScanAsync();
    if (out) snprintf(out, cap, "已开始（最多 15 秒）\n完成后点「刷新状态」");
    return 0;
}

__attribute__((constructor))
static void XGBoot(void) {
    @autoreleasepool {
        NSLog(@"[XG] ===== XiuGou v10 加载 =====");
        XGLoadConfig();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [XGOverlay install];
        });
    }
}
