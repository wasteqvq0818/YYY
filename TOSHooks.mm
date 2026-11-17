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
//  2. 盘面读取
// ============================================================================
static uintptr_t g_boardRoot   = 0;
static uintptr_t g_battleRoot  = 0;

static BOOL XGReadBoard(TOSBoard *out) {
    if (!out || !g_boardRoot) return NO;
    uintptr_t arr = g_boardRoot + XG_BOARD_ARRAY_OFF;

    if (XG_BOARD_ELEM_BYTE) {
        int8_t raw[TOS_SIZE] = {};
        if (!XGRead(arr, raw, sizeof(raw))) return NO;
        memcpy(out->attr, raw, TOS_SIZE);
    } else {
        int32_t raw[TOS_SIZE] = {};
        if (!XGRead(arr, raw, sizeof(raw))) return NO;
        for (int i = 0; i < TOS_SIZE; i++) out->attr[i] = (int8_t)raw[i];
    }
    // 值域闸：全部落在 0..5 才认为读对了，防止读错对象让求解器乱走
    for (int i = 0; i < TOS_SIZE; i++) {
        if (out->attr[i] < 0 || out->attr[i] > 5) return NO;
    }
    return YES;
}

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
//  4. 快速胜利 —— 调用式实现（不做 hook）
//
//  为什么改成"调用"而不是"hook 受伤函数"：
//    hook 需要 Substrate，TrollStore 没有；而 IL2CPP 暴露了 runtime_invoke，
//    可以直接调用游戏自己的结算/伤害方法，效果一样但零依赖。
// ============================================================================

// 4.1 清场：把敌人列表的 HP / alive 写 0
//     注意：这里只调游戏自己的"重算存活"逻辑，不直接判定胜负
static int XGKillAllViaList(void) {
    uintptr_t battle = g_battleRoot;
    if (!battle && XG_BATTLE_ROOT_PTR_OFF) {
        uintptr_t base = XGImageBase("UnityFramework");
        if (base) battle = XGReadV<uintptr_t>(base + XG_BATTLE_ROOT_PTR_OFF);
    }
    if (!battle) return 0;

    uintptr_t list = XGReadV<uintptr_t>(battle + XG_OFF_ENEMY_LIST);
    if (!list) return 0;

    uintptr_t items = XGReadV<uintptr_t>(list + 0x10);
    int32_t   n     = XGReadV<int32_t>(list + 0x18);
    if (!items || n <= 0 || n > 64) return 0;

    uintptr_t data = items + 0x20;
    int killed = 0;
    for (int i = 0; i < n; i++) {
        uintptr_t ent = XGReadV<uintptr_t>(data + (uintptr_t)i * sizeof(uintptr_t));
        if (!ent) continue;
        int32_t zero = 0;
        // 写内存：TrollStore 的 App 有 no-sandbox，直接 mach_vm_write 可用
        uintptr_t page = (ent + XG_OFF_ENEMY_HP) & ~(PAGE_SIZE - 1);
        vm_protect(mach_task_self(), (vm_address_t)page, PAGE_SIZE,
                   FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
        vm_write(mach_task_self(), (vm_address_t)(ent + XG_OFF_ENEMY_HP),
                      (vm_offset_t)&zero, sizeof(zero));
        if (XG_OFF_ENEMY_ALIVE) {
            int8_t a = 0;
            vm_write(mach_task_self(), (vm_address_t)(ent + XG_OFF_ENEMY_ALIVE),
                          (vm_offset_t)&a, sizeof(a));
        }
        killed++;
    }
    if (killed) NSLog(@"[XG] 清场 %d 个敌人（游戏会自己判定胜利并走正常结算）", killed);
    return killed;
}

// 4.2 直接调结算方法：拿到 Settle 实例 → 调结算/胜利方法
static int XGCallSettle(void) {
    void *inst = XGI2Instance(XG_SETTLE_CLASS);
    if (!inst) {
        NSLog(@"[XG] %s 的 Instance 拿不到（可能不在战斗中）", XG_SETTLE_CLASS);
        return 0;
    }
    void *m = XGI2Method(XG_SETTLE_CLASS, XG_SETTLE_METHOD, XG_FASTWIN_WIN_ARGC);
    if (!m) {
        NSLog(@"[XG] 方法 %s/%d 不存在，用 XGI2DumpMethods 探一下真实名字",
              XG_SETTLE_METHOD, XG_FASTWIN_WIN_ARGC);
        return 0;
    }
    void *params[1] = { NULL };
    BOOL t = YES;
    if (XG_FASTWIN_WIN_ARGC >= 1) params[0] = &t;
    void *exc = NULL;
    XGI2Invoke(m, inst, params, &exc);
    if (exc) { NSLog(@"[XG] 结算方法抛异常（参数不匹配？）"); return 0; }
    NSLog(@"[XG] 已调用 %s::%s", XG_SETTLE_CLASS, XG_SETTLE_METHOD);
    return 1;
}

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
                case 2: if (!XGKillAllViaList()) NSLog(@"[XG] 清场失败：%@", XGFastWinStatus()); break;
                case 3: if (!XGCallSettle()) XGKillAllViaList(); break;
                default: break;
            }
        }

        // 结算伪造
        if (XG.on[F_SETTLE_FAKE] && now - g_lastSettle >= 1.0) {
            g_lastSettle = now;
            XGSettleReport rep;
            if (XGSettlementGenerate(&XG.settle, &rep)) {
                NSLog(@"[XG] 战报: %@", XGSettlementDescribe(&rep));
                if (!XGSettlementApply(&rep)) XGKillAllViaList();
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
__attribute__((constructor))
static void XGBoot(void) {
    @autoreleasepool {
        NSLog(@"[XG] ===== XiuGou.dylib 加载 =====");
        NSLog(@"[XG] 目标: %@ pid=%d", [[NSBundle mainBundle] bundleIdentifier], getpid());

        XGLoadConfig();
        XGI2Init();

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            // 字段探测（面板开关打开时，把关键类的字段/偏移全打进日志）
            if (XG.on[F_DEBUG_PROBE]) {
                NSLog(@"[XG] === 字段探测开始 ===");
                XGI2ProbeConfigured();
                NSLog(@"[XG] === 字段探测结束 ===");
            }

            [XGOverlay install];

            g_tickTimer = [NSTimer scheduledTimerWithTimeInterval:0.35
                                                          repeats:YES
                                                            block:^(NSTimer *t) { XGTick(); }];
            NSLog(@"[XG] 主循环启动（0.35s 轮询）");
        });
    }
}
