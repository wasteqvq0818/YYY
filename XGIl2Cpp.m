#import "XGIl2Cpp.h"

#include <dlfcn.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <stdarg.h>
#include <time.h>

// ============================================================================
//  IL2CPP 导出符号（全部 dlsym 拿，不硬链 —— 硬链在符号缺失时会让 dylib 整个加载失败）
// ============================================================================
typedef struct Il2CppDomain Il2CppDomain;
typedef struct Il2CppAssembly Il2CppAssembly;
typedef struct Il2CppImage Il2CppImage;

static Il2CppDomain *(*p_domain_get)(void);
static const Il2CppAssembly **(*p_domain_get_assemblies)(const Il2CppDomain *, size_t *);
static Il2CppImage *(*p_assembly_get_image)(const Il2CppAssembly *);
static Il2CppClass *(*p_image_get_class)(const Il2CppImage *, size_t);
static size_t (*p_image_get_class_count)(const Il2CppImage *);
static const char *(*p_class_get_name)(Il2CppClass *);
static const char *(*p_class_get_namespace)(Il2CppClass *);
static const MethodInfo *(*p_class_get_method_from_name)(Il2CppClass *, const char *, int);
static const void *(*p_field_get_offset)(Il2CppClass *, const char *);
static void *(*p_class_get_static_field_data)(Il2CppClass *);
static void *(*p_runtime_invoke)(const void *, void *, void **, void **);
static void *(*p_class_get_fields)(Il2CppClass *, void **);
static const char *(*p_field_get_name)(void *);
static void *(*p_class_get_methods)(Il2CppClass *, void **);
static const char *(*p_method_get_name)(void *);
static uint32_t (*p_method_get_param_count)(void *);

static bool g_i2ready = false;
static char g_err[256] = {0};

// ---- 类名缓存：类名 → Il2CppClass* ----
#define CACHE_MAX 128
typedef struct { char name[64]; Il2CppClass *cls; } CacheEnt;
static CacheEnt g_cache[CACHE_MAX];
static int g_cacheN = 0;

const char *XGI2LastError(void) { return g_err; }

static void set_err(const char *fmt, const char *a, const char *b) {
    snprintf(g_err, sizeof(g_err), fmt, a ? a : "", b ? b : "");
}

bool XGI2Init(void) {
    if (g_i2ready) return true;
    void *h = dlopen(NULL, RTLD_NOW);
    if (!h) h = dlopen("/usr/lib/libSystem.B.dylib", RTLD_NOW);

    p_domain_get                = (Il2CppDomain *(*)(void))dlsym(h, "il2cpp_domain_get");
    p_domain_get_assemblies     = (const Il2CppAssembly **(*)(const Il2CppDomain *, size_t *))dlsym(h, "il2cpp_domain_get_assemblies");
    p_assembly_get_image        = (Il2CppImage *(*)(const Il2CppAssembly *))dlsym(h, "il2cpp_assembly_get_image");
    p_image_get_class           = (Il2CppClass *(*)(const Il2CppImage *, size_t))dlsym(h, "il2cpp_image_get_class");
    p_image_get_class_count     = (size_t (*)(const Il2CppImage *))dlsym(h, "il2cpp_image_get_class_count");
    p_class_get_name            = (const char *(*)(Il2CppClass *))dlsym(h, "il2cpp_class_get_name");
    p_class_get_namespace       = (const char *(*)(Il2CppClass *))dlsym(h, "il2cpp_class_get_namespace");
    p_class_get_method_from_name= (const MethodInfo *(*)(Il2CppClass *, const char *, int))dlsym(h, "il2cpp_class_get_method_from_name");
    p_field_get_offset          = (const void *(*)(Il2CppClass *, const char *))dlsym(h, "il2cpp_field_get_offset");
    p_class_get_static_field_data = (void *(*)(Il2CppClass *))dlsym(h, "il2cpp_class_get_static_field_data");
    p_runtime_invoke            = (void *(*)(const void *, void *, void **, void **))dlsym(h, "il2cpp_runtime_invoke");
    p_class_get_fields          = (void *(*)(Il2CppClass *, void **))dlsym(h, "il2cpp_class_get_fields");
    p_field_get_name            = (const char *(*)(void *))dlsym(h, "il2cpp_field_get_name");
    p_class_get_methods         = (void *(*)(Il2CppClass *, void **))dlsym(h, "il2cpp_class_get_methods");
    p_method_get_name           = (const char *(*)(void *))dlsym(h, "il2cpp_method_get_name");
    p_method_get_param_count    = (uint32_t (*)(void *))dlsym(h, "il2cpp_method_get_param_count");

    if (!p_domain_get || !p_class_get_name) {
        set_err("il2cpp symbols missing (not an IL2CPP process?)", NULL, NULL);
        return false;
    }
    g_i2ready = true;
    NSLog(@"[XG-I2] ready: images api=%d method api=%d",
          p_image_get_class != NULL, p_class_get_method_from_name != NULL);
    return true;
}

