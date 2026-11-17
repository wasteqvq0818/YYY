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
#define XG_OFF_EI_DEAD           0x90     // _isDead
#define XG_OFF_EI_PREDICT_HP     0x38     // predictHP（血条显示值）

// ---- 以下偏移全部来自 dump.cs（metadata v39，Il2CppDumper-lxraa 实跑）----
//      EnemyInstance:
//        predictHP @0x38 (float)  _isDead @0x90 (bool)  cannotDie @0x8A (bool)
//        _isPreventInstantKill @0x48 (ManagedBoolWithSkillParam*，指针)
//        mData @0xF8 (EnemyData*)   ← 实例到数据的真实引用
//      EnemyData:
//        _mMaxHP @0x28 (Number)  _mCurrentHP @0x38 (Number)  mExists @0x18 (EnemyInstance*)
//      Number = struct { Decimal _val; }  → 16 字节
//      Decimal 布局: lo@+0, mid@+4, hi@+8, flags@+12
#define XG_ACC_INST_MDATA         0xF8
#define XG_ACC_INST_PREDICT_HP    0x38
#define XG_ACC_INST_ISDEAD        0x90
#define XG_ACC_INST_CANNOTDIE     0x8A
#define XG_ACC_INST_PREVENT_KILL  0x48
#define XG_ACC_DATA_CUR_HP        0x38
#define XG_ACC_DATA_MAX_HP        0x28
#define XG_ACC_DATA_EXISTS        0x18
#define XG_ACC_DECIMAL_SIZE       16

// ---- Labyrinth 的静态字段（dump.cs 行 32134 起，全部 static）----
//      Labyrinth.BattleZoneEnemy      @0xE0  List<EnemyInstance>  ← 当前战场敌人
//      Labyrinth.totalBattleZoneEnemy @0xE8  int
//      Labyrinth.IsBlockEnemyDie      @0x68  ManagedBool          ← 阻止敌人死亡
//      Labyrinth.IsBlockChangeHPBar   @0x88  ManagedBool
//      List<T>: _items@0x10  _size@0x18
//      Il2CppArray: 数据区@0x20
//      ManagedBool: _oriValue@0x10  _keys@0x18（isTrue = _keys.Count>0）
#define XG_LAB_CLASS               "Labyrinth"
#define XG_ACC_LAB_BATTLEZONE      0xE0
#define XG_ACC_LAB_TOTAL           0xE8
#define XG_ACC_LAB_BLOCK_DIE       0x68
#define XG_ACC_LAB_BLOCK_HPBAR     0x88
#define XG_ACC_LIST_ITEMS          0x10
#define XG_ACC_LIST_SIZE           0x18
#define XG_ACC_ARRAY_DATA          0x20
#define XG_ACC_MB_ORIVALUE         0x10
#define XG_ACC_MB_KEYS             0x18

// ---- 方法名（来自 XG_methods.txt 全量方法扫描，46,963 类 / 226,963 方法）----
#define XG_BATTLE_CTRL_CLASS     "Labyrinth"        // 战斗控制器（有 Victory/GameOver/CheckEndBattleZone）
#define XG_VICTORY_METHOD        "Victory"          // 直接触发胜利
#define XG_VICTORY2_METHOD       "Victory2"
#define XG_DIE_METHOD            "Die"              // EnemyInstance 的死亡方法
#define XG_CHECKEND_METHOD       "CheckEndBattleZone"

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
    int   stageCurrent;      // 跳关用：当前第几关（游戏里显示的 3/7 的 3）
    int   stageTotal;        // 跳关用：总共几关（7）
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

// 由 TOSHooks.mm 提供（放在这个带 extern "C" 保护的头里，
// 避免 XGOverlay.m(C) 与 TOSHooks.mm(ObjC++) 之间符号名不匹配）
void XGScanAsync(void);
void XGScanMethodsAsync(void);   // 扫描方法名（找胜利/结算函数）
void XGCallDieAsync(void);       // 对场上所有敌人调用 Die()
void XGForceVictoryAsync(void);  // 直接调用 Labyrinth.Victory()
const char *XGLastCallResult(void);

