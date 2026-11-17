#import "XGIl2Cpp.h"

#include <dlfcn.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <stdarg.h>
#include <time.h>
#include <unistd.h>
#include <mach-o/dyld.h>

// ============================================================================
//  IL2CPP 导航层
//
//  ⚠️ 签名必须与 IL2CPP 官方头一致，否则 C 调用约定下会读到垃圾指针直接 SIGSEGV。
//     本文件曾经踩过两个坑（已修）：
//       1. il2cpp_field_get_offset(FieldInfo*)           —— 只吃一个参数，
//          原来写成 (klass, name)，等于把 klass 当 FieldInfo 解引用。
//       2. il2cpp_class_from_name(Il2CppImage*, ns, name) —— 第一个参数是 Image 不是 Domain。
//          本文件干脆不用它：遍历全部 image 的类按名字比对，跨版本更稳。
//
//  另外：il2cpp 的 image/class 遍历相关导出在不同版本里名字略有差异，
//  所有可选符号都做非空检查，缺失就降级而不是崩。
// ============================================================================

typedef struct Il2CppDomain  Il2CppDomain;
typedef struct Il2CppAssembly Il2CppAssembly;
typedef struct Il2CppImage   Il2CppImage;
typedef struct Il2CppClass   Il2CppClass;
typedef struct FieldInfo     FieldInfo;
typedef struct MethodInfo    MethodInfo;

static Il2CppDomain  *(*p_domain_get)(void);
static const Il2CppAssembly **(*p_domain_get_assemblies)(const Il2CppDomain *, size_t *);
static Il2CppImage   *(*p_assembly_get_image)(const Il2CppAssembly *);
static Il2CppImage   *(*p_class_get_image)(Il2CppClass *);
static Il2CppClass   *(*p_image_get_class)(const Il2CppImage *, size_t);
static size_t         (*p_image_get_class_count)(const Il2CppImage *);
static const char    *(*p_class_get_name)(Il2CppClass *);
static const char    *(*p_class_get_namespace)(Il2CppClass *);
static const MethodInfo *(*p_class_get_method_from_name)(Il2CppClass *, const char *, int);
static FieldInfo     *(*p_class_get_fields)(Il2CppClass *, void **);
static const char    *(*p_field_get_name)(FieldInfo *);
static size_t         (*p_field_get_offset)(FieldInfo *);      // ★ 单参数
static uint32_t       (*p_method_get_param_count)(const MethodInfo *);
static void          *(*p_runtime_invoke)(const void *, void *, void **, void **);

static bool g_ready = false;
static char g_err[256];

const char *XGI2LastError(void) { return g_err; }

bool XGI2Init(void) {
    if (g_ready) return true;
    void *h = dlopen(NULL, RTLD_NOW);
    if (!h) h = dlopen("/usr/lib/libSystem.B.dylib", RTLD_NOW);

    p_domain_get              = (Il2CppDomain *(*)(void))dlsym(h, "il2cpp_domain_get");
    p_domain_get_assemblies   = (const Il2CppAssembly **(*)(const Il2CppDomain *, size_t *))
                                dlsym(h, "il2cpp_domain_get_assemblies");
    p_assembly_get_image      = (Il2CppImage *(*)(const Il2CppAssembly *))
                                dlsym(h, "il2cpp_assembly_get_image");
    p_class_get_image         = (Il2CppImage *(*)(Il2CppClass *))dlsym(h, "il2cpp_class_get_image");
    p_image_get_class         = (Il2CppClass *(*)(const Il2CppImage *, size_t))
                                dlsym(h, "il2cpp_image_get_class");
    p_image_get_class_count   = (size_t (*)(const Il2CppImage *))dlsym(h, "il2cpp_image_get_class_count");
    p_class_get_name          = (const char *(*)(Il2CppClass *))dlsym(h, "il2cpp_class_get_name");
    p_class_get_namespace     = (const char *(*)(Il2CppClass *))dlsym(h, "il2cpp_class_get_namespace");
    p_class_get_method_from_name = (const MethodInfo *(*)(Il2CppClass *, const char *, int))
                                dlsym(h, "il2cpp_class_get_method_from_name");
    p_class_get_fields        = (FieldInfo *(*)(Il2CppClass *, void **))dlsym(h, "il2cpp_class_get_fields");
    p_field_get_name          = (const char *(*)(FieldInfo *))dlsym(h, "il2cpp_field_get_name");
    p_field_get_offset        = (size_t (*)(FieldInfo *))dlsym(h, "il2cpp_field_get_offset");
    p_method_get_param_count  = (uint32_t (*)(const MethodInfo *))dlsym(h, "il2cpp_method_get_param_count");
    p_runtime_invoke          = (void *(*)(const void *, void *, void **, void **))
                                dlsym(h, "il2cpp_runtime_invoke");

    if (!p_domain_get || !p_class_get_name) {
        snprintf(g_err, sizeof(g_err), "il2cpp 符号缺失（不是 IL2CPP 进程？）");
        return false;
    }
    g_ready = true;
    NSLog(@"[XG-I2] ready: enum=%d fields=%d methods=%d invoke=%d",
          p_domain_get_assemblies && p_image_get_class,
          p_class_get_fields && p_field_get_offset,
          p_class_get_method_from_name != NULL,
          p_runtime_invoke != NULL);
    return true;
}