// ============================================================================
//  遍历所有 image 的所有类，找名字匹配的。
//  只做一次遍历（~2 万类，实测几十毫秒），命中即缓存。
// ============================================================================
Il2CppClass *XGI2Class(const char *name) {
    if (!name || !*name) return NULL;

    for (int i = 0; i < g_cacheN; i++) {
        if (strcmp(g_cache[i].name, name) == 0 && g_cache[i].cls) return g_cache[i].cls;
    }

    if (!XGI2Init()) return NULL;
    if (!p_domain_get_assemblies || !p_assembly_get_image || !p_image_get_class) {
        set_err("image enumeration api unavailable", NULL, NULL);
        return NULL;
    }

    size_t count = 0;
    const Il2CppAssembly **asms = p_domain_get_assemblies(p_domain_get(), &count);
    Il2CppClass *found = NULL;

    for (size_t a = 0; a < count && !found; a++) {
        Il2CppImage *img = p_assembly_get_image(asms[a]);
        if (!img) continue;
        size_t cc = p_image_get_class_count ? p_image_get_class_count(img) : 0;
        for (size_t c = 0; c < cc; c++) {
            Il2CppClass *k = p_image_get_class(img, c);
            if (!k) continue;
            const char *nm = p_class_get_name(k);
            if (nm && strcmp(nm, name) == 0) { found = k; break; }
        }
    }

    if (!found) {
        set_err("class not found: %s", name, NULL);
        return NULL;
    }

    if (g_cacheN < CACHE_MAX) {
        strncpy(g_cache[g_cacheN].name, name, sizeof(g_cache[0].name) - 1);
        g_cache[g_cacheN].cls = found;
        g_cacheN++;
    }
    return found;
}

void *XGI2Method(const char *className, const char *method, int argc) {
    if (!XGI2Init() || !p_class_get_method_from_name) return NULL;
    Il2CppClass *k = XGI2Class(className);
    if (!k) return NULL;

    const MethodInfo *m = p_class_get_method_from_name(k, method, argc);
    if (!m) { set_err("method not found: %s::%s/%d", className, method); return NULL; }

    // MethodInfo 首字段 = methodPointer
    return *(void **)m;
}

uint32_t XGI2FieldOff(const char *className, const char *field) {
    if (!XGI2Init() || !p_field_get_offset) return 0;
    Il2CppClass *k = XGI2Class(className);
    if (!k) return 0;
    return (uint32_t)(uintptr_t)p_field_get_offset(k, field);
}

void *XGI2StaticData(const char *className) {
    if (!XGI2Init() || !p_class_get_static_field_data) return NULL;
    Il2CppClass *k = XGI2Class(className);
    if (!k) return NULL;
    return p_class_get_static_field_data(k);
}

void *XGI2Invoke(void *methodInfo, void *obj, void **params, void **exc) {
    if (!XGI2Init() || !p_runtime_invoke || !methodInfo) return NULL;
    return p_runtime_invoke(methodInfo, obj, params, exc);
}

void *XGI2Instance(const char *className) {
    if (!XGI2Init() || !p_class_get_method_from_name) return NULL;
    Il2CppClass *k = XGI2Class(className);
    if (!k) return NULL;
    const MethodInfo *getter = p_class_get_method_from_name(k, "get_Instance", 0);
    if (!getter) getter = p_class_get_method_from_name(k, "get_instance", 0);
    if (!getter) { set_err("no get_Instance on %s", className, NULL); return NULL; }
    return p_runtime_invoke(getter, NULL, NULL, NULL);
}

