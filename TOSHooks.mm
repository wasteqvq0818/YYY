// ============================================================================
//  XiuGou · 只做「直接胜利」（v8 · 绝对不会自己动）
//
//  前两版闪退的两个原因，这版都堵掉了：
//    ① v6：直接解引用未验证指针（memcpy 野地址）→ 全部换成 vm_read_overwrite
//    ② v7：内存扫描跑在主线程（NSTimer 回调），几秒无响应被 iOS 看门狗杀掉
//          → 扫描挪到后台队列，且默认不自动执行，只有你点按钮才扫一次
//
//  设计原则：装上之后它什么都不做。你点「扫描」它才动一次。
//  就算扫描逻辑有问题，也只在你主动点击时发生，不会影响正常游戏。
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

// ============================================================================
//  1. 安全内存读写（任何非法地址都只返回失败，不会崩）
// ============================================================================
static BOOL SafeRead(uintptr_t addr, void *out, size_t len) {
    if (!addr || !out || len == 0) return NO;
    if (addr < 0x10000000ULL) return NO;
    vm_size_t got = 0;
    kern_return_t kr = vm_read_overwrite(mach_task_self(), (vm_address_t)addr,
                                         (vm_size_t)len, (vm_address_t)out, &got);
    return kr == KERN_SUCCESS && got == len;
}

