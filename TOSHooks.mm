// ============================================================================
//  XiuGou v9 · 直接胜利（扩大扫描 + 同时处理 EnemyInstance）
//
//  v8 的教训：
//    清了 10 处 EnemyData.currentHP，但敌人血条没动、照常攻击。
//    两个原因：
//      ① 只扫了 310MB（游戏占 5.6GB）—— 真相大概率在没扫到的区域
//      ② EnemyData 是配置/数据层；场上敌人是 EnemyInstance
//         （带 predictHP@0x38、_isDead@0x90，还有 cannotDie@0x8a、
//          _isPreventInstantKill@0x48 两个防秒杀开关）
//
//  v9 做法：
//    · 一次遍历同时匹配两种类：EnemyData 和 EnemyInstance
//    · 扫描上限 2GB / 12 秒（后台跑，不碰主线程）
//    · 记录命中样本（地址 + HP 值），面板上直接显示，方便判断是不是真实例
//    · 依然遵守「先读得到才写」的铁律
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

// ---- 安全读写 ----
static BOOL SafeRead(uintptr_t addr, void *out, size_t len) {
    if (!addr || !out || len == 0 || addr < 0x10000000ULL) return NO;
    vm_size_t got = 0;
    return vm_read_overwrite(mach_task_self(), (vm_address_t)addr,
                             (vm_size_t)len, (vm_address_t)out, &got) == KERN_SUCCESS
           && got == len;
}

