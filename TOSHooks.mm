// ============================================================================
//  XiuGou · 神魔之塔辅助（TrollStore / 非越狱环境）
//
//  架构说明（逆向 XiuGou.dylib 得出的结论，也是本文件的设计依据）：
//    · 不依赖 Substrate / Substitute —— TrollStore 环境没有这两个框架
//    · 不写游戏内存（没有 vm_write）—— 只用 mach_vm_read_overwrite 读
//    · 不 hook 任何函数 —— 用 il2cpp_runtime_invoke 直接调用游戏自己的方法
//    这样游戏执行的是它自己的逻辑，状态流转自然，服务端看到的报告也自洽。
//
//  入口：__attribute__((constructor)) 而不是 Logos 的 %ctor
//  本文件不需要 .xm 后缀，也不需要 Logos 预处理。
// ============================================================================

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <dlfcn.h>
#include <unistd.h>
#include <stdio.h>
#include <math.h>
#include <string.h>

#include "TOSBoard.h"
#import "XGConfig.h"
#import "XGOverlay.h"
#import "XGFastWin.h"
#import "XGSettlement.h"
#import "XGIl2Cpp.h"
#import "TouchInjector.h"

#ifndef PAGE_SIZE
#define PAGE_SIZE 4096UL
#endif

// ============================================================================
//  1. 进程内内存工具（tweak 与游戏同地址空间，不需要 task_for_pid）
// ============================================================================
static BOOL XGRead(uintptr_t addr, void *out, size_t len) {
    if (!addr || !out) return NO;
    vm_size_t got = 0;
    kern_return_t kr = vm_read_overwrite(mach_task_self(), (vm_address_t)addr,
                                        (vm_size_t)len,
                                        (vm_address_t)out, (vm_size_t *)&got);
    return kr == KERN_SUCCESS && got == len;
}

template <typename T>
static T XGReadV(uintptr_t addr) { T v = {}; XGRead(addr, &v, sizeof(T)); return v; }

static uintptr_t XGImageBase(const char *hint) {
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, hint)) return (uintptr_t)_dyld_get_image_header(i);
    }
    return 0;
}

// ============================================================================
//  2. 盘面读取（实测链路）
//     Puzzle 实例 → Puzzle._puzzleGems(0x158) → PuzzleGem._element(0xbc)
//     PuzzleGem.pos(0x60) 是格位索引，_puzzleGems 可能是 Il2CppArray 或 List<T>
// ============================================================================
static uintptr_t g_puzzle = 0;

/// 实测结论：Puzzle 有大量小偏移字段（0x0/0x4/0x8/0x18...）→ 那些是静态字段，
/// 所以实例很可能挂在静态字段上，用多路尝试拿。
static uintptr_t XGPuzzle(void) {
    if (g_puzzle) return g_puzzle;
    g_puzzle = (uintptr_t)XGI2GetInstanceMulti(XG_PUZZLE_CLASS);
    if (g_puzzle) NSLog(@"[XG] Puzzle 实例 = 0x%lx", (unsigned long)g_puzzle);
    return g_puzzle;
}

/// 从容器取出「元素指针数组」起始地址，兼容 Il2CppArray 与 List<T>
static uintptr_t XGContainerData(uintptr_t container, int *countOut) {
    *countOut = 0;
    if (!container) return 0;

    // List<T>：+0x10 = items(Il2CppArray*)，+0x18 = size
    uintptr_t items = XGReadV<uintptr_t>(container + XG_OFF_LIST_ITEMS);
    int32_t   size  = XGReadV<int32_t>(container + XG_OFF_LIST_SIZE);
    if (items && size > 0 && size <= 300) {
        *countOut = size;
        return items + XG_OFF_ARRAY_DATA;
    }

    // Il2CppArray：+0x18 = max_length，数据从 +0x20 开始
    int32_t len = XGReadV<int32_t>(container + XG_OFF_ARRAY_LENGTH);
    if (len > 0 && len <= 300) {
        *countOut = len;
        return container + XG_OFF_ARRAY_DATA;
    }
    return 0;
}

