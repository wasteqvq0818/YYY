#import "XGSettlement.h"
#import "XGConfig.h"
#import "XGIl2Cpp.h"

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <string.h>
#include <stdlib.h>

// ============================================================================
//  为什么这样设计（逆向结论）
//
//  XiuGou.dylib 的导入表里只有 _vm_read_overwrite，没有 vm_write / mach_vm_write。
//  它靠 _dlsym 运行期绑定游戏函数，用 `XG binding failed [%s]` 记录绑定失败。
//  导出 `_xiugou_apply_command` / `_xiugou_build_status` 供外部下发命令。
//
//  推论：它的"快速胜利"= 生成合规战报 → 喂给游戏自己的结算上报。
//  这也解释了它为什么有一整套 settlement 参数（区间、模式、自定义、逐回合）。
//
//  本模块照这个思路实现：先算出一份自洽报告，再交给游戏的结算构造点。
// ============================================================================

typedef struct Il2CppDomain Il2CppDomain;
typedef struct Il2CppClass Il2CppClass;
typedef struct MethodInfo MethodInfo;

static Il2CppDomain *(*st_domain_get)(void);
static Il2CppClass  *(*st_class_from_name)(const Il2CppDomain *, const char *, const char *);
static const MethodInfo *(*st_method_from_name)(Il2CppClass *, const char *, int);
static void         *(*st_runtime_invoke)(const void *, void *, void **, void **);

static BOOL g_stReady = NO;

static void STBind(void) {
    if (g_stReady) return;
    void *h = dlopen(NULL, RTLD_NOW);
    st_domain_get       = (Il2CppDomain *(*)(void))dlsym(h, "il2cpp_domain_get");
    st_class_from_name  = (Il2CppClass *(*)(const Il2CppDomain *, const char *, const char *))dlsym(h, "il2cpp_class_from_name");
    st_method_from_name = (const MethodInfo *(*)(Il2CppClass *, const char *, int))dlsym(h, "il2cpp_class_get_method_from_name");
    st_runtime_invoke   = (void *(*)(const void *, void *, void **, void **))dlsym(h, "il2cpp_runtime_invoke");
    g_stReady = st_domain_get && st_class_from_name && st_method_from_name;
    if (!g_stReady) NSLog(@"[XG-ST] il2cpp 符号缺失；结算只能生成不能下发");
}

// ============================================================================
// 1. 参数默认值（对齐原版面板出厂值）
// ============================================================================
void XGSettlementDefaults(XGSettleParams *p) {
    if (!p) return;
    p->waves             = 1;
    p->roundsPerWave     = 3;
    p->combosPerRound    = 8;
    p->stepsPerRound     = 12;
    p->roundSeconds      = 6;
    p->waveSwitchSeconds = 2;
    p->firstClearGroups  = 4;
    p->orbsPerGroup      = 3;
    p->mode              = 0;         // 区间随机
    p->damageMin         = 200000;
    p->damageMax         = 900000;
    p->damageFixed       = 500000;
    p->targetSeconds     = 0;
    p->jitterPercent     = 12;
}

// ============================================================================
// 2. 伪随机（不用 arc4random 是为了可复现；换个 seed 就是另一份战报）
// ============================================================================
static uint64_t g_seed = 0;

static uint32_t next_rand(void) {
    if (!g_seed) g_seed = (uint64_t)time(NULL) ^ ((uint64_t)getpid() << 17);
    g_seed ^= g_seed << 13;
    g_seed ^= g_seed >> 7;
    g_seed ^= g_seed << 17;
    return (uint32_t)(g_seed & 0x7fffffff);
}

static int jitter(int base, int pct) {
    if (pct <= 0 || base == 0) return base;
    int span = base * pct / 100;
    if (span < 1) span = 1;
    int delta = (int)(next_rand() % (uint32_t)(span * 2 + 1)) - span;
    int v = base + delta;
    return v < 1 ? 1 : v;
}

// ============================================================================
// 3. 生成战报
//     关键：不要给每一回合都用同一个数字。
//     真人打出来的回合伤害是有波动的，恒定值是最容易被统计检测抓的特征。
// ============================================================================
int XGSettlementGenerate(const XGSettleParams *p, XGSettleReport *out) {
    if (!p || !out) return 0;
    if (p->waves <= 0 || p->roundsPerWave <= 0) return 0;

    int totalRounds = p->waves * p->roundsPerWave;
    if (totalRounds > XG_MAX_ROUNDS) totalRounds = XG_MAX_ROUNDS;

    memset(out, 0, sizeof(*out));
    out->waves = p->waves;

    int dmin = p->damageMin, dmax = p->damageMax;
    if (dmin > dmax) { int t = dmin; dmin = dmax; dmax = t; }
    if (dmin < 1) dmin = 1;

    for (int i = 0; i < totalRounds; i++) {
        int dmg;
        switch (p->mode) {
            case 1:  dmg = p->damageFixed; break;
            default: {
                uint32_t span = (uint32_t)(dmax - dmin);
                dmg = dmin + (int)(span ? (next_rand() % span) : 0);
                break;
            }
        }
        // 区间模式本身已随机；固定/自定义模式再叠一层抖动，避免"每回合一模一样"
        if (p->mode != 0) dmg = jitter(dmg, p->jitterPercent);

        int combos = jitter(p->combosPerRound, p->jitterPercent);
        int steps  = jitter(p->stepsPerRound, p->jitterPercent);

        out->perRoundDamage[i] = dmg;
        out->perRoundCombos[i] = combos;
        out->perRoundSteps[i]  = steps;

        out->damage += dmg;
        out->combos += combos;
        out->steps  += steps;
    }
    out->rounds = totalRounds;

    // 耗时：优先按目标总秒数反推，否则按回合时间自然累加
    if (p->targetSeconds > 0) {
        out->seconds = p->targetSeconds;
    } else {
        out->seconds = totalRounds * p->roundSeconds + (p->waves - 1) * p->waveSwitchSeconds;
    }
    return 1;
}

