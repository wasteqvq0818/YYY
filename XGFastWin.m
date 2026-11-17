#import "XGFastWin.h"
#import "XGConfig.h"
#import "XGIl2Cpp.h"

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <string.h>

// ============================================================================
//  本模块自带一份 il2cpp 绑定（不依赖 TOSHooks.xm 的 static 符号）：
//  游戏一崩，独立模块更容易定位是哪一层出的问题；也方便单独调试档 3。
// ============================================================================

typedef struct Il2CppDomain Il2CppDomain;
typedef struct Il2CppClass Il2CppClass;
typedef struct MethodInfo MethodInfo;

static Il2CppDomain *(*fw_domain_get)(void);
static Il2CppClass  *(*fw_class_from_name)(const Il2CppDomain *, const char *, const char *);
static const MethodInfo *(*fw_method_from_name)(Il2CppClass *, const char *, int);
static const void *(*fw_field_offset)(Il2CppClass *, const char *);
static void         *(*fw_static_data)(Il2CppClass *);
static void         *(*fw_runtime_invoke)(const void *, void *, void **, void **);

static BOOL g_fwReady = NO;
static uintptr_t g_fwImageBase = 0;

static void FWBind(void) {
    if (g_fwReady) return;
    void *h = dlopen(NULL, RTLD_NOW);
    fw_domain_get      = (Il2CppDomain *(*)(void))dlsym(h, "il2cpp_domain_get");
    fw_class_from_name = (Il2CppClass *(*)(const Il2CppDomain *, const char *, const char *))dlsym(h, "il2cpp_class_from_name");
    fw_method_from_name= (const MethodInfo *(*)(Il2CppClass *, const char *, int))dlsym(h, "il2cpp_class_get_method_from_name");
    fw_field_offset    = (const void *(*)(Il2CppClass *, const char *))dlsym(h, "il2cpp_field_get_offset");
    fw_static_data     = (void *(*)(Il2CppClass *))dlsym(h, "il2cpp_class_get_static_field_data");
    fw_runtime_invoke  = (void *(*)(const void *, void *, void **, void **))dlsym(h, "il2cpp_runtime_invoke");
    g_fwReady = fw_domain_get && fw_class_from_name && fw_method_from_name;
    if (!g_fwReady) NSLog(@"[XG-FW] il2cpp 符号缺失，快速胜利不可用");
}

// ---------------- 内存 ----------------

static uintptr_t FWImageBase(void) {
    if (g_fwImageBase) return g_fwImageBase;
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *nm = _dyld_get_image_name(i);
        if (nm && strstr(nm, "UnityFramework")) {
            g_fwImageBase = (uintptr_t)_dyld_get_image_header(i);
            return g_fwImageBase;
        }
    }
    return 0;
}

static BOOL FWRead(uintptr_t addr, void *out, size_t len) {
    if (!addr || !out) return NO;
    vm_size_t got = 0;
    return vm_read_overwrite(mach_task_self(), (vm_address_t)addr,
                                  (vm_size_t)len,
                                  (vm_address_t)out, &got) == KERN_SUCCESS;
}

static uintptr_t FWPtr(uintptr_t addr) {
    uintptr_t v = 0;
    FWRead(addr, &v, sizeof(v));
    return v;
}

static int32_t FWI32(uintptr_t addr) {
    int32_t v = 0;
    FWRead(addr, &v, sizeof(v));
    return v;
}