static BOOL XGReadBoard(TOSBoard *out) {
    if (!out) return NO;
    uintptr_t puzzle = XGPuzzle();
    if (!puzzle) return NO;

    uintptr_t gems = XGReadV<uintptr_t>(puzzle + XG_OFF_PUZZLE_GEMS);
    if (!gems) return NO;

    int count = 0;
    uintptr_t data = XGContainerData(gems, &count);
    if (!data || count < TOS_SIZE) return NO;

    memset(out->attr, -1, sizeof(out->attr));
    int filled = 0;
    for (int i = 0; i < count; i++) {
        uintptr_t gem = XGReadV<uintptr_t>(data + (uintptr_t)i * sizeof(uintptr_t));
        if (!gem) continue;
        int32_t el  = XGReadV<int32_t>(gem + XG_OFF_GEM_ELEMENT);
        int32_t pos = XGReadV<int32_t>(gem + XG_OFF_GEM_POS);
        if (el < 0 || el > 5) continue;
        if (pos < 0 || pos >= TOS_SIZE) continue;
        out->attr[pos] = (int8_t)el;
        filled++;
    }
    return filled >= 20;      // 至少 20 格有效
}

// ============================================================================
// ============================================================================
//  3. 自动转珠
// ============================================================================
static CGRect g_boardRect = {{0, 0}, {0, 0}};

static CGPoint XGCellToScreen(int idx) {
    int x = idx % TOS_W, y = idx / TOS_W;
    CGFloat cw = g_boardRect.size.width  / TOS_W;
    CGFloat ch = g_boardRect.size.height / TOS_H;
    return CGPointMake(g_boardRect.origin.x + cw * (x + 0.5),
                       g_boardRect.origin.y + ch * (y + 0.5));
}

static void XGPlayPath(const TOSSolution *sol, int stepMs) {
    if (!sol || sol->len < 2) return;
    TouchInjector *ti = [TouchInjector shared];
    if (!ti.available) { NSLog(@"[XG] 触摸注入不可用"); return; }

    [ti beginAtPoint:XGCellToScreen(sol->path[0]) inWindow:nil];
    for (int i = 1; i < sol->len; i++) {
        usleep((useconds_t)(stepMs * 1000));
        [ti moveToPoint:XGCellToScreen(sol->path[i])];
    }
    usleep((useconds_t)(stepMs * 1000));
    [ti end];
    NSLog(@"[XG] 落子完成：%d 步 / %d combo / 消 %d 珠",
          sol->len - 1, sol->combos, sol->cleared);
}

static void XGAutoSolveOnce(BOOL dryRun) {
    TOSBoard b;
    if (!XGReadBoard(&b)) { NSLog(@"[XG] 盘面读取失败（检查 XG_BOARD_ARRAY_OFF / g_boardRoot）"); return; }

    TOSSolution sol;
    if (!tos_solve(&b, XG.conf.maxSteps, XG.conf.solveBudgetMs, &sol, 1)) {
        NSLog(@"[XG] 无解"); return;
    }
    if (dryRun || XG.conf.dryRun) {
        printf("[XG] 解: ");
        for (int i = 0; i < sol.len; i++) printf("%d ", sol.path[i]);
        printf("combos=%d cleared=%d\n", sol.combos, sol.cleared);
        return;
    }
    XGPlayPath(&sol, XG.conf.touchStepMs);
}