static BOOL SafeWrite(uintptr_t addr, const void *data, size_t len) {
    if (!addr || !data || len == 0 || addr < 0x10000000ULL) return NO;
    uint8_t probe[8];
    if (!SafeRead(addr, probe, len >= 8 ? 8 : len)) return NO;
    uintptr_t page = addr & ~(uintptr_t)(PAGE_SIZE - 1);
    vm_protect(mach_task_self(), (vm_address_t)page, PAGE_SIZE,
               FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    return vm_write(mach_task_self(), (vm_address_t)addr,
                    (vm_offset_t)data, (mach_msg_type_number_t)len) == KERN_SUCCESS;
}

static int32_t SafeReadI32(uintptr_t a) { int32_t v = 0; SafeRead(a, &v, 4); return v; }
static void    SafeWriteI32(uintptr_t a, int32_t v) { SafeWrite(a, &v, 4); }

// ---- 状态 ----
static volatile int  g_scanning  = 0;
static volatile int  g_nData = 0, g_nInst = 0, g_killed = 0, g_scannedMB = 0;
static char          g_scanMsg[320] = "未扫描";

// 命中样本（最多记 6 个，面板显示用）
typedef struct { uintptr_t addr; int32_t hp; int isInst; } Sample;
static Sample g_samples[6];
static int    g_sampleN = 0;

int  XGLastKillCount(void)   { return g_killed; }
int  XGScanState(void)       { return g_scanning; }
const char *XGScanMessage(void) { return g_scanMsg; }

// ---- 扫描参数 ----
#define CHUNK_BYTES      (256 * 1024)         // 每次 256KB
#define MAX_TOTAL_BYTES  (2ULL * 1024 * 1024 * 1024)   // 2GB 上限
#define TIME_BUDGET_SEC  12.0

static int ScanAndKill(void) {
    g_nData = g_nInst = g_killed = g_scannedMB = 0;
    g_sampleN = 0;

    if (!XGI2Init()) { snprintf(g_scanMsg, sizeof(g_scanMsg), "il2cpp 未就绪"); return -1; }

    void *kData = XGI2Class(XG_ENEMY_CLASS);            // "EnemyData"
    void *kInst = XGI2Class(XG_ENEMY_INSTANCE_CLASS);   // "EnemyInstance"
    if (!kData && !kInst) {
        snprintf(g_scanMsg, sizeof(g_scanMsg), "两个类都没找到");
        return -1;
    }

    uint8_t *buf = (uint8_t *)malloc(CHUNK_BYTES);
    if (!buf) { snprintf(g_scanMsg, sizeof(g_scanMsg), "内存不足"); return -1; }

    CFTimeInterval t0 = CFAbsoluteTimeGetCurrent();
    uint64_t total = 0;
    int nData = 0, nInst = 0, killed = 0;

    vm_address_t addr = 0;
    while (total < MAX_TOTAL_BYTES) {
        if (CFAbsoluteTimeGetCurrent() - t0 > TIME_BUDGET_SEC) break;

        vm_size_t size = 0;
        vm_region_basic_info_data_64_t info;
        mach_port_t obj = MACH_PORT_NULL;
        mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;

        if (vm_region_64(mach_task_self(), &addr, &size, VM_REGION_BASIC_INFO_64,
                         (vm_region_info_t)&info, &cnt, &obj) != KERN_SUCCESS) break;
        if (obj != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), obj);

        BOOL ok = (info.protection & VM_PROT_READ) && (info.protection & VM_PROT_WRITE)
                  && !(info.protection & VM_PROT_EXECUTE)
                  && size >= 0x1000 && size <= 0x40000000ULL;

        if (ok) {
            uintptr_t p = ((uintptr_t)addr + 7) & ~(uintptr_t)7;
            uintptr_t end = (uintptr_t)addr + size;

            while (p + 0x100 < end) {
                if (CFAbsoluteTimeGetCurrent() - t0 > TIME_BUDGET_SEC) break;

                size_t want = CHUNK_BYTES;
                if (p + want > end) want = (size_t)(end - p);
                if (want < 0x100) break;

                vm_size_t got = 0;
                if (vm_read_overwrite(mach_task_self(), (vm_address_t)p,
                                      (vm_size_t)want, (vm_address_t)buf, &got) != KERN_SUCCESS
                    || got < 0x100) break;

                total += got;
                g_scannedMB = (int)(total / (1024 * 1024));

                for (size_t off = 0; off + 0x100 < (size_t)got; off += 8) {
                    void *head = *(void **)(buf + off);
                    if (!head) continue;

                    BOOL isData = (head == kData);
                    BOOL isInst = (!isData && kInst && head == kInst);
                    if (!isData && !isInst) continue;

                    uintptr_t o = p + off;
                    if (isData) nData++; else nInst++;

                    if (isData) {
                        // 6 字段版：isDead@0x20 currentHP@0x24
                        int32_t dead = SafeReadI32(o + XG_OFF_ENEMY_DEAD);
                        int32_t hp1  = SafeReadI32(o + XG_OFF_ENEMY_HP_SIMPLE);
                        // 42 字段版：_mCurrentHP@0x38
                        int32_t hp2  = SafeReadI32(o + XG_OFF_ENEMY_HP_FULL);

                        if (g_sampleN < 6 && (hp1 > 0 || hp2 > 0)) {
                            g_samples[g_sampleN].addr = o;
                            g_samples[g_sampleN].hp = hp1 > 0 ? hp1 : hp2;
                            g_samples[g_sampleN].isInst = 0;
                            g_sampleN++;
                        }
                        if (hp1 > 0 && hp1 < 1000000000) { SafeWriteI32(o + XG_OFF_ENEMY_HP_SIMPLE, 0); killed++; }
                        if (hp2 > 0 && hp2 < 1000000000) { SafeWriteI32(o + XG_OFF_ENEMY_HP_FULL,   0); killed++; }
                        if (dead == 0 && (hp1 > 0 || hp2 > 0)) SafeWriteI32(o + XG_OFF_ENEMY_DEAD, 1);

                    } else {
                        // EnemyInstance：predictHP@0x38，防秒杀两个开关，_isDead@0x90
                        int32_t php  = SafeReadI32(o + XG_OFF_EI_PREDICT_HP);
                        int32_t dead = SafeReadI32(o + XG_OFF_EI_DEAD);

                        if (g_sampleN < 6 && php > 0) {
                            g_samples[g_sampleN].addr = o;
                            g_samples[g_sampleN].hp = php;
                            g_samples[g_sampleN].isInst = 1;
                            g_sampleN++;
                        }
                        // 先把"打不死"的开关关掉
                        SafeWriteI32(o + XG_OFF_EI_PREVENT_KILL, 0);
                        SafeWriteI32(o + XG_OFF_EI_CANNOT_DIE,   0);
                        if (php > 0 && php < 1000000000) { SafeWriteI32(o + XG_OFF_EI_PREDICT_HP, 0); killed++; }
                        if (dead == 0) { SafeWriteI32(o + XG_OFF_EI_DEAD, 1); killed++; }
                    }
                }
                p += got;
            }
        }
        addr += size;
    }

    free(buf);
    g_nData = nData; g_nInst = nInst; g_killed = killed;

    snprintf(g_scanMsg, sizeof(g_scanMsg),
             "扫 %dMB｜EnemyData %d｜EnemyInstance %d｜改动 %d 处",
             g_scannedMB, nData, nInst, killed);

    NSLog(@"[XG] %s", g_scanMsg);
    for (int i = 0; i < g_sampleN; i++) {
        NSLog(@"[XG] 样本 %d: %s @0x%lx hp=%d",
              i, g_samples[i].isInst ? "Inst" : "Data",
              (unsigned long)g_samples[i].addr, g_samples[i].hp);
    }
    return killed;
}

void XGScanAsync(void) {
    if (g_scanning == 1) return;
    g_scanning = 1;
    snprintf(g_scanMsg, sizeof(g_scanMsg), "扫描中…（最多 12 秒）");

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            ScanAndKill();
            g_scanning = 2;
        }
    });
}

// 面板按钮
int XGSolvePreview(char *out, int cap) {
    XGScanAsync();
    if (out) snprintf(out, cap, "后台扫描已开始（最多 12 秒）\n点「刷新状态」看结果");
    return 0;
}

// 样本信息（面板用）
const char *XGSampleInfo(void) {
    static char b[256];
    b[0] = 0;
    for (int i = 0; i < g_sampleN; i++) {
        char t[64];
        snprintf(t, sizeof(t), "%s 0x%lx hp=%d\n",
                 g_samples[i].isInst ? "I" : "D",
                 (unsigned long)g_samples[i].addr, g_samples[i].hp);
        strncat(b, t, sizeof(b) - strlen(b) - 1);
    }
    return b;
}

__attribute__((constructor))
static void XGBoot(void) {
    @autoreleasepool {
        NSLog(@"[XG] ===== XiuGou v9 加载 =====");
        XGLoadConfig();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [XGOverlay install];
        });
    }
}