// ============================================================================
//  遍历：按类名找（不用 il2cpp_class_from_name，避免 namespace 和签名问题）
// ============================================================================
typedef void (*ClassVisitor)(Il2CppClass *k, const char *name, const char *ns, void *ctx);

static int walkClasses(ClassVisitor cb, void *ctx) {
    if (!XGI2Init()) return 0;
    if (!p_domain_get_assemblies || !p_assembly_get_image || !p_image_get_class) {
        snprintf(g_err, sizeof(g_err), "image 枚举 API 缺失");
        return 0;
    }
    size_t n = 0;
    const Il2CppAssembly **asms = p_domain_get_assemblies(p_domain_get(), &n);
    if (!asms) { snprintf(g_err, sizeof(g_err), "assemblies 为空"); return 0; }

    int total = 0;
    for (size_t a = 0; a < n; a++) {
        if (!asms[a]) continue;
        Il2CppImage *img = p_assembly_get_image(asms[a]);
        if (!img) continue;
        size_t cc = p_image_get_class_count ? p_image_get_class_count(img) : 0;
        for (size_t c = 0; c < cc; c++) {
            Il2CppClass *k = p_image_get_class(img, c);
            if (!k) continue;
            const char *nm = p_class_get_name(k);
            if (!nm) continue;
            const char *ns = p_class_get_namespace ? p_class_get_namespace(k) : "";
            total++;
            if (cb) cb(k, nm, ns ? ns : "", ctx);
        }
    }
    return total;
}

// ---- 按名找类（带缓存）----
#define CACHE_MAX 64
static struct { char name[80]; Il2CppClass *cls; } g_cache[CACHE_MAX];
static int g_cacheN = 0;

struct FindCtx { const char *want; Il2CppClass *found; };

static void findCb(Il2CppClass *k, const char *nm, const char *ns, void *ctx) {
    struct FindCtx *f = (struct FindCtx *)ctx;
    if (!f->found && strcmp(nm, f->want) == 0) f->found = k;
}

Il2CppClass *XGI2Class(const char *name) {
    if (!name || !*name) return NULL;
    for (int i = 0; i < g_cacheN; i++)
        if (strcmp(g_cache[i].name, name) == 0 && g_cache[i].cls) return g_cache[i].cls;

    struct FindCtx f = { name, NULL };
    walkClasses(findCb, &f);
    if (!f.found) {
        snprintf(g_err, sizeof(g_err), "class not found: %s", name);
        return NULL;
    }
    if (g_cacheN < CACHE_MAX) {
        strncpy(g_cache[g_cacheN].name, name, sizeof(g_cache[0].name) - 1);
        g_cache[g_cacheN].cls = f.found;
        g_cacheN++;
    }
    return f.found;
}