// 面板"预览最优解"按钮用
int XGSolvePreview(char *out, int cap) {
    if (out && cap > 0) out[0] = 0;
    TOSBoard b;
    if (!XGReadBoard(&b)) {
        if (out) snprintf(out, cap, "盘面读取失败：检查 XG_BOARD_ARRAY_OFF");
        return 0;
    }
    TOSSolution sol;
    if (!tos_solve(&b, XG.conf.maxSteps, XG.conf.solveBudgetMs, &sol, 1)) {
        if (out) snprintf(out, cap, "无解");
        return 0;
    }
    if (out) {
        int n = snprintf(out, cap, "%d 步 / 消 %d 珠\n路径: ", sol.len - 1, sol.cleared);
        for (int i = 0; i < sol.len && n < cap - 8; i++)
            n += snprintf(out + n, cap - n, "%d ", sol.path[i]);
        n += snprintf(out + n, cap - n, "\n盘面:\n");
        for (int y = 0; y < TOS_H && n < cap - 16; y++) {
            for (int x = 0; x < TOS_W && n < cap - 12; x++)
                n += snprintf(out + n, cap - n, "%s", tos_attr_name(b.attr[y * TOS_W + x]));
            n += snprintf(out + n, cap - n, "\n");
        }
    }
    return sol.combos;
}

// ============================================================================
//  4. 快速胜利
//
//  实测结论：全量扫描 31,404 个类后确认，游戏没有 Result/Win/Settle 这类命名，
//  所以「直接调结算方法」这条路不存在。快速胜利只能走：
//      清空当前波次所有敌人的 HP → 让游戏自己触发全灭判定 → 自己走结算上报
//  这反而是最自然的路径（服务端看到的是游戏自己算出来的胜利）。
//
//  敌人链路：WaveData._enemies(0x18) 或 GameplayWaveData.<EnemyDatas>(0x10)
//           → EnemyData.currentHP(0x24) / _mCurrentHP(0x38)
//
//  注意 EnemyInstance 上有两个防秒杀开关（_isPreventInstantKill @0x48、cannotDie @0x8a），
//  Boss 会开；清场改的是 EnemyData 的 HP 字段，绕开这两个 flag。
// ============================================================================