// ============================================================================
//  把全部类名导出到文件 —— 装上一次就不用再猜类名了
// ============================================================================
int XGI2DumpClassNames(const char *path) {
    if (!XGI2Init() || !path) return 0;
    FILE *f = fopen(path, "w");
    if (!f) return 0;

    size_t count = 0;
    const Il2CppAssembly **asms = p_domain_get_assemblies(p_domain_get(), &count);
    int n = 0;
    for (size_t a = 0; a < count; a++) {
        Il2CppImage *img = p_assembly_get_image(asms[a]);
        if (!img) continue;
        size_t cc = p_image_get_class_count ? p_image_get_class_count(img) : 0;
        for (size_t c = 0; c < cc; c++) {
            Il2CppClass *k = p_image_get_class(img, c);
            if (!k) continue;
            const char *nm = p_class_get_name(k);
            const char *ns = p_class_get_namespace ? p_class_get_namespace(k) : "";
            if (nm) { fprintf(f, "%s.%s\n", ns ? ns : "", nm); n++; }
        }
    }
    fclose(f);
    NSLog(@"[XG-I2] dumped %d class names -> %s", n, path);
    return n;
}


// ============================================================================
//  运行时自省：把一个类的字段/方法全打出来（含偏移）
//  这是替代 dump.cs 的关键 —— 装上插件跑一次，配置就齐了。
// ============================================================================
int XGI2DumpFields(const char *className) {
    if (!XGI2Init() || !p_class_get_fields || !p_field_get_name) return 0;
    Il2CppClass *k = XGI2Class(className);
    if (!k) { NSLog(@"[XG-I2] %s: class missing", className); return 0; }

    int n = 0;
    void *iter = NULL;
    NSLog(@"[XG-I2] === %s 字段 ===", className);
    while (1) {
        void *f = p_class_get_fields(k, &iter);
        if (!f) break;
        const char *fn = p_field_get_name(f);
        uint32_t off = p_field_get_offset ? (uint32_t)(uintptr_t)p_field_get_offset(k, fn) : 0;
        NSLog(@"[XG-I2]   %s  @0x%x", fn, off);
        n++;
    }
    NSLog(@"[XG-I2] === %s 共 %d 个字段 ===", className, n);
    return n;
}

int XGI2DumpMethods(const char *className, const char *filter) {
    if (!XGI2Init() || !p_class_get_methods || !p_method_get_name) return 0;
    Il2CppClass *k = XGI2Class(className);
    if (!k) return 0;

    int n = 0, shown = 0;
    void *iter = NULL;
    NSLog(@"[XG-I2] === %s 方法%s%s ===", className,
          filter ? " (筛选: " : "", filter ? filter : "");
    while (1) {
        void *m = p_class_get_methods(k, &iter);
        if (!m) break;
        const char *mn = p_method_get_name(m);
        uint32_t argc = p_method_get_param_count ? p_method_get_param_count(m) : 0;
        n++;
        if (filter && (!mn || !strstr(mn, filter))) continue;
        void *code = *(void **)m;
        NSLog(@"[XG-I2]   %s/%u  @ %p", mn, argc, code);
        shown++;
    }
    NSLog(@"[XG-I2] === %s 共 %d 个方法，显示 %d 个 ===", className, n, shown);
    return n;
}

// 一次性探测：把配置里关心的类全部打印（装好后跑一次即可）
void XGI2ProbeConfigured(void) {
    static const char *classes[] = {
        "Settle", "DoSettleRounds",
        "BattlePhaseBaseHandler", "BattleTeamHandler",
        "EnemyData", "EnemyMonsterData", "EnemyTakeDamageData",
        "BoardMainView", "PuzzleView", "PuzzleGemDisplayHandler",
        NULL
    };
    for (int i = 0; classes[i]; i++) {
        Il2CppClass *k = XGI2Class(classes[i]);
        if (!k) { NSLog(@"[XG-I2] (缺) %s", classes[i]); continue; }
        XGI2DumpFields(classes[i]);
    }
}


// ============================================================================
//  探测结果落盘
//  iOS 非越狱设备上 NSLog 只能通过 Console.app / idevicesyslog 看，
//  直接写文件最省事：装完插件跑一次，用 Filza 把文件拷出来即可。
// ============================================================================
static FILE *g_pf = NULL;

static void PLog(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    if (g_pf) { vfprintf(g_pf, fmt, ap); fputc('\n', g_pf); fflush(g_pf); }
    va_end(ap);
}

static void PLogC(NSString *s) {
    if (!s) return;
    PLog("%s", s.UTF8String);
}