// ---- 按名找字段（FieldInfo*），offset 只认 FieldInfo* ----
FieldInfo *XGI2FindField(Il2CppClass *k, const char *field) {
    if (!k || !field || !p_class_get_fields || !p_field_get_name) return NULL;
    void *iter = NULL;
    for (int guard = 0; guard < 4000; guard++) {
        FieldInfo *f = p_class_get_fields(k, &iter);
        if (!f) break;
        const char *fn = p_field_get_name(f);
        if (fn && strcmp(fn, field) == 0) return f;
    }
    return NULL;
}

uint32_t XGI2FieldOff(const char *className, const char *field) {
    if (!XGI2Init() || !p_field_get_offset) return 0;
    Il2CppClass *k = XGI2Class(className);
    if (!k) return 0;
    FieldInfo *f = XGI2FindField(k, field);
    if (!f) return 0;
    return (uint32_t)p_field_get_offset(f);     // ★ 只传 FieldInfo*
}

// 给定已拿到的 Il2CppClass* 直接取字段偏移（静态字段也走这里，返回相对偏移）
uint32_t XGI2FieldOffOfClass(void *klass, const char *field) {
    if (!klass || !field || !p_field_get_offset) return 0;
    FieldInfo *f = XGI2FindField((Il2CppClass *)klass, field);
    if (!f) return 0;
    return (uint32_t)p_field_get_offset(f);
}

// ---- 方法入口 ----
void *XGI2Method(const char *className, const char *method, int argc) {
    if (!XGI2Init() || !p_class_get_method_from_name) return NULL;
    Il2CppClass *k = XGI2Class(className);
    if (!k) return NULL;
    const MethodInfo *m = p_class_get_method_from_name(k, method, argc);
    if (!m) {
        snprintf(g_err, sizeof(g_err), "method not found: %s::%s/%d", className, method);
        return NULL;
    }
    return *(void **)m;     // MethodInfo 首字段 = methodPointer
}

void *XGI2StaticData(const char *className) {
    // 静态字段在 il2cpp 里从 class 的 static field data 起步；这里保留接口，
    // 实际取偏移用 XGI2FieldOff（对静态字段返回的也是相对偏移）
    Il2CppClass *k = XGI2Class(className);
    return k ? (void *)k : NULL;
}

void *XGI2Invoke(void *methodInfo, void *obj, void **params, void **exc) {
    if (!XGI2Init() || !p_runtime_invoke || !methodInfo) return NULL;
    return p_runtime_invoke(methodInfo, obj, params, exc);
}

void *XGI2Instance(const char *className) {
    if (!XGI2Init() || !p_class_get_method_from_name || !p_runtime_invoke) return NULL;
    Il2CppClass *k = XGI2Class(className);
    if (!k) return NULL;
    const MethodInfo *g = p_class_get_method_from_name(k, "get_Instance", 0);
    if (!g) g = p_class_get_method_from_name(k, "get_instance", 0);
    if (!g) g = p_class_get_method_from_name(k, "Instance", 0);
    if (!g) { snprintf(g_err, sizeof(g_err), "no Instance on %s", className); return NULL; }
    return p_runtime_invoke(g, NULL, NULL, NULL);
}

// ============================================================================
//  分阶段探测 —— 每阶段落盘 + 独立标记
//
//  设计原因：上一版一次性 dump，一旦某个类上 API 崩掉，整个进程没了、
//  文件也没留下信息，无法定位。现在拆成 Phase A/B/C，每阶段结束立刻 fflush，
//  崩了也能从已有内容判断停在哪一步。
// ============================================================================

char XGProbePathBuf[512] = {0};
int  XGProbeBytes = 0;
int  XGProbeState = 0;   // 0=未跑 1=成功 2=失败

static FILE *g_pf = NULL;
static char  g_pfPath[512] = {0};

static void PLog(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    if (g_pf) { vfprintf(g_pf, fmt, ap); fputc('\n', g_pf); }
    va_end(ap);
}

static void PFlush(const char *mark) {
    if (!g_pf) return;
    PLog("[phase %s done]", mark);
    fflush(g_pf);
}

static const char *kKeep[] = {
    "Settle", "Battle", "Board", "Puzzle", "Enemy", "Monster",
    "WaveData", "StageData", "GemBoard", "Combo", "SkillCtrl",
    "PlayerData", "TeamData", "DeckData", NULL
};