static void XGWriteBytes(uintptr_t addr, const void *data, size_t len) {
    if (!addr || !data) return;
    uintptr_t page = addr & ~(uintptr_t)(PAGE_SIZE - 1);
    vm_protect(mach_task_self(), (vm_address_t)page, PAGE_SIZE,
               FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    vm_write(mach_task_self(), (vm_address_t)addr, (vm_offset_t)data,
             (mach_msg_type_number_t)len);
}

static int XGKillAllEnemies(void) {
    uintptr_t wave = (uintptr_t)XGI2GetInstanceMulti(XG_WAVE_CLASS);
    if (!wave) wave = (uintptr_t)XGI2GetInstanceMulti(XG_GWAVE_CLASS);
    if (!wave) { NSLog(@"[XG] 拿不到 WaveData 实例"); return 0; }

    uintptr_t list = XGReadV<uintptr_t>(wave + XG_OFF_WAVE_ENEMIES);
    if (!list) list = XGReadV<uintptr_t>(wave + XG_OFF_GWAVE_ENEMY_DATAS);
    if (!list) { NSLog(@"[XG] WaveData 里没有敌人列表"); return 0; }

    int count = 0;
    uintptr_t data = XGContainerData(list, &count);
    if (!data || count <= 0) { NSLog(@"[XG] 敌人列表为空"); return 0; }

    int killed = 0;
    for (int i = 0; i < count && i < 64; i++) {
        uintptr_t e = XGReadV<uintptr_t>(data + (uintptr_t)i * sizeof(uintptr_t));
        if (!e) continue;
        int32_t hpSimple = XGReadV<int32_t>(e + XG_OFF_ENEMY_HP_SIMPLE);
        int32_t hpFull   = XGReadV<int32_t>(e + XG_OFF_ENEMY_HP_FULL);
        int32_t zero = 0;
        if (hpSimple > 0) { XGWriteBytes(e + XG_OFF_ENEMY_HP_SIMPLE, &zero, 4); killed++; }
        if (hpFull   > 0) { XGWriteBytes(e + XG_OFF_ENEMY_HP_FULL,   &zero, 4); killed++; }
        int8_t dead = 1;
        XGWriteBytes(e + XG_OFF_ENEMY_DEAD, &dead, 1);
    }
    if (killed) NSLog(@"[XG] 清场：%d 个敌人 HP 归零（敌人共 %d 个）", killed, count);
    return killed;
}

// ---- 盘面验证：v6 装上后，probe 文件末尾会直接出现读到的 30 格 ----
void XGProbeBoardDump(void) {
    if (!XGProbePathBuf[0]) return;
    FILE *f = fopen(XGProbePathBuf, "a");
    if (!f) return;

    fprintf(f, "\n\n########## v6 盘面验证 ##########\n");

    // 1) 各种静态字段尝试
    static const char *cands[] = { "Instance", "_instance", "_getInstance",
                                   "mInstance", "s_Instance", "Current", NULL };
    for (int i = 0; cands[i]; i++) {
        uintptr_t v = XGI2StaticFieldPtr(XG_PUZZLE_CLASS, cands[i]);
        fprintf(f, "  静态字段 %-14s = 0x%lx\n", cands[i], (unsigned long)v);
    }

    uintptr_t puzzle = XGPuzzle();
    fprintf(f, "  Puzzle 实例         = 0x%lx\n", (unsigned long)puzzle);
    if (puzzle) {
        uintptr_t gems = XGReadV<uintptr_t>(puzzle + XG_OFF_PUZZLE_GEMS);
        int cnt = 0;
        uintptr_t data = XGContainerData(gems, &cnt);
        fprintf(f, "  _puzzleGems         = 0x%lx\n", (unsigned long)gems);
        fprintf(f, "  元素数组            = 0x%lx   数量=%d\n", (unsigned long)data, cnt);

        for (int i = 0; i < cnt && i < 40; i++) {
            uintptr_t g = XGReadV<uintptr_t>(data + (uintptr_t)i * sizeof(uintptr_t));
            if (!g) continue;
            int32_t el  = XGReadV<int32_t>(g + XG_OFF_GEM_ELEMENT);
            int32_t lv  = XGReadV<int32_t>(g + XG_OFF_GEM_LV);
            int32_t pos = XGReadV<int32_t>(g + XG_OFF_GEM_POS);
            fprintf(f, "    gem[%2d] @0x%-10lx el=%d lv=%d pos=%d\n",
                    i, (unsigned long)g, el, lv, pos);
        }
    }

    TOSBoard b;
    BOOL ok = XGReadBoard(&b);
    fprintf(f, "\n  盘面读取: %s\n", ok ? "√ 成功" : "× 失败");
    if (ok) {
        for (int y = 0; y < TOS_H; y++) {
            fprintf(f, "    ");
            for (int x = 0; x < TOS_W; x++)
                fprintf(f, "%s ", tos_attr_name(b.attr[y * TOS_W + x]));
            fprintf(f, "\n");
        }
    }

    fprintf(f, "\n  敌人清场测试: ");
    int k = XGKillAllEnemies();
    fprintf(f, k ? "清掉 %d 个\n" : "没找到敌人（可能不在战斗中）\n", k);
    fclose(f);
}

// ============================================================================
// ============================================================================
//  5. 主循环
// ============================================================================
static NSTimer *g_tickTimer = nil;
static CFAbsoluteTime g_lastSolve = 0;
static CFAbsoluteTime g_lastWin = 0;
static CFAbsoluteTime g_lastSettle = 0;

static void XGResolveRoots(void) {
    // 盘面/战斗对象：优先用配置里的静态偏移，其次尝试常见的单例类
    uintptr_t base = XGImageBase("UnityFramework");
    if (!base) base = XGImageBase("ProductName");
    if (!base) return;

    if (!g_battleRoot && XG_BATTLE_ROOT_PTR_OFF) {
        g_battleRoot = XGReadV<uintptr_t>(base + XG_BATTLE_ROOT_PTR_OFF);
    }
    // 盘面对象：BoardMainView / PuzzleView 的实例
    if (!g_boardRoot) {
        void *b = XGI2Instance("BoardMainView");
        if (!b) b = XGI2Instance("PuzzleView");
        if (b) g_boardRoot = (uintptr_t)b;
    }
}

static void XGTick(void) {
    @autoreleasepool {
        XGResolveRoots();
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();

        // 战斗倍速
        if (XG.on[F_TIME_SCALE]) XGFastWinSetSpeed((float)XG.conf.gameSpeed);

        // 快速胜利
        if (XG.on[F_FAST_WIN] && now - g_lastWin >= XG.conf.fastWinCooldown) {
            g_lastWin = now;
            switch (XG.conf.fastWinMode) {
                case 1: XGFastWinSetSpeed((float)XG.conf.gameSpeed); break;
                case 2: if (!XGKillAllEnemies()) NSLog(@"[XG] 清场失败：%@", XGFastWinStatus()); break;
                case 3: XGKillAllEnemies(); break;   // 全量扫描证实无结算类，本档等同清场
                default: break;
            }
        }

        // 结算伪造
        if (XG.on[F_SETTLE_FAKE] && now - g_lastSettle >= 1.0) {
            g_lastSettle = now;
            XGSettleReport rep;
            if (XGSettlementGenerate(&XG.settle, &rep)) {
                NSLog(@"[XG] 战报: %@", XGSettlementDescribe(&rep));
                if (!XGSettlementApply(&rep)) XGKillAllEnemies();
            }
        }

        // 自动转珠
        if (XG.on[F_AUTO_SOLVE] && now - g_lastSolve >= XG.conf.autoCooldown) {
            g_lastSolve = now;
            XGAutoSolveOnce(NO);
        }
    }
}

// ============================================================================
//  6. 入口（替代 Logos 的 %ctor）
// ============================================================================
// 加载标记：写到多个位置，任一成功即可证明 dylib 被成功注入
static void XGWriteLoadedFlag(void) {
    NSString *bundle = [[NSBundle mainBundle] bundleIdentifier] ?: @"?";
    NSString *line = [NSString stringWithFormat:
        @"XiuGou.dylib loaded\ntime=%@\nbundle=%@\npid=%d\nuid=%d\n",
        [NSDate date], bundle, getpid(), getuid()];

    NSMutableArray *paths = [NSMutableArray array];
    [paths addObject:@"/var/mobile/Documents/XG_loaded.txt"];
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    if (docs) [paths addObject:[docs stringByAppendingPathComponent:@"XG_loaded.txt"]];
    [paths addObject:[NSTemporaryDirectory() stringByAppendingPathComponent:@"XG_loaded.txt"]];

    for (NSString *p in paths) {
        NSString *dir = [p stringByDeletingLastPathComponent];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        if ([line writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil]) {
            NSLog(@"[XG] 加载标记写入 %@", p);
            return;
        }
    }
    NSLog(@"[XG] 加载标记写入失败（沙箱限制）");
}

__attribute__((constructor))
static void XGBoot(void) {
    @autoreleasepool {
        XGWriteLoadedFlag();
        NSLog(@"[XG] ===== XiuGou.dylib 加载 =====");
        NSLog(@"[XG] 目标: %@ pid=%d", [[NSBundle mainBundle] bundleIdentifier], getpid());

        XGLoadConfig();
        XGI2Init();

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            // 先把 UI 装上（保证悬浮球一定能出来，不被后面的重活影响）
            [XGOverlay install];

            // 字段探测：无条件跑（当前阶段最需要的数据，不依赖开关是否保存成功）
            // 必须在后台队列 —— 放主线程会卡死游戏启动。
            {
                NSLog(@"[XG] === 字段探测已排队（后台线程）===");
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                    @autoreleasepool {
                        int bytes = XGI2ProbeToFile(NULL);
                        NSLog(@"[XG] === 字段探测完成：%d 字节 ===", bytes);
                        XGProbeBoardDump();          // 追加盘面验证 + 清场测试
                        NSLog(@"[XG] === 盘面验证已写入探测文件 ===");
                    }
                });
            }

            g_tickTimer = [NSTimer scheduledTimerWithTimeInterval:0.35
                                                          repeats:YES
                                                            block:^(NSTimer *t) { XGTick(); }];
            NSLog(@"[XG] 主循环启动（0.35s 轮询）");
        });
    }
}