static BOOL SafeWrite(uintptr_t addr, const void *data, size_t len) {
    if (!addr || !data || len == 0) return NO;
    if (addr < 0x10000000ULL) return NO;
    uint8_t probe[8];
    if (!SafeRead(addr, probe, len >= 8 ? 8 : len)) return NO;   // 读得到才写

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
//  2. 扫描状态（面板显示）
// ============================================================================
static volatile int  g_scanning   = 0;   // 0=空闲 1=进行中 2=已完成
static volatile int  g_hitObjects = 0;
static volatile int  g_killed     = 0;
static volatile int  g_scannedMB  = 0;
static char          g_scanMsg[128] = "未扫描";

int  XGLastKillCount(void) { return g_killed; }
int  XGScanState(void)     { return g_scanning; }
const char *XGScanMessage(void) { return g_scanMsg; }

// ============================================================================
//  3. 扫描并清场
//
//  限流三件套（防止卡死）：
//    · 每次只读 64KB（不是 2MB）
//    · 总扫描量上限 300MB
//    · 累计超过 2.5 秒就主动停
// ============================================================================
#define CHUNK_BYTES      (64 * 1024)
#define MAX_TOTAL_BYTES  (300ULL * 1024 * 1024)
#define TIME_BUDGET_SEC  2.5

static int ScanAndKillEnemies(void) {
    g_hitObjects = 0;
    g_killed = 0;
    g_scannedMB = 0;

    if (!XGI2Init()) { snprintf(g_scanMsg, sizeof(g_scanMsg), "il2cpp 未就绪"); return -1; }
    void *klass = XGI2Class(XG_ENEMY_CLASS);
    if (!klass) { snprintf(g_scanMsg, sizeof(g_scanMsg), "找不到 EnemyData 类"); return -1; }

    uint8_t *buf = (uint8_t *)malloc(CHUNK_BYTES);
    if (!buf) { snprintf(g_scanMsg, sizeof(g_scanMsg), "内存不足"); return -1; }

    CFTimeInterval t0 = CFAbsoluteTimeGetCurrent();
    uint64_t totalRead = 0;
    int hits = 0, killed = 0;

    vm_address_t addr = 0;
    while (totalRead < MAX_TOTAL_BYTES) {
        // 超时保护
        if (CFAbsoluteTimeGetCurrent() - t0 > TIME_BUDGET_SEC) {
            snprintf(g_scanMsg, sizeof(g_scanMsg), "超时停止（已扫 %d MB）", g_scannedMB);
            break;
        }

        vm_size_t size = 0;
        vm_region_basic_info_data_64_t info;
        mach_port_t object_name = MACH_PORT_NULL;
        mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;

        kern_return_t kr = vm_region_64(mach_task_self(), &addr, &size,
                                        VM_REGION_BASIC_INFO_64,
                                        (vm_region_info_t)&info, &count, &object_name);
        if (kr != KERN_SUCCESS) break;
        if (object_name != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), object_name);

        BOOL readable   = (info.protection & VM_PROT_READ) != 0;
        BOOL writable   = (info.protection & VM_PROT_WRITE) != 0;
        BOOL executable = (info.protection & VM_PROT_EXECUTE) != 0;
        BOOL skip = (!readable || !writable || executable || size < 0x1000 || size > 0x20000000ULL);

        if (!skip) {
            uintptr_t p = ((uintptr_t)addr + 7) & ~(uintptr_t)7;
            uintptr_t end = (uintptr_t)addr + size;

            while (p + 0x40 < end) {
                if (CFAbsoluteTimeGetCurrent() - t0 > TIME_BUDGET_SEC) break;

                size_t want = CHUNK_BYTES;
                if (p + want > end) want = (size_t)(end - p);
                if (want < 0x40) break;

                vm_size_t got = 0;
                kern_return_t r = vm_read_overwrite(mach_task_self(), (vm_address_t)p,
                                                    (vm_size_t)want, (vm_address_t)buf, &got);
                if (r != KERN_SUCCESS || got < 0x40) break;

                totalRead += got;
                g_scannedMB = (int)(totalRead / (1024 * 1024));

                for (size_t off = 0; off + 0x40 < (size_t)got; off += 8) {
                    if (*(void **)(buf + off) != klass) continue;
                    uintptr_t obj = p + off;
                    hits++;

                    int32_t dead = SafeReadI32(obj + XG_OFF_ENEMY_DEAD);
                    int32_t hp   = SafeReadI32(obj + XG_OFF_ENEMY_HP_SIMPLE);
                    int32_t hpFull = SafeReadI32(obj + XG_OFF_ENEMY_HP_FULL);

                    // 合理性闸：血量必须在 (0, 10亿)
                    BOOL hpOK     = (hp > 0 && hp < 1000000000);
                    BOOL hpFullOK = (hpFull > 0 && hpFull < 1000000000);

                    if (hpOK) {
                        int32_t zero = 0;
                        if (SafeWrite(obj + XG_OFF_ENEMY_HP_SIMPLE, &zero, 4)) killed++;
                    }
                    if (hpFullOK) {
                        int32_t zero = 0;
                        if (SafeWrite(obj + XG_OFF_ENEMY_HP_FULL, &zero, 4)) killed++;
                    }
                    if (dead == 0 && (hpOK || hpFullOK)) {
                        int32_t one = 1;
                        SafeWrite(obj + XG_OFF_ENEMY_DEAD, &one, 4);
                    }
                }
                p += got;
            }
        }
        addr += size;
    }

    free(buf);
    g_hitObjects = hits;
    g_killed = killed;
    if (killed > 0) {
        snprintf(g_scanMsg, sizeof(g_scanMsg), "命中 %d 个对象，清零 %d 处 HP（扫了 %d MB）",
                 hits, killed, g_scannedMB);
    } else {
        snprintf(g_scanMsg, sizeof(g_scanMsg), "扫了 %d MB，命中 %d 个对象，没有可清的血量",
                 g_scannedMB, hits);
    }
    NSLog(@"[XG] %s", g_scanMsg);
    return killed;
}

// ============================================================================
//  4. 对外入口（面板按钮调用）—— 后台执行，绝不阻塞主线程
// ============================================================================
void XGScanAsync(void) {
    if (g_scanning == 1) return;
    g_scanning = 1;
    snprintf(g_scanMsg, sizeof(g_scanMsg), "扫描中…");

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            ScanAndKillEnemies();
            g_scanning = 2;
        }
    });
}

// 面板"预览最优解"按钮复用这个入口
int XGSolvePreview(char *out, int cap) {
    XGScanAsync();
    if (out) snprintf(out, cap, "已在后台开始扫描\n进度看面板顶部状态\n（结果约 1~3 秒后刷新）");
    return 0;
}

// ============================================================================
//  5. 入口：只装 UI，不做任何自动动作
// ============================================================================
__attribute__((constructor))
static void XGBoot(void) {
    @autoreleasepool {
        NSLog(@"[XG] ===== XiuGou v8 加载（只做直接胜利，默认不自动执行）=====");
        XGLoadConfig();

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [XGOverlay install];
            NSLog(@"[XG] 面板就绪。进战斗后点「扫描并清场」才会动作。");
        });
    }
}