static bool keepClass(const char *nm) {
    for (int i = 0; kKeep[i]; i++)
        if (strstr(nm, kKeep[i])) return true;
    return false;
}

// Phase A：只数 image / 类，不碰字段
static int phaseA(void) {
    if (!XGI2Init()) return -1;
    size_t n = 0;
    const Il2CppAssembly **asms = p_domain_get_assemblies
        ? p_domain_get_assemblies(p_domain_get(), &n) : NULL;
    PLog("assemblies=%zu ptr=%p", n, (void *)asms);
    if (!asms) return -1;

    int total = 0, images = 0;
    for (size_t a = 0; a < n; a++) {
        if (!asms[a]) continue;
        Il2CppImage *img = p_assembly_get_image ? p_assembly_get_image(asms[a]) : NULL;
        if (!img) continue;
        images++;
        size_t cc = p_image_get_class_count ? p_image_get_class_count(img) : 0;
        PLog("  image[%zu] classes=%zu", a, cc);
        total += (int)cc;
        if (a > 40) { PLog("  ... (只列前 40 个 image)"); break; }
    }
    PLog("images=%d total_classes=%d", images, total);
    return total;
}

// Phase B：只写类名（不取字段/方法）
struct NameCtx { int n; };
static void nameCb(Il2CppClass *k, const char *nm, const char *ns, void *ctx) {
    struct NameCtx *c = (struct NameCtx *)ctx;
    if (keepClass(nm)) {
        PLog("CLS %s.%s", ns, nm);
        c->n++;
    }
}
static int phaseB(void) {
    struct NameCtx c = { 0 };
    walkClasses(nameCb, &c);
    PLog("kept_classes=%d", c.n);
    return c.n;
}

// Phase C：对命中的类取字段/方法（上限保护）
struct DetailCtx { int classes; };
static void detailCb(Il2CppClass *k, const char *nm, const char *ns, void *ctx) {
    struct DetailCtx *c = (struct DetailCtx *)ctx;
    if (!keepClass(nm)) return;
    if (c->classes > 400) return;          // 最多详情 400 个类

    PLog("\n### %s.%s", ns, nm);
    c->classes++;

    if (p_class_get_fields && p_field_get_name && p_field_get_offset) {
        void *it = NULL;
        int nf = 0;
        while (nf < 40) {
            FieldInfo *f = p_class_get_fields(k, &it);
            if (!f) break;
            const char *fn = p_field_get_name(f);
            if (!fn) continue;
            size_t off = p_field_get_offset(f);   // ★ 单参数
            PLog("  F %-36s @0x%zx", fn, off);
            nf++;
        }
    }
    if (p_class_get_method_from_name) {
        // 方法遍历没有稳定 API，退而用命名知识：探几个常见名字
        static const char *common[] = {
            "DoSettleRounds", "Settle", "GetSettleResult", "OnStageClear",
            "Start", "Update", "Awake", "get_Instance", NULL
        };
        static const int argcs[] = { 0, 1, 2 };
        for (int i = 0; common[i]; i++) {
            for (int a = 0; a < 3; a++) {
                const MethodInfo *m = p_class_get_method_from_name(k, common[i], argcs[a]);
                if (m) { PLog("  M %-36s /%d  @ %p", common[i], argcs[a], *(void **)m); break; }
            }
        }
    }
}
static int phaseC(void) {
    struct DetailCtx c = { 0 };
    walkClasses(detailCb, &c);
    PLog("detail_classes=%d", c.classes);
    return c.classes;
}

