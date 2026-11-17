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

// 血量是 int64（游戏里敌人血量 5000 亿 = 5e11，远超 int32 上限）
static int64_t R64(uintptr_t a) { int64_t v = 0; SafeRead(a, &v, 8); return v; }
static void    W64(uintptr_t a, int64_t v) { SafeWrite(a, &v, 8); }

#define HP_MAX_INT64  1000000000000000LL   // 1000 万亿，覆盖任何血量

static void    W32(uintptr_t a, int32_t v) { SafeWrite(a, &v, 4); }

// ---- 状态 ----
static volatile int g_state = 0;     // 0空闲 1扫描中 2完成 3失败
static volatile int g_nData = 0, g_nInst = 0, g_killed = 0;
static volatile int g_okBlocks = 0, g_totalBlocks = 0;
static char g_msg[320] = "未扫描";

typedef struct { uintptr_t addr; int64_t hp; int isInst; } Sample;
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
        snprintf(t, sizeof(t), "%s 0x%lx hp=%lld\n",
                 g_samples[i].isInst ? "I" : "D",
                 (unsigned long)g_samples[i].addr, (long long)g_samples[i].hp);
        strncat(b, t, sizeof(b) - strlen(b) - 1);
    }
    return b;
}

// ---- 扫描参数（保守）----
#define CHUNK        (64 * 1024)
#define SCAN_START   0x100000000ULL       // 4GB 起（iOS 堆一般在上面）
#define SCAN_END     0x500000000ULL       // 20GB 止
#define TIME_BUDGET  15.0


