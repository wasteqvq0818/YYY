#ifndef XG_CONFIG_H
#define XG_CONFIG_H

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// ============================================================================
//  精简版配置 —— 只服务「直接胜利」一个功能
//
//  所有偏移来自 XG_probe.txt 实测（31,404 个类扫描）。
//  游戏更新后这些偏移由 il2cpp 运行期自动适配，类名不变就不用重抓。
// ============================================================================

// ---- 敌人（实测：两套 EnemyData 布局，扫描时两种都查）----
#define XG_ENEMY_CLASS           "EnemyData"
#define XG_OFF_ENEMY_DEAD        0x20     // isDead          (int32)
#define XG_OFF_ENEMY_HP_SIMPLE   0x24     // currentHP       (int32)  ← 6 字段版
#define XG_OFF_ENEMY_ROUND_SIMPLE 0x28    // readyRound
#define XG_OFF_ENEMY_HP_FULL     0x38     // _mCurrentHP     ← 42 字段版
#define XG_OFF_ENEMY_MAXHP_FULL  0x28     // _mMaxHP

// ---- 敌人实例上的防秒杀开关（仅作参考，本方案直接改数据字段，绕开它们）----
#define XG_ENEMY_INSTANCE_CLASS  "EnemyInstance"
#define XG_OFF_EI_PREVENT_KILL   0x48     // _isPreventInstantKill
#define XG_OFF_EI_CANNOT_DIE     0x8a     // cannotDie

// ---- 功能开关（只剩一个）----
typedef enum {
    F_FAST_WIN = 0,     // 直接胜利
    F_COUNT
} XGFeature;

typedef struct {
    // 保留几个字段给面板用（精简版暂时不用，但面板代码引用了）
    int   maxSteps;
    int   solveBudgetMs;
    int   minCombos;
    int   scanIntervalMs;    // 扫描间隔（毫秒）
    BOOL  dryRun;            // 只扫描不改
} XGConfT;

typedef struct {
    XGConfT conf;
    BOOL    on[F_COUNT];
} XGState;

extern XGState XG;

void XGLoadConfig(void);
void XGSaveConfig(void);
const char *XGFeatureName(XGFeature f);

// 由 TOSHooks.mm 提供
int  XGLastKillCount(void);

#ifdef __cplusplus
}
#endif
#endif