int XGI2ProbeToFile(const char *path) {
    if (!XGI2Init()) {
        XGProbeState = 2;
        NSLog(@"[XG-I2] probe: il2cpp 未就绪");
        return 0;
    }

    // 选一个能写的路径
    NSMutableArray<NSString *> *cands = [NSMutableArray array];
    if (path) [cands addObject:[NSString stringWithUTF8String:path]];
    [cands addObject:@"/var/mobile/Documents/XG_probe.txt"];
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    if (docs) [cands addObject:[docs stringByAppendingPathComponent:@"XG_probe.txt"]];
    [cands addObject:[NSTemporaryDirectory() stringByAppendingPathComponent:@"XG_probe.txt"]];

    FILE *f = NULL;
    for (NSString *p in cands) {
        NSString *dir = [p stringByDeletingLastPathComponent];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                 withIntermediateDirectories:YES attributes:nil error:nil];
        f = fopen(p.UTF8String, "w");
        if (f) { strncpy(g_pfPath, p.UTF8String, sizeof(g_pfPath) - 1); break; }
    }
    if (!f) {
        XGProbeState = 2;
        NSLog(@"[XG-I2] probe: 所有候选路径都写不进去");
        return 0;
    }

    g_pf = f;
    PLog("=== XiuGou probe ===");
    PLog("time=%s", [[NSDate date] description].UTF8String);
    PLog("pid=%d uid=%d", getpid(), getuid());

    const char *unityBase = NULL;
    char basebuf[64];
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *nm = _dyld_get_image_name(i);
        if (nm && strstr(nm, "UnityFramework")) {
            snprintf(basebuf, sizeof(basebuf), "%p", (void *)_dyld_get_image_header(i));
            unityBase = basebuf;
            break;
        }
    }
    PLog("UnityFramework base=%s", unityBase ? unityBase : "NOT FOUND");
    PFlush("A-header");

    int total = phaseA();
    PFlush("B-enum");
    if (total < 0) {
        PLog("!! assemblies 枚举失败，提前结束");
        fflush(g_pf); g_pf = NULL; fclose(f);
        NSLog(@"[XG-I2] probe 失败 -> %@", [NSString stringWithUTF8String:g_pfPath]);
        return 0;
    }

    int kept = phaseB();
    PFlush("C-names");

    int det = phaseC();
    PFlush("D-detail");

    PLog("\n=== summary: total=%d kept=%d detail=%d ===", total, kept, det);
    fflush(g_pf);
    g_pf = NULL;
    fclose(f);

    int sz = (int)[[NSFileManager defaultManager] attributesOfItemAtPath:
                   [NSString stringWithUTF8String:g_pfPath] error:nil].fileSize;
    strncpy(XGProbePathBuf, g_pfPath, sizeof(XGProbePathBuf) - 1);
    XGProbeBytes = sz;
    XGProbeState = 1;
    NSLog(@"[XG-I2] probe 完成 -> %s (%d 字节)", g_pfPath, sz);
    return sz;
}

int XGI2DumpClassNames(const char *path) {
    if (!XGI2Init() || !path) return 0;
    FILE *f = fopen(path, "w");
    if (!f) return 0;
    g_pf = f;
    struct NameCtx c = { 0 };
    walkClasses(nameCb, &c);
    fflush(f); g_pf = NULL; fclose(f);
    return c.n;
}

// ---- 兼容旧接口 ----
int XGI2DumpFields(const char *className) {
    Il2CppClass *k = XGI2Class(className);
    if (!k) return 0;
    int n = 0;
    void *it = NULL;
    while (p_class_get_fields) {
        FieldInfo *f = p_class_get_fields(k, &it);
        if (!f) break;
        const char *fn = p_field_get_name ? p_field_get_name(f) : "?";
        size_t off = p_field_get_offset ? p_field_get_offset(f) : 0;
        NSLog(@"[XG-I2]   %s @0x%zx", fn, off);
        n++;
    }
    return n;
}

int XGI2DumpMethods(const char *className, const char *filter) {
    Il2CppClass *k = XGI2Class(className);
    if (!k || !p_class_get_method_from_name) return 0;
    static const char *common[] = {
        "DoSettleRounds", "Settle", "OnStageClear", "Start", "Update", "Awake", NULL
    };
    int n = 0;
    for (int i = 0; common[i]; i++) {
        for (int a = 0; a < 3; a++) {
            const MethodInfo *m = p_class_get_method_from_name(k, common[i], a);
            if (m) { NSLog(@"[XG-I2] %s::%s/%d @ %p", className, common[i], a, *(void **)m); n++; break; }
        }
    }
    return n;
}

void XGI2ProbeConfigured(void) {
    // 由 XGI2ProbeToFile 统一处理；这里只做一次轻量统计
    struct NameCtx c = { 0 };
    walkClasses(nameCb, &c);
    NSLog(@"[XG-I2] 命中类 %d 个", c.n);
}