static BOOL FWWrite(uintptr_t addr, const void *data, size_t len) {
    if (!addr || !data) return NO;
    uintptr_t page = addr & ~(uintptr_t)(PAGE_SIZE - 1);
    vm_protect(mach_task_self(), (vm_address_t)page, PAGE_SIZE,
               FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    return vm_write(mach_task_self(), (vm_address_t)addr,
                         (vm_offset_t)data, (mach_msg_type_number_t)len) == KERN_SUCCESS;
}

static void FWWriteI32(uintptr_t addr, int32_t v) { FWWrite(addr, &v, sizeof(v)); }
static void FWWriteI8(uintptr_t addr, int8_t v)   { FWWrite(addr, &v, sizeof(v)); }

// ============================================================================
//  档 2：一击清场
//  敌人列表布局（Unity List<T>，64 位）：
//      +0x10 → Il2CppArray(items)   +0x18 → int32 size
//      items+0x20 → 元素指针数组
//  清零 HP + 存活标志后，游戏自身的"全灭判定"会走正常胜利 + 正常结算上传，
//  这是检测面最小的一条路。
// ============================================================================
int XGFastWinKillAll(void) {
    // 清场逻辑已迁移到 TOSHooks.mm 的 XGKillAllEnemies()
    // 那边走的是实测链路 WaveData._enemies → EnemyData.currentHP
    return 0;
}

// ============================================================================
//  档 3：直接调胜利流程
//  BattleManager::Instance 是静态属性 → 先 runtime_invoke get_Instance 拿对象，
//  再 invoke Win / OnStageClear。这条链和"结算 + 上报"在同一流程上，
//  比改状态机 state 更接近真实通关。
// ============================================================================
int XGFastWinForce(void) {
    FWBind();
    if (!g_fwReady) return 0;

    Il2CppClass *cls = XGI2Class(XG_FASTWIN_CLASS);   // 按类名遍历查找，不依赖 namespace
    if (!cls) { NSLog(@"[XG-FW] class missing: %s", XG_FASTWIN_CLASS); return 0; }

    void *instance = NULL;
    if (XG_FASTWIN_USE_INSTANCE) {
        const MethodInfo *getter = fw_method_from_name(cls, "get_Instance", 0);
        if (getter) instance = fw_runtime_invoke(getter, NULL, NULL, NULL);
        if (!instance) { NSLog(@"[XG-FW] Instance 为 nil（可能不在战斗中）"); return 0; }
    }

    const MethodInfo *win = fw_method_from_name(cls, XG_FASTWIN_WIN_METHOD, XG_FASTWIN_WIN_ARGC);
    if (!win) {
        NSLog(@"[XG-FW] method missing: %s/%d", XG_FASTWIN_WIN_METHOD, XG_FASTWIN_WIN_ARGC);
        return 0;
    }

    void *params[1] = { NULL };
    BOOL argTrue = YES;
    if (XG_FASTWIN_WIN_ARGC >= 1) params[0] = &argTrue;

    void *exc = NULL;
    fw_runtime_invoke(win, instance, params, &exc);
    if (exc) { NSLog(@"[XG-FW] 胜利方法抛异常（参数类型不符？）"); return 0; }

    NSLog(@"[XG-FW] forced win");
    return 1;
}

// ============================================================================
//  档 1：战斗倍速
//  UnityEngine.Time.timeScale 是静态 float，直接写静态字段区。
//  比 hook get_timeScale 稳（那是 icall，没有托管方法体可 hook）。
// ============================================================================
void XGFastWinSetSpeed(float mult) {
    FWBind();
    if (!g_fwReady || !fw_static_data) return;

    Il2CppClass *t = XGI2Class("Time");   // 按类名遍历查找，避免 class_from_name 的 Image/Domain 参数坑
    if (!t) return;
    void *sd = fw_static_data(t);
    if (!sd) return;

    uint32_t off = XGI2FieldOffOfClass((void *)t, "timeScale");
    if (!off) { NSLog(@"[XG-FW] timeScale 偏移没取到"); return; }
    if (mult < 0.1f) mult = 0.1f;
    if (mult > 20.0f) mult = 20.0f;
    FWWrite((uintptr_t)sd + off, &mult, sizeof(mult));
}

// ---------------- 状态串（面板显示用） ----------------
NSString *XGFastWinStatus(void) {
    uintptr_t base = FWImageBase();
    uintptr_t battle = base ? FWPtr(base + XG_BATTLE_ROOT_PTR_OFF) : 0;
    uintptr_t list = battle ? FWPtr(battle + XG_OFF_ENEMY_LIST) : 0;
    int32_t n = list ? FWI32(list + 0x18) : 0;
    return [NSString stringWithFormat:@"battle=0x%lx list=0x%lx enemies=%d",
            (unsigned long)battle, (unsigned long)list, n];
}

void XGFastWinInstall(void) {
    FWBind();
    NSLog(@"[XG-FW] installed il2cpp=%d", g_fwReady);
}

#ifndef PAGE_SIZE
#define PAGE_SIZE 4096UL   // iOS arm64；不依赖 <mach/vm_param.h>
#endif