/// 遍历全部 image 的全部类，写「类名 -> 字段+偏移 / 方法+入口」
static int dumpAllClasses(FILE *f) {
    if (!XGI2Init() || !f) return 0;
    if (!p_domain_get_assemblies || !p_assembly_get_image) return 0;

    size_t count = 0;
    const Il2CppAssembly **asms = p_domain_get_assemblies(p_domain_get(), &count);
    if (!asms) return 0;

    int total = 0;
    for (size_t a = 0; a < count; a++) {
        Il2CppImage *img = p_assembly_get_image(asms[a]);
        if (!img) continue;
        size_t cc = p_image_get_class_count ? p_image_get_class_count(img) : 0;
        for (size_t c = 0; c < cc; c++) {
            Il2CppClass *k = p_image_get_class(img, c);
            if (!k) continue;
            const char *nm = p_class_get_name(k);
            if (!nm) continue;

            // 只记录关心词根的类，避免文件过大
            bool keep = strstr(nm, "Settle") || strstr(nm, "Battle") || strstr(nm, "Board") ||
                        strstr(nm, "Puzzle") || strstr(nm, "Enemy") || strstr(nm, "Monster") ||
                        strstr(nm, "Wave") || strstr(nm, "Stage") || strstr(nm, "Gem") ||
                        strstr(nm, "Combo") || strstr(nm, "Skill") || strstr(nm, "Player") ||
                        strstr(nm, "Team") || strstr(nm, "Deck") || strstr(nm, "Orb");
            if (!keep) continue;

            const char *ns = p_class_get_namespace ? p_class_get_namespace(k) : "";
            PLog("\n### %s.%s", ns ? ns : "", nm);
            total++;

            if (p_class_get_fields && p_field_get_name) {
                void *it = NULL;
                int nf = 0;
                while (1) {
                    void *fd = p_class_get_fields(k, &it);
                    if (!fd) break;
                    const char *fn = p_field_get_name(fd);
                    if (!fn) continue;
                    uint32_t off = p_field_get_offset ? (uint32_t)(uintptr_t)p_field_get_offset(k, fn) : 0;
                    PLog("  F %-34s @0x%x", fn, off);
                    nf++;
                    if (nf > 120) break;
                }
            }
            if (p_class_get_methods && p_method_get_name) {
                void *it = NULL;
                int nm2 = 0;
                while (1) {
                    void *m = p_class_get_methods(k, &it);
                    if (!m) break;
                    const char *mn = p_method_get_name(m);
                    if (!mn) continue;
                    uint32_t argc = p_method_get_param_count ? p_method_get_param_count(m) : 0;
                    void *code = *(void **)m;
                    PLog("  M %-34s /%u  @ %p", mn, argc, code);
                    nm2++;
                    if (nm2 > 160) break;
                }
            }
        }
    }
    return total;
}

int XGI2ProbeToFile(const char *path) {
    if (!XGI2Init()) return 0;

    NSString *target = path ? [NSString stringWithUTF8String:path] : nil;
    NSMutableArray<NSString *> *cands = [NSMutableArray array];
    if (target) [cands addObject:target];
    [cands addObject:@"/var/mobile/Documents/XG_probe.txt"];
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    if (docs) [cands addObject:[docs stringByAppendingPathComponent:@"XG_probe.txt"]];
    [cands addObject:[NSTemporaryDirectory() stringByAppendingPathComponent:@"XG_probe.txt"]];

    for (NSString *p in cands) {
        NSString *dir = [p stringByDeletingLastPathComponent];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        FILE *f = fopen(p.UTF8String, "w");
        if (!f) continue;

        g_pf = f;
        PLog("=== XiuGou probe  %s ===", [[NSDate date] description].UTF8String);
        PLog("bundle=%s  pid=%d", [[[NSBundle mainBundle] bundleIdentifier] UTF8String], getpid());

        const struct mach_header_64 *hdr = NULL;
        for (uint32_t i = 0; i < _dyld_image_count(); i++) {
            const char *nm = _dyld_get_image_name(i);
            if (nm && strstr(nm, "UnityFramework")) { hdr = (void *)_dyld_get_image_header(i); break; }
        }
        PLog("UnityFramework base = %p", hdr);

        int n = dumpAllClasses(f);
        PLog("\n=== 共导出 %d 个类 ===", n);

        g_pf = NULL;
        fclose(f);
        NSLog(@"[XG-I2] probe -> %@ (%d classes)", p, n);
        return (int)[[NSFileManager defaultManager] attributesOfItemAtPath:p error:nil].fileSize;
    }
    NSLog(@"[XG-I2] probe 无法写入任何路径");
    return 0;
}
