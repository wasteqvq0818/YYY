// ============================================================================
//  XiuGou 复刻 · 神魔之塔（com.madhead.tos.zh）功能层
//  架构：IL2CPP 方法指针 hook（MSHookFunction）+ 字段直写 + 触摸注入自动转珠
//  所有 [TODO] 处填你在目标上 dump 出来的类名/偏移，填完即生效
// ============================================================================

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <substrate.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <math.h>
#include <stdio.h>
#include <unistd.h>
#include "TOSBoard.h"
#import "TouchInjector.h"
#import "XGConfig.h"
#import "XGOverlay.h"
#import "XGFastWin.h"
#import "XGSettlement.h"
#import "XGIl2Cpp.h"

// ============================================================================
//  0. il2cpp API
// ============================================================================
typedef struct Il2CppDomain Il2CppDomain;
typedef struct Il2CppClass Il2CppClass;
typedef struct MethodInfo MethodInfo;

static Il2CppDomain *(*i2c_domain_get)(void);
static Il2CppClass  *(*i2c_class_from_name)(const Il2CppDomain *, const char *, const char *);
static const MethodInfo *(*i2c_method_from_name)(Il2CppClass *, const char *, int);
static const void *(*i2c_field_get_offset)(Il2CppClass *, const char *);

static void XGInitIl2Cpp(void) {
    void *h = dlopen(NULL, RTLD_NOW);
    i2c_domain_get        = (Il2CppDomain *(*)(void))dlsym(h, "il2cpp_domain_get");
    i2c_class_from_name   = (Il2CppClass *(*)(const Il2CppDomain *, const char *, const char *))dlsym(h, "il2cpp_class_from_name");
    i2c_method_from_name  = (const MethodInfo *(*)(Il2CppClass *, const char *, int))dlsym(h, "il2cpp_class_get_method_from_name");
    i2c_field_get_offset  = (const void *(*)(Il2CppClass *, const char *))dlsym(h, "il2cpp_field_get_offset");
}

/// 取方法入口指针（MethodInfo 首字段 = methodPointer）
static void *XGMethodPtr(const char *ns, const char *cls, const char *method, int argc) {
    if (!i2c_domain_get || !i2c_class_from_name) return NULL;
    Il2CppClass *k = i2c_class_from_name(i2c_domain_get(), ns, cls);
    if (!k) { NSLog(@"[XG] class not found: %s.%s", ns, cls); return NULL; }
    const MethodInfo *m = i2c_method_from_name(k, method, argc);
    if (!m) { NSLog(@"[XG] method not found: %s::%s/%d", cls, method, argc); return NULL; }
    return *(void **)m;
}

static uintptr_t XGFieldOff(const char *ns, const char *cls, const char *field) {
    if (!i2c_domain_get || !i2c_class_from_name || !i2c_field_get_offset) return 0;
    Il2CppClass *k = i2c_class_from_name(i2c_domain_get(), ns, cls);
    if (!k) return 0;
    return (uintptr_t)i2c_field_get_offset(k, field);
}

// ============================================================================
//  1. 进程内内存工具（tweak 与游戏同地址空间，无需 task_for_pid）
// ============================================================================
static BOOL XGRead(uintptr_t addr, void *out, size_t len) {
    if (!addr || !out) return NO;
    mach_vm_size_t got = 0;
    kern_return_t kr = mach_vm_read_overwrite(mach_task_self(), (mach_vm_address_t)addr,
                                              (mach_vm_size_t)len,
                                              (mach_vm_address_t)out, &got);
    return kr == KERN_SUCCESS && got == len;
}

template <typename T>
static T XGReadV(uintptr_t addr) { T v = {}; XGRead(addr, &v, sizeof(T)); return v; }

static BOOL XGWrite(uintptr_t addr, const void *data, size_t len) {
    if (!addr || !data) return NO;
    uintptr_t page = addr & ~(uintptr_t)(PAGE_SIZE - 1);
    vm_protect(mach_task_self(), (vm_address_t)page, PAGE_SIZE,
               FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    return mach_vm_write(mach_task_self(), (vm_address_t)addr,
                         (vm_offset_t)data, (mach_msg_type_number_t)len) == KERN_SUCCESS;
}

template <typename T>
static void XGWriteV(uintptr_t addr, T v) { XGWrite(addr, &v, sizeof(T)); }

static uintptr_t XGImageBase(const char *hint) {
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, hint)) return (uintptr_t)_dyld_get_image_header(i);
    }
    return 0;
}