// ============================================================================
//  对象内存 dump —— 把对象原始字节写到文件，人工判断真实字段位置
//  （探测出来的 offset 有重复，说明静态/实例字段混在一起，不能直接信）
// ============================================================================
static void XGDumpObject(uintptr_t obj, int isInst, int idx) {
    static FILE *df = NULL;
    static int inited = 0;
    if (!inited) {
        inited = 1;
        NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        NSArray *cands = @[@"/var/mobile/Documents/XG_dump.txt",
                           docs ? [docs stringByAppendingPathComponent:@"XG_dump.txt"] : @"/tmp/XG_dump.txt",
                           [NSTemporaryDirectory() stringByAppendingPathComponent:@"XG_dump.txt"]];
        for (NSString *pth in cands) {
            [[NSFileManager defaultManager] createDirectoryAtPath:[pth stringByDeletingLastPathComponent]
                                      withIntermediateDirectories:YES attributes:nil error:nil];
            df = fopen(pth.UTF8String, "a");
            if (df) { NSLog(@"[XG] dump -> %@", pth); break; }
        }
        if (df) {
            fprintf(df, "\n\n===== XiuGou 对象 dump %s =====\n", [[NSDate date] description].UTF8String);
        }
    }
    if (!df) return;

    uint8_t raw[0x100];
    memset(raw, 0, sizeof(raw));
    if (!SafeRead(obj, raw, sizeof(raw))) {
        fprintf(df, "\n[%s #%d] 0x%lx 读取失败\n", isInst ? "Inst" : "Data", idx, (unsigned long)obj);
        return;
    }

    fprintf(df, "\n[%s #%d] 0x%lx\n", isInst ? "Inst" : "Data", idx, (unsigned long)obj);
    for (int r = 0; r < 0x100; r += 16) {
        fprintf(df, "  +0x%02x: ", r);
        for (int c = 0; c < 16; c++) fprintf(df, "%02x ", raw[r + c]);
        fprintf(df, " | i32: ");
        for (int c = 0; c < 16; c += 4) {
            int32_t v;
            memcpy(&v, raw + r + c, 4);
            fprintf(df, "%d ", v);
        }
        fprintf(df, "\n");
    }
    fflush(df);
}

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

            // 诊断：dump 前 3 个对象的内存（0x80 字节），供人工判断真实字段
            if (isData && nData <= 3) XGDumpObject(o, 0, nData);
            if (isInst && nInst <= 3) XGDumpObject(o, 1, nInst);

            if (isData) {
                int32_t dead = R32(o + XG_OFF_ENEMY_DEAD);

                // 两套布局都按 int64 试（血量 5000 亿 = 0x74_6A528000，必须 8 字节）
                // 0x24：6 字段版，按 int32（地址非 8 字节对齐，不按 int64 读免得误伤）
                int32_t hpA32 = R32(o + XG_OFF_ENEMY_HP_SIMPLE);
                BOOL okA = (hpA32 > 0 && hpA32 < 2000000000);

                // 0x38：42 字段版，按 int64（5000 亿血量走这套布局）
                int64_t hpB = R64(o + XG_OFF_ENEMY_HP_FULL);
                BOOL okB = (hpB > 0 && hpB < HP_MAX_INT64);

                if (g_sampleN < 6 && (okA || okB)) {
                    g_samples[g_sampleN++] = (Sample){ o, okB ? hpB : (int64_t)hpA32, 0 };
                }
                if (okA) { W32(o + XG_OFF_ENEMY_HP_SIMPLE, 0); killed++; }
                if (okB) { W64(o + XG_OFF_ENEMY_HP_FULL,   0); killed++; }
                if (dead == 0 && (okA || okB)) W32(o + XG_OFF_ENEMY_DEAD, 1);
            } else {
                int64_t php = R64(o + XG_OFF_EI_PREDICT_HP);     // predictHP 也是 int64
                int32_t dead = R32(o + XG_OFF_EI_DEAD);
                BOOL okP = (php > 0 && php < HP_MAX_INT64);

                if (g_sampleN < 6 && okP) {
                    g_samples[g_sampleN++] = (Sample){ o, php, 1 };
                }
                // 先关掉「打不死」的开关
                W32(o + XG_OFF_EI_PREVENT_KILL, 0);
                W32(o + XG_OFF_EI_CANNOT_DIE, 0);
                if (okP) { W64(o + XG_OFF_EI_PREDICT_HP, 0); killed++; }
                if (dead == 0) { W32(o + XG_OFF_EI_DEAD, 1); killed++; }
            }
        }
    }

    free(buf);
    g_nData = nData; g_nInst = nInst; g_killed = killed;
    g_okBlocks = okBlocks; g_totalBlocks = totalBlocks;
    g_state = 2;

    snprintf(g_msg, sizeof(g_msg),
             "块 %d/%d｜Data %d｜Inst %d｜改动 %d\n样本已 dump 到 Documents/XG_dump.txt",
             okBlocks, totalBlocks, nData, nInst, killed);
    NSLog(@"[XG] %s", g_msg);
    for (int i = 0; i < g_sampleN; i++) {
        NSLog(@"[XG] 样本%d %s @0x%lx hp=%lld", i,
              g_samples[i].isInst ? "Inst" : "Data",
              (unsigned long)g_samples[i].addr, (long long)g_samples[i].hp);
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

// 方法名扫描（找游戏自己的胜利/结算/死亡函数）
void XGScanMethodsAsync(void) {
    snprintf(g_msg, sizeof(g_msg), "扫描方法名中…（约 20~60 秒）");
    g_state = 1;
    dispatch_async(dispatch_get_main_queue(), ^{
        // il2cpp 遍历必须在主线程
        if (!XGI2Init()) { snprintf(g_msg, sizeof(g_msg), "il2cpp 未就绪"); g_state = 3; return; }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            @autoreleasepool {
                int n = XGI2ProbeMethods(NULL);
                snprintf(g_msg, sizeof(g_msg),
                         n > 0 ? "方法扫描完成，命中 %d 个 → Documents/XG_methods.txt"
                               : "方法扫描完成，没命中，检查关键词",
                         n);
                g_state = 2;
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


// ============================================================================
//  调用式实现（学 XiuGou：不写内存，直接调用游戏自己的方法）
//
//  依据 XG_methods.txt 实测：
//    EnemyInstance.Die 有两个重载（argc 0 / 1）
//    Labyrinth.Victory / Victory2 / CheckEndBattleZone / GameOver 构成完整战斗流程
// ============================================================================
static char g_callMsg[256] = "未调用";
const char *XGLastCallResult(void) { return g_callMsg; }

// 收集场上 EnemyInstance 实例地址（最多 64 个）
#define MAX_INST 64
static int CollectInstances(void *kInst, uintptr_t *out, int maxN) {
    if (!kInst || !out) return 0;
    uint8_t *buf = (uint8_t *)malloc(CHUNK);
    if (!buf) return 0;

    int n = 0;
    CFTimeInterval t0 = CFAbsoluteTimeGetCurrent();

    for (uintptr_t p = SCAN_START; p + CHUNK < SCAN_END && n < maxN; p += CHUNK) {
        if (CFAbsoluteTimeGetCurrent() - t0 > TIME_BUDGET) break;
        vm_size_t got = 0;
        if (vm_read_overwrite(mach_task_self(), (vm_address_t)p, (vm_size_t)CHUNK,
                              (vm_address_t)buf, &got) != KERN_SUCCESS || got < 0x100) continue;
        for (size_t off = 0; off + 0x100 < (size_t)got && n < maxN; off += 8) {
            if (*(void **)(buf + off) == kInst) out[n++] = p + off;
        }
    }
    free(buf);
    return n;
}

// ---- 方案 A：对每个 EnemyInstance 调 Die() ----
void XGCallDieAsync(void) {
    if (g_state == 1) return;
    g_state = 1;
    snprintf(g_msg, sizeof(g_msg), "调用 Die 中…");

    dispatch_async(dispatch_get_main_queue(), ^{
        if (!XGI2Init()) { snprintf(g_msg, sizeof(g_msg), "il2cpp 未就绪"); g_state = 3; return; }
        void *kInst = XGI2Class(XG_ENEMY_INSTANCE_CLASS);
        void *mDie0 = XGI2Method(XG_ENEMY_INSTANCE_CLASS, XG_DIE_METHOD, 0);
        void *mDie1 = XGI2Method(XG_ENEMY_INSTANCE_CLASS, XG_DIE_METHOD, 1);
        NSLog(@"[XG] klass=%p Die/0=%p Die/1=%p", kInst, mDie0, mDie1);

        if (!kInst || (!mDie0 && !mDie1)) {
            snprintf(g_msg, sizeof(g_msg), "Die 方法没找到（klass=%p m0=%p m1=%p）", kInst, mDie0, mDie1);
            g_state = 3;
            return;
        }

        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            static uintptr_t insts[MAX_INST];
            int n = CollectInstances(kInst, insts, MAX_INST);

            dispatch_async(dispatch_get_main_queue(), ^{
                int ok = 0, fail = 0;
                for (int i = 0; i < n; i++) {
                    void *exc = NULL;
                    void *arg = (void *)1;          // 有些 Die(bool) 需要参数
                    void **params = mDie1 ? (void *[]){ &arg } : NULL;
                    void *m = mDie1 ? mDie1 : mDie0;
                    XGI2Invoke(m, (void *)insts[i], params, &exc);
                    if (exc) fail++; else ok++;
                }
                snprintf(g_msg, sizeof(g_msg), "找到 %d 个敌人，Die 成功 %d / 失败 %d", n, ok, fail);
                snprintf(g_callMsg, sizeof(g_callMsg), "%s", g_msg);
                g_state = 2;
            });
        });
    });
}

// ---- 方案 B：直接调 Labyrinth.Victory() ----
void XGForceVictoryAsync(void) {
    if (g_state == 1) return;
    g_state = 1;
    snprintf(g_msg, sizeof(g_msg), "调用 Victory 中…");

    dispatch_async(dispatch_get_main_queue(), ^{
        if (!XGI2Init()) { snprintf(g_msg, sizeof(g_msg), "il2cpp 未就绪"); g_state = 3; return; }

        void *inst = XGI2GetInstanceMulti(XG_BATTLE_CTRL_CLASS);
        void *mV = XGI2Method(XG_BATTLE_CTRL_CLASS, XG_VICTORY_METHOD, 0);
        void *mV2 = XGI2Method(XG_BATTLE_CTRL_CLASS, XG_VICTORY2_METHOD, 0);
        NSLog(@"[XG] Labyrinth inst=%p Victory=%p Victory2=%p", inst, mV, mV2);

        if (!inst) {
            snprintf(g_msg, sizeof(g_msg), "拿不到 Labyrinth 实例（可能不在战斗中）");
            g_state = 3;
            return;
        }
        void *m = mV ? mV : mV2;
        if (!m) {
            snprintf(g_msg, sizeof(g_msg), "Victory 方法没找到");
            g_state = 3;
            return;
        }
        void *exc = NULL;
        XGI2Invoke(m, inst, NULL, &exc);
        if (exc) {
            snprintf(g_msg, sizeof(g_msg), "Victory 调用抛异常");
            g_state = 3;
        } else {
            snprintf(g_msg, sizeof(g_msg), "已调用 %s.Victory()", XG_BATTLE_CTRL_CLASS);
            g_state = 2;
        }
        snprintf(g_callMsg, sizeof(g_callMsg), "%s", g_msg);
    });
}


// ============================================================================
//  血量归零 Hook（v15 · 学 XiuGou 的思路，但不写游戏数据）
//
//  原理：IL2CPP 的 MethodInfo 首字段就是函数指针。
//        把它改成我们的函数 = 完成 hook，不用改代码段、不用可执行内存、
//        不用处理 ARM64 指令重定位。原函数完好，照常转调。
//
//  目标（来自 XG_methods.txt 实测）：
//    EnemyData.set_mCurrentHP @ 0x115b9670c
//    EnemyData.set_mMaxHP     @ 0x115b966f8
//
//  效果：游戏每次给敌人设血量（含初始化），都被改成 0 → 敌人立刻死。
//        走的是游戏自己的流程，不存在「改了数据但不生效」的问题。
// ============================================================================

static void   *g_miCurHP = NULL;      // MethodInfo*
static void   *g_miMaxHP = NULL;
static void   *g_origCurHP = NULL;    // 原始函数指针
static void   *g_origMaxHP = NULL;
static int     g_hpHookOn = 0;

int XGHPHookInstalled(void) { return g_hpHookOn; }

// set_mCurrentHP(int64 value) —— arm64 传参 x0=this, x1=value
static void my_setCurrentHP(void *self, int64_t value) {
    if (g_origCurHP) {
        ((void (*)(void *, int64_t))g_origCurHP)(self, 0);   // 一律设成 0
    }
}

// set_mMaxHP(int64 value)
static void my_setMaxHP(void *self, int64_t value) {
    if (g_origMaxHP) {
        ((void (*)(void *, int64_t))g_origMaxHP)(self, 1);   // 最大值设成 1（保险）
    }
}

int XGInstallHPHook(void) {
    if (g_hpHookOn) return 1;
    if (!XGI2Init()) { snprintf(g_callMsg, sizeof(g_callMsg), "il2cpp 未就绪"); return 0; }

    g_miCurHP = XGI2MethodInfo(XG_ENEMY_CLASS, "set_mCurrentHP", 1);
    g_miMaxHP = XGI2MethodInfo(XG_ENEMY_CLASS, "set_mMaxHP", 1);
    NSLog(@"[XG] MethodInfo: set_mCurrentHP=%p set_mMaxHP=%p", g_miCurHP, g_miMaxHP);

    if (!g_miCurHP && !g_miMaxHP) {
        snprintf(g_callMsg, sizeof(g_callMsg), "两个 setter 都没找到");
        return 0;
    }

    int n = 0;
    if (g_miCurHP) {
        void **slot = (void **)g_miCurHP;          // 首字段 = methodPointer
        g_origCurHP = *slot;
        void *repl = (void *)my_setCurrentHP;
        if (SafeWrite((uintptr_t)slot, &repl, sizeof(repl))) n++;
        else NSLog(@"[XG] set_mCurrentHP 写入失败");
    }
    if (g_miMaxHP) {
        void **slot = (void **)g_miMaxHP;
        g_origMaxHP = *slot;
        void *repl = (void *)my_setMaxHP;
        if (SafeWrite((uintptr_t)slot, &repl, sizeof(repl))) n++;
        else NSLog(@"[XG] set_mMaxHP 写入失败");
    }

    g_hpHookOn = (n > 0);
    snprintf(g_callMsg, sizeof(g_callMsg),
             g_hpHookOn ? "Hook 已装：%d 个 setter（进战斗后敌人血量恒为 0）"
                        : "Hook 安装失败");
    NSLog(@"[XG] %s (origCur=%p origMax=%p)", g_callMsg, g_origCurHP, g_origMaxHP);
    return g_hpHookOn;
}

void XGRemoveHPHook(void) {
    if (!g_hpHookOn) return;
    if (g_miCurHP && g_origCurHP) SafeWrite((uintptr_t)g_miCurHP, &g_origCurHP, 8);
    if (g_miMaxHP && g_origMaxHP) SafeWrite((uintptr_t)g_miMaxHP, &g_origMaxHP, 8);
    g_hpHookOn = 0;
    snprintf(g_callMsg, sizeof(g_callMsg), "Hook 已卸载");
    NSLog(@"[XG] Hook 已卸载");
}


// ============================================================================
//  v16：加调用计数 + hook 死亡判定
//
//  v15 只 hook 了 set_mCurrentHP，装上了但没效果。两种可能必须区分：
//    A. 该 setter 根本没被调用（游戏内部直接写 _mCurrentHP 字段，绕过属性）
//    B. 调用了但值被别处覆盖
//  所以每个 hook 都加计数器，面板直接显示调用次数。
//
//  同时新增更彻底的 hook：
//    EnemyInstance.get_isDead  返回 true  → 任何 if(isDead) 都成立
//    EnemyInstance.CheckDie    返回 true  → 死亡判定永远通过
// ============================================================================

static volatile int g_cntCurHP = 0;
static volatile int g_cntMaxHP = 0;
static volatile int g_cntIsDead = 0;
static volatile int g_cntCheckDie = 0;

static void *g_miIsDead = NULL,   *g_origIsDead = NULL;
static void *g_miCheckDie = NULL, *g_origCheckDie = NULL;
static int   g_deadHookOn = 0;

// ---- 计数版 HP setter ----
static void my2_setCurrentHP(void *self, int64_t value) {
    g_cntCurHP++;
    if (g_origCurHP) ((void (*)(void *, int64_t))g_origCurHP)(self, 0);
}
static void my2_setMaxHP(void *self, int64_t value) {
    g_cntMaxHP++;
    if (g_origMaxHP) ((void (*)(void *, int64_t))g_origMaxHP)(self, 1);
}

// ---- get_isDead：永远 true ----
// IL2CPP 的 bool 返回走 w0（低字节）
static uint8_t my_get_isDead(void *self) {
    g_cntIsDead++;
    return 1;
}

// ---- CheckDie：永远 true ----
static uint8_t my_CheckDie(void *self) {
    g_cntCheckDie++;
    return 1;
}

int XGDeadHookInstalled(void) { return g_deadHookOn; }
int XGCntCurHP(void)    { return g_cntCurHP; }
int XGCntMaxHP(void)    { return g_cntMaxHP; }
int XGCntIsDead(void)   { return g_cntIsDead; }
int XGCntCheckDie(void) { return g_cntCheckDie; }

void XGResetCounters(void) {
    g_cntCurHP = g_cntMaxHP = g_cntIsDead = g_cntCheckDie = 0;
}

static int hookOne(void *mi, void *repl, void **origOut) {
    if (!mi) return 0;
    void **slot = (void **)mi;
    if (origOut && !*origOut) *origOut = *slot;
    void *r = repl;
    return SafeWrite((uintptr_t)slot, &r, sizeof(r)) ? 1 : 0;
}

// 装全套 hook：HP setter（计数版）+ isDead + CheckDie
int XGInstallDeadHook(void) {
    if (!XGI2Init()) { snprintf(g_callMsg, sizeof(g_callMsg), "il2cpp 未就绪"); return 0; }

    int n = 0;
    // 1. HP setter 换成计数版
    if (g_miCurHP) n += hookOne(g_miCurHP, (void *)my2_setCurrentHP, &g_origCurHP);
    if (g_miMaxHP) n += hookOne(g_miMaxHP, (void *)my2_setMaxHP,     &g_origMaxHP);

    // 2. isDead / CheckDie
    g_miIsDead   = XGI2MethodInfo(XG_ENEMY_INSTANCE_CLASS, "get_isDead", 0);
    g_miCheckDie = XGI2MethodInfo(XG_ENEMY_INSTANCE_CLASS, "CheckDie", 0);
    NSLog(@"[XG] mi isDead=%p CheckDie=%p", g_miIsDead, g_miCheckDie);
    if (g_miIsDead)   n += hookOne(g_miIsDead,   (void *)my_get_isDead, &g_origIsDead);
    if (g_miCheckDie) n += hookOne(g_miCheckDie, (void *)my_CheckDie,   &g_origCheckDie);

    g_deadHookOn = (n > 0);
    snprintf(g_callMsg, sizeof(g_callMsg), "装了 %d 个 hook（进战斗看计数）", n);
    NSLog(@"[XG] %s", g_callMsg);
    return n;
}

void XGRemoveDeadHook(void) {
    if (g_miCurHP && g_origCurHP)         SafeWrite((uintptr_t)g_miCurHP, &g_origCurHP, 8);
    if (g_miMaxHP && g_origMaxHP)         SafeWrite((uintptr_t)g_miMaxHP, &g_origMaxHP, 8);
    if (g_miIsDead && g_origIsDead)       SafeWrite((uintptr_t)g_miIsDead, &g_origIsDead, 8);
    if (g_miCheckDie && g_origCheckDie)   SafeWrite((uintptr_t)g_miCheckDie, &g_origCheckDie, 8);
    g_deadHookOn = 0;
    snprintf(g_callMsg, sizeof(g_callMsg), "hook 已卸载");
}