// 装/卸「血量归零」hook（改 MethodInfo 函数指针，不碰代码段）
int  XGInstallHPHook(void);
void XGRemoveHPHook(void);
int  XGHPHookInstalled(void);
int  XGInstallDeadHook(void);
void XGRemoveDeadHook(void);
int  XGDeadHookInstalled(void);
int  XGInstallInlineHooks(void);
void XGCallEnemyDieAsync(void);   // 直接调 methodPointer（绕过 runtime_invoke）

// dump 游戏的 NSUserDefaults（XiuGou 可能走的是改 plist/偏好这条路）
// hook 血量 getter：让游戏每次读血量都拿到 0
void XGWaveProbe(void);        // dump Labyrinth 波次字段的真实值
void XGSetTotalWaveOne(void);  // 关卡值改成 1（打一波就胜利）
void XGJumpToLastWave(void);   // 跳关值改到末尾
const char *XGWaveMsg(void);
void XGAutoKillStart(void);   // 自动过关开关：自动调 EnemyDie（走完整流程，正常掉卡）
void XGAutoKillStop(void);
int  XGAutoKillActive(void);
int  XGAutoKillTotal(void);
void XGAutoKillTickOnce(void);
void XGForceVictoryNow(void);   // 直接调 Labyrinth.Victory()
const char *XGVictoryMsg(void);
void XGKillAllStart(void);     // 连续杀：每 0.25s 处理一个敌人
void XGKillAllStop(void);
int  XGKillAllRunning(void);
int  XGKillAllCount(void);
const char *XGKillAllMsg(void);
void XGDieCallAsync(void);     // 走游戏死亡流程（直接调 methodPointer）
const char *XGDieCallMsg(void);
void XGAutoStart(void);        // 开自动过关：进战斗自动清空敌人
void XGAutoStop(void);
int  XGAutoActive(void);
int  XGAutoClearCount(void);
void XGClearBattleZone(void);   // 把 BattleZoneEnemy 的 size 置 0（游戏据此判定没有敌人）
const char *XGClearMsg(void);
void XGMonitorStart(void);     // 开始监视（记录游戏状态变化，供对比 XiuGou）
void XGMonitorStop(void);
int  XGMonitorActive(void);
const char *XGMonitorMsg(void);
int  XGHookHPGetter(void);
int  XGHPGetterHooked(void);
void XGPatchCacheAsync(void);      // 改 RESTORE_CACHE 里的敌人 hp（XiuGou 的做法）
int  XGPatchEnemyCount(void);
const char *XGPatchMsg(void);
void XGRestoreCacheAsync(void);    // 只读：解析并显示缓存内容
void XGDumpPrefsAsync(void);
const char *XGDumpPrefsMsg(void);
int  XGCallOk(void);
int  XGCallFail(void);
int  XGCallRan(void);
const char *XGCallDieMsg(void);
void XGKillBattleZoneAsync(void);   // 终版：清血 + 触发死亡判定（用真实实例）
int  XGKillChanged(void);
int  XGKillRan(void);
const char *XGKillMessage(void);
void XGZeroBattleZoneAsync(void);   // 终版：走 Labyrinth.BattleZoneEnemy 静态链
int  XGZBHits(void);
int  XGZBChanged(void);
int  XGZBRan(void);
const char *XGZBMessage(void);
void XGZeroEnemiesAsync(void);   // 精确清血（走 EnemyInstance.mData 链）
int  XGZeroHits(void);
int  XGZeroChanged(void);
const char *XGZeroMessage(void);
void XGSkipStageAsync(void);
int  XGSkipHits(void);
int  XGSkipChanged(void);
const char *XGSkipMessage(void);
int  XGInlineCount(void);
int  XGCntIsDead2(void);
int  XGCntCheckDie2(void);
int  XGCntCurHP2(void);
int  XGCntVerify2(void);
int  XGCntCurHP(void);
int  XGCntMaxHP(void);
int  XGCntIsDead(void);
int  XGCntCheckDie(void);
int  XGCntVerify(void);   // 验证 hook（UpdateRound）的调用次数
void XGResetCounters(void);
int  XGScanState(void);
const char *XGScanMessage(void);
int  XGLastKillCount(void);
const char *XGSampleInfo(void);   // 命中样本（地址 + hp），面板显示用

#ifdef __cplusplus
}
#endif
#endif