// ============================================================================
//  2. 盘面读取：把游戏里的 30 格属性搬进 TOSBoard
//     [TODO] BOARD_ROOT 是"当前战斗盘面对象"的地址来源：
//       方案 A：静态字段 GameMain/BoardCtrl 单例 + 字段偏移
//       方案 B：AOB 定位盘面数组（6*5 个连续 int32，值域 0..5 最稳定）
// ============================================================================

static uintptr_t g_boardRoot   = 0;   // 盘面对象地址（每关重算）
static uintptr_t g_boardArrOff = XG_BOARD_ARRAY_OFF;   // 盘面数组在对象内偏移
static int       g_boardType   = XG_BOARD_ELEM_BYTE;   // 元素宽度：1=byte 4=int32

static BOOL XGReadBoard(TOSBoard *out) {
    if (!out) return NO;
    uintptr_t arr = g_boardRoot + g_boardArrOff;
    if (!g_boardRoot) return NO;

    if (g_boardType == XG_BOARD_ELEM_BYTE) {
        int8_t raw[TOS_SIZE] = {};
        if (!XGRead(arr, raw, sizeof(raw))) return NO;
        memcpy(out->attr, raw, TOS_SIZE);
    } else {
        int32_t raw[TOS_SIZE] = {};
        if (!XGRead(arr, raw, sizeof(raw))) return NO;
        for (int i = 0; i < TOS_SIZE; i++) out->attr[i] = (int8_t)raw[i];
    }
    // 合法性校验：全部落在 0..5 才认为读对了（防止读错对象导致求解器乱走）
    for (int i = 0; i < TOS_SIZE; i++) {
        if (out->attr[i] < 0 || out->attr[i] > 5) return NO;
    }
    return YES;
}

// ============================================================================
//  3. 自动转珠（旗舰功能）
//     流程：读盘面 → 求解 → 把格子索引映射成屏幕坐标 → 触摸逐点拖动
// ============================================================================

static CGRect g_boardRect = {{0,0},{0,0}};   // 棋盘在屏幕上的矩形（配置或从 UI 读）

static CGPoint XGCellToScreen(int idx) {
    int x = idx % TOS_W, y = idx / TOS_W;
    CGFloat cw = g_boardRect.size.width  / TOS_W;
    CGFloat ch = g_boardRect.size.height / TOS_H;
    return CGPointMake(g_boardRect.origin.x + cw * (x + 0.5),
                       g_boardRect.origin.y + ch * (y + 0.5));
}

/// 用注入触摸走完一条路径。stepMs 越小越快（但太快会被游戏判定为非法拖动）
static void XGPlayPath(const TOSSolution *sol, int stepMs) {
    if (!sol || sol->len < 2) return;
    TouchInjector *ti = [TouchInjector shared];
    if (!ti.available) { NSLog(@"[XG] touch injector unavailable"); return; }

    CGPoint p0 = XGCellToScreen(sol->path[0]);
    [ti beginAtPoint:p0 inWindow:nil];
    for (int i = 1; i < sol->len; i++) {
        usleep((useconds_t)(stepMs * 1000));
        CGPoint p = XGCellToScreen(sol->path[i]);
        [ti moveToPoint:p];
    }
    usleep((useconds_t)(stepMs * 1000));
    [ti end];
    NSLog(@"[XG] played path len=%d combos=%d cleared=%d", sol->len - 1, sol->combos, sol->cleared);
}

/// 自动转珠主循环：按配置的时间预算求解并落子
void XGAutoSolveOnce(void) {
    TOSBoard b;
    if (!XGReadBoard(&b)) { NSLog(@"[XG] board read failed"); return; }

    TOSSolution sol;
    int ok = tos_solve(&b, XG.conf.maxSteps, XG.conf.solveBudgetMs, &sol, 1);
    if (!ok || sol.combos < XG.conf.minCombos) {
        NSLog(@"[XG] no solution (minCombos=%d)", XG.conf.minCombos);
        return;
    }
    if (XG.conf.dryRun) {     // 调试：只打印不落子
        printf("[XG] solution: "); for (int i = 0; i < sol.len; i++) printf("%d ", sol.path[i]);
        printf(" combos=%d cleared=%d\n", sol.combos, sol.cleared);
        return;
    }
    XGPlayPath(&sol, XG.conf.touchStepMs);
}

