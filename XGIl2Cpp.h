#ifndef XG_IL2CPP_H
#define XG_IL2CPP_H



#import <Foundation/Foundation.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// ============================================================================
//  IL2CPP 导航层 —— 按「类名」找类，不需要 namespace、不需要 RVA
//
//  为什么这么做：
//    il2cpp_class_from_name 要求 namespace 精确匹配，而 namespace 只能从
//    dump.cs 里读。但 Il2CppDumper 目前不支持 metadata v39（神魔之塔用的版本）。
//    换一条路：遍历所有 image 的所有类，按类名比对 —— 一次遍历（几万类）几十毫秒，
//    缓存结果即可。这样类名对就行，namespace 是 "" 还是 "Battle" 都无所谓。
//
//  同理，方法地址用 il2cpp_class_get_method_from_name 运行期取，
//  完全不用 RVA + 基址人工计算。
// ============================================================================

typedef struct Il2CppClass Il2CppClass;
typedef struct MethodInfo MethodInfo;

// 初始化（幂等）。返回 false = 不是 IL2CPP 游戏或符号缺失
bool XGI2Init(void);

// 按类名找类（缓存）。name 传 C 字符串，例如 "EnemyData"
Il2CppClass *XGI2Class(const char *name);

// 找所有同名类（多程序集场景）。返回命中个数
int XGI2FindAllClasses(const char *name, void **out, int maxN);

// 按「类名 + 方法名 + 参数个数」拿方法入口指针（可直接给 MSHookFunction）
void *XGI2Method(const char *className, const char *method, int argc);

// MethodInfo*（hook 用：改它的首字段就是换函数指针）
void *XGI2MethodInfo(const char *className, const char *method, int argc);

// 给定 Il2CppClass* 取 MethodInfo
void *XGI2MethodInfoOfClass(void *klass, const char *method, int argc);

// 字段偏移（实例字段）。失败返回 0
uint32_t XGI2FieldOff(const char *className, const char *field);

// 给定 Il2CppClass* 直接取字段偏移（避免再走一次全量遍历）
uint32_t XGI2FieldOffOfClass(void *klass, const char *field);

// 读静态字段的值（当指针用）。会先触发类型初始化（cctor），否则 static data 为空
uintptr_t XGI2StaticFieldPtr(const char *className, const char *field);

// 多路尝试拿单例：静态字段(Instance/_instance/_getInstance/mInstance) + 静态方法(getInstance/get_Instance/Instance/get_Current/Current)
// 探测阶段用来确定 Puzzle 这类核心类到底怎么取实例
void *XGI2GetInstanceMulti(const char *className);

// 打印某类的静态字段（调试用，写进 probe 文件）
void XGI2DumpStaticFields(const char *className);

// 静态字段数据区指针（静态字段用它 + offset）
void *XGI2StaticData(const char *className);

// 取对象的类名 / 命名空间（诊断用）
const char *XGI2ClassName(void *klass);
const char *XGI2ClassNamespace(void *klass);

// 调方法：obj 传实例（静态方法传 NULL），params 是参数地址数组
// 返回返回值指针或 NULL，exc 非空表示托管异常
void *XGI2Invoke(void *methodInfo, void *obj, void **params, void **exc);

// 拿单例：调用 get_Instance。失败返回 NULL
void *XGI2Instance(const char *className);

// 自省：打印某类的全部字段（含偏移）/ 方法（含入口地址）
int  XGI2DumpFields(const char *className);
int  XGI2DumpMethods(const char *className, const char *nameFilter);

// 一次性探测配置里关心的所有类
void XGI2ProbeConfigured(void);

// 把探测结果写到文件（iOS 非越狱设备读日志困难，落盘最省事）
// path 传 NULL 时默认写 /var/mobile/Documents/XG_probe.txt，失败回退沙箱 Documents
// 返回写入的字节数
int XGI2ProbeToFile(const char *path);

// 遍历所有类的方法名，筛出胜利/结算/死亡相关函数（v13 用）
int XGI2ProbeMethods(const char *path);

// 探测结果的实际落盘路径与大小（面板直接显示，省得用户到处找）
extern char XGProbePathBuf[512];
extern int  XGProbeBytes;
extern int  XGProbeState;   // 0=未跑 1=成功 2=失败

// 调试：把所有类名写到 path（一行一个），用于离线 grep
int XGI2DumpClassNames(const char *path);

// 最近一次失败原因
const char *XGI2LastError(void);


#ifdef __cplusplus
}
#endif
#endif