// ============================================================================
// 4. 下发到游戏结算
//
//  两种落地方式：
//
//  A) 直接构造结算对象（推荐，最干净）
//     找 BattleResult / SettlementData 这类类，按字段顺序塞值，再 invoke 结算流程：
//         SettlementData d;
//         d.damage = report.damage; d.rounds = report.rounds; ...
//         runtime_invoke(BattleManager::Settle, instance, &d, &exc)
//     优点：不进战斗循环，一次成型。
//
//  B) hook 上报前的构造点（兼容性更好）
//     用 MSHookFunction 挂住"组装 battle record"的函数，
//     在 orig 调用前把它的参数改成本报告的数值。
//     优点：不用知道对象布局，缺点：需要找到那个函数。
//
//  下面给 A 的骨架；B 的锚点用 XG_SETTLE_HOOK_SYMBOL 指定（dlsym 找函数）。
// ============================================================================

int XGSettlementApply(const XGSettleReport *r) {
    if (!r) return 0;
    STBind();

    // ---- 方式 B：优先走"构造点替换"，需要 XG_SETTLE_HOOK_SYMBOL 非空 ----
    if (XG_SETTLE_HOOK_SYMBOL[0] != '\0') {
        void *fn = dlsym(RTLD_SELF, XG_SETTLE_HOOK_SYMBOL);
        if (!fn) fn = dlsym(RTLD_DEFAULT, XG_SETTLE_HOOK_SYMBOL);
        if (fn) {
            // 约定：void fn(int64_t damage, int rounds, int combos, int steps, int seconds)
            typedef void (*ApplyFn)(int64_t, int, int, int, int);
            ((ApplyFn)fn)(r->damage, r->rounds, r->combos, r->steps, r->seconds);
            NSLog(@"[XG-ST] applied via %s", XG_SETTLE_HOOK_SYMBOL);
            return 1;
        }
        NSLog(@"[XG-ST] hook symbol not found: %s", XG_SETTLE_HOOK_SYMBOL);
    }

    // ---- 方式 A：走 il2cpp 结算方法 ----
    if (!g_stReady) return 0;

    Il2CppClass *cls = XGI2Class(XG_SETTLE_CLASS);   // 按类名遍历查找，不依赖 namespace
    if (!cls) { NSLog(@"[XG-ST] class missing: %s", XG_SETTLE_CLASS); return 0; }

    // 拿单例（如果结算类挂在 manager 上）
    void *instance = NULL;
    const MethodInfo *inst = st_method_from_name(cls, "get_Instance", 0);
    if (inst) instance = st_runtime_invoke(inst, NULL, NULL, NULL);

    const MethodInfo *m = st_method_from_name(cls, XG_SETTLE_METHOD, XG_SETTLE_ARGC);
    if (!m) { NSLog(@"[XG-ST] method missing: %s/%d", XG_SETTLE_METHOD, XG_SETTLE_ARGC); return 0; }

    // 参数按 (long damage, int rounds, int combos, int steps, int seconds) 传。
    // 若目标的结算方法签名不同，改这里的 params 打包顺序即可。
    int64_t a0 = r->damage;
    int32_t a1 = r->rounds, a2 = r->combos, a3 = r->steps, a4 = r->seconds;
    void *params[5] = { &a0, &a1, &a2, &a3, &a4 };

    void *exc = NULL;
    st_runtime_invoke(m, instance, params, &exc);
    if (exc) { NSLog(@"[XG-ST] settle invoke raised"); return 0; }

    NSLog(@"[XG-ST] applied via il2cpp: damage=%lld rounds=%d", (long long)r->damage, r->rounds);
    return 1;
}

// ============================================================================
// 5. 摘要
// ============================================================================
NSString *XGSettlementDescribe(const XGSettleReport *r) {
    if (!r) return @"(空)";
    return [NSString stringWithFormat:
            @"%d 波 / %d 回合 / %d 连击 / %d 步 / %lld 伤害 / %d 秒",
            r->waves, r->rounds, r->combos, r->steps,
            (long long)r->damage, r->seconds];
}

void XGSettlementInstall(void) {
    STBind();
    NSLog(@"[XG-ST] installed il2cpp=%d settleClass=%s", g_stReady, XG_SETTLE_CLASS);
}
#include <time.h>
#include <unistd.h>

#ifndef PAGE_SIZE
#define PAGE_SIZE 4096UL   // iOS arm64；不依赖 <mach/vm_param.h>
#endif