// ============================================================================
//  4. 功能 hook
// ============================================================================

// ---- 4.1 无限技能 CD ----
// 思路：把"技能冷却读值"的函数改成返回 0。
// [TODO] TOS 里技能相关的类通常是 SkillCtrl / Skill / MonsterSkill，方法名 GetCD / get_CD。
static int32_t (*orig_getCD)(void *self);
static int32_t my_getCD(void *self) {
    if (XG.on[F_INF_SKILL]) return 0;
    return orig_getCD ? orig_getCD(self) : 0;
}

// ---- 4.2 无敌（每次受击伤害归零）----
// [TODO] 玩家受伤入口：Player::Hurt / Player::OnDamage；参数 (self, int damage)
static void (*orig_hurt)(void *self, int32_t dmg);
static void my_hurt(void *self, int32_t dmg) {
    if (XG.on[F_GOD_MODE]) {
        NSLog(@"[XG] blocked %d damage", dmg);
        return;                       // 直接吞掉，血量不动
    }
    if (orig_hurt) orig_hurt(self, dmg);
}

// ---- 4.3 伤害倍率 / 秒杀 ----
// [TODO] 敌人受伤入口：Monster::Hurt / Enemy::TakeDamage
static void (*orig_enemyHurt)(void *self, int32_t dmg);
static void my_enemyHurt(void *self, int32_t dmg) {
    if (XG.on[F_ONE_HIT] && orig_enemyHurt) { orig_enemyHurt(self, 99999999); return; }
    if (XG.on[F_DMG_MULT] && orig_enemyHurt) {
        long long v = (long long)dmg * (long long)XG.conf.dmgMult;
        orig_enemyHurt(self, (int32_t)(v > INT32_MAX ? INT32_MAX : v));
        return;
    }
    if (orig_enemyHurt) orig_enemyHurt(self, dmg);
}

// ---- 4.4 转珠时间加长 ----
// [TODO] 计时器读值函数 BoardCtrl::GetTurnTime / Timer::GetRemain
static float (*orig_turnTime)(void *self);
static float my_turnTime(void *self) {
    float t = orig_turnTime ? orig_turnTime(self) : 5.0f;
    return XG.on[F_LONG_TIME] ? t * XG.conf.timeMult : t;
}

// ---- 4.5 自动战斗（自动转珠 / 自动出招）----
// 用 CADisplayLink 低频轮询：检测"当前轮到玩家操作"→ 触发一次自动转珠
static NSTimer *g_autoTimer = nil;

// ---- 4.7 快速胜利 ----
// 档位：1=倍速  2=一击清场（推荐）  3=直接胜利流程
static void XGFastWinTick(void) {
    static CFAbsoluteTime last = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - last < XG.conf.fastWinCooldown) return;
    last = now;

    switch (XG.conf.fastWinMode) {
        case 1: {
            XGFastWinSetSpeed((float)XG.conf.gameSpeed);
            break;
        }
        case 2: {
            int n = XGFastWinKillAll();          // 清场后游戏自己判胜、自己结算
            if (!n) NSLog(@"[XG] fastwin: %@", XGFastWinStatus());
            break;
        }
        case 3: {
            int ok = XGFastWinForce();           // 直调胜利流程
            if (!ok) NSLog(@"[XG] force win failed, fallback -> killAll");
            else XGFastWinKillAll();
            break;
        }
        default: break;
    }
}

static void XGAutoTick(void) {
    // 结算伪造：生成战报并下发（对应原版 xg.settlement.* 那套参数）
    if (XG.on[F_SETTLE_FAKE]) {
        static CFAbsoluteTime lastSettle = 0;
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - lastSettle > 1.0) {
            lastSettle = now;
            XGSettleReport rep;
            if (XGSettlementGenerate(&XG.settle, &rep)) {
                NSLog(@"[XG] report: %@", XGSettlementDescribe(&rep));
                if (!XGSettlementApply(&rep)) {
                    NSLog(@"[XG] settle apply failed -> fallback killAll");
                    XGFastWinKillAll();
                }
            }
        }
    }
    if (XG.on[F_TIME_SCALE]) XGFastWinSetSpeed((float)XG.conf.gameSpeed);
    if (XG.on[F_FAST_WIN])   XGFastWinTick();
    if (!XG.on[F_AUTO_SOLVE]) return;
    // [TODO] 判断是否处于玩家转珠阶段：读 BoardCtrl 的 state 字段
    if (XG.conf.autoStrict && !XGReadV<int32_t>(g_boardRoot + XG_STATE_OFF)) return;
    static CFAbsoluteTime lastPlay = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - lastPlay < XG.conf.autoCooldown) return;
    lastPlay = now;
    XGAutoSolveOnce();
}

// ---- 4.6 掉率/奖励（可选，改结算表）----
// [TODO] 结算函数 ResultPanel::BuildReward / DropCtrl::Roll
// 手法：hook 返回前修改参数数组（掉落表是 List<DropItem>，改 items 的 id/count）

// ============================================================================
//  5. 装配
// ============================================================================
// 面板"预览最优解"用：求解但不落子，返回 combo 数并把路径写进 out
int XGSolvePreview(char *out, int cap) {
    if (out && cap > 0) out[0] = 0;
    TOSBoard b;
    if (!XGReadBoard(&b)) {
        if (out) snprintf(out, cap, "盘面读取失败：检查 XG_BOARD_ARRAY_OFF / g_boardRoot");
        return 0;
    }
    TOSSolution sol;
    int ok = tos_solve(&b, XG.conf.maxSteps, XG.conf.solveBudgetMs, &sol, 1);
    if (!ok) {
        if (out) snprintf(out, cap, "无解（可提高最大步数或预算）");
        return 0;
    }
    if (out) {
        int n = snprintf(out, cap, "步数 %d / 消 %d 珠\n路径: ", sol.len - 1, sol.cleared);
        for (int i = 0; i < sol.len && n < cap - 8; i++) {
            n += snprintf(out + n, cap - n, "%d ", sol.path[i]);
        }
        snprintf(out + n, cap - n, "\n盘面:\n");
        for (int y = 0; y < TOS_H && n < cap - 16; y++) {
            for (int x = 0; x < TOS_W && n < cap - 12; x++) {
                n += snprintf(out + n, cap - n, "%s", tos_attr_name(b.attr[y * TOS_W + x]));
            }
            n += snprintf(out + n, cap - n, "\n");
        }
    }
    return sol.combos;
}

static void XGInstallHooks(void) {
    // 类名/方法名按你 dump.cs 里的实际命名填
    struct { const char *ns, *cls, *m; int argc; void *repl; void **orig; } table[] = {
        { XG_NS_SKILL,  "SkillCtrl", "get_CD",        1, (void *)my_getCD,       (void **)&orig_getCD },
        { XG_NS_PLAYER, "Player",    "Hurt",          2, (void *)my_hurt,         (void **)&orig_hurt },
        { XG_NS_ENEMY,  "Monster",   "Hurt",          2, (void *)my_enemyHurt,    (void **)&orig_enemyHurt },
        { XG_NS_BOARD,  "BoardCtrl", "get_TurnTime",  1, (void *)my_turnTime,     (void **)&orig_turnTime },
    };

    for (size_t i = 0; i < sizeof(table)/sizeof(table[0]); i++) {
        void *fn = XGMethodPtr(table[i].ns, table[i].cls, table[i].m, table[i].argc);
        if (!fn) continue;
        MSHookFunction(fn, table[i].repl, table[i].orig);
        NSLog(@"[XG] hooked %s::%s/%d @ %p", table[i].cls, table[i].m, table[i].argc, fn);
    }
}

%ctor {
    @autoreleasepool {
        XGLoadConfig();
        XGInitIl2Cpp();

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            // 运行时自省：把关键类的字段/方法打进日志（替代 dump.cs）
            if (XG.on[F_DEBUG_PROBE]) XGI2ProbeConfigured();
            XGFastWinInstall();
            XGSettlementInstall();
            XGInstallHooks();
            [XGOverlay install];          // 悬浮球 + 开关面板
            g_autoTimer = [NSTimer scheduledTimerWithTimeInterval:0.35 repeats:YES
                                                        block:^(NSTimer *t) { XGAutoTick(); }];
            NSLog(@"[XG] loaded v1.0");
        });
    }
}

#ifndef PAGE_SIZE
#define PAGE_SIZE 4096UL   // iOS arm64；不依赖 <mach/vm_param.h>
#endif
