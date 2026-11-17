#ifndef XG_CONFIG_H
#define XG_CONFIG_H

#import <Foundation/Foundation.h>
#include "XGSettlement.h"

#ifdef __cplusplus
extern "C" {
#endif

// ============================================================================
//  偏移表 —— 全部来自 XG_probe.txt 实测（31,404 个类 / 218 万字段扫描）
//
//  ★ 这些都是「类内字段偏移」，游戏更新后由 il2cpp 运行期自动适配，不用重抓。
//  ★ 类名也是运行期按名查找，只有类被改名/混淆才需要更新。
// ============================================================================

// ---- 盘面（核心：自动转珠读这一条链）----
#define XG_PUZZLE_CLASS          "Puzzle"
#define XG_OFF_PUZZLE_GEMS       0x158   // Puzzle._puzzleGems       （数组或 List）
#define XG_OFF_PUZZLE_GEM_COUNT  0x178   // Puzzle.<NumOfPuzzleGem>k__BackingField
#define XG_OFF_PUZZLE_DATA       0xa0    // Puzzle.<PuzzleData>k__BackingField
#define XG_OFF_PUZZLE_MOVE       0xc0    // Puzzle.MovePuzzleGem
#define XG_OFF_PUZZLE_ACTIVATED  0x18    // Puzzle.activated（小偏移 → 静态字段）
#define XG_OFF_PUZZLE_DETECTING  0x90    // Puzzle.IsBlockDetectPhase
#define XG_OFF_PUZZLE_ROUND_END  0x160   // Puzzle.IsEndedPlayerRoundFromTimeBar

// ---- 单颗珠子 ----
#define XG_GEM_CLASS             "PuzzleGem"
#define XG_OFF_GEM_ELEMENT       0xbc    // PuzzleGem._element  ← 属性值 0..5
#define XG_OFF_GEM_LV            0xc4    // PuzzleGem._gemLv
#define XG_OFF_GEM_POS           0x60    // PuzzleGem.pos
#define XG_OFF_GEM_MARKED        0x6c    // PuzzleGem.markedForRemoval

// ---- 容器布局（两种都试，自适应）----
#define XG_OFF_ARRAY_DATA        0x20    // Il2CppArray 元素起始
#define XG_OFF_ARRAY_LENGTH      0x18    // Il2CppArray.max_length
#define XG_OFF_LIST_ITEMS        0x10    // List<T>.items
#define XG_OFF_LIST_SIZE         0x18    // List<T>.size

// ---- 敌人（两种 EnemyData 布局都试）----
#define XG_ENEMY_CLASS           "EnemyData"
#define XG_ENEMY_INSTANCE_CLASS  "EnemyInstance"
// 简化版 EnemyData（6 字段）
#define XG_OFF_ENEMY_HP_SIMPLE   0x24    // currentHP
#define XG_OFF_ENEMY_DEAD        0x20    // isDead
#define XG_OFF_ENEMY_ROUND_SIMPLE 0x28   // readyRound
// 完整版 EnemyData（42 字段）
#define XG_OFF_ENEMY_HP_FULL     0x38    // _mCurrentHP
#define XG_OFF_ENEMY_MAXHP_FULL  0x28    // _mMaxHP
#define XG_OFF_ENEMY_ROUND_FULL  0x80    // _mReadyRound
#define XG_OFF_ENEMY_ELEMENT     0x48    // _mElement

// ---- 波次 → 敌人列表 ----
#define XG_WAVE_CLASS            "WaveData"
#define XG_OFF_WAVE_ENEMIES      0x18    // WaveData._enemies
#define XG_GWAVE_CLASS           "GameplayWaveData"
#define XG_OFF_GWAVE_ENEMY_DATAS 0x10    // GameplayWaveData.<EnemyDatas>

// ---- 敌人实例（防秒杀的两个开关）----
#define XG_OFF_EI_PREVENT_KILL   0x48    // EnemyInstance._isPreventInstantKill
#define XG_OFF_EI_INSTANT_KILL   0x50    // EnemyInstance.isInstantKill
#define XG_OFF_EI_CANNOT_DIE     0x8a    // EnemyInstance.cannotDie
#define XG_OFF_EI_DEAD           0x90    // EnemyInstance._isDead
#define XG_OFF_EI_PREDICT_HP     0x38    // EnemyInstance.predictHP

// ---- 结算：游戏没有 Result/Win/Settle 命名的类（全量扫描证实），
//      所以快速胜利走「清场 + 让游戏自己判胜」这条路，不直接调结算 ----
#define XG_SETTLE_CLASS         "WaveData"   // 波次数据（预留）
#define XG_SETTLE_METHOD        "Start"      // 预留
#define XG_SETTLE_ARGC          0
#define XG_SETTLE_NS            ""
#define XG_SETTLE_HOOK_SYMBOL   ""           // 空 = 走 il2cpp

// ---- 快速胜利 ----
#define XG_BATTLE_ROOT_PTR_OFF   0x00000000  // 已废弃：现在通过类单例取，不再硬编码映像偏移
#define XG_OFF_ENEMY_LIST        0x00000000  // 已废弃：改用 EnemyData/EnemyInstance 遍历

// ---- 功能开关 ----
typedef enum {
    F_AUTO_SOLVE = 0,   // 自动转珠
    F_INF_SKILL,        // 无限技能（需另找技能类，暂未接）
    F_GOD_MODE,         // 无敌（改 PlayerMonsterData.HP）
    F_ONE_HIT,          // 秒杀（改 EnemyData.currentHP）
    F_DMG_MULT,         // 伤害倍率
    F_LONG_TIME,        // 转珠加时
    F_TIME_SCALE,       // 战斗倍速
    F_FAST_WIN,         // 快速胜利
    F_SETTLE_FAKE,      // 结算伪造
    F_DEBUG_PROBE,      // 字段探测
    F_COUNT
} XGFeature;

typedef struct {
    int   maxSteps;        // 求解最大步数
    int   solveBudgetMs;   // 求解时间预算
    int   minCombos;       // 低于该 combo 不落子
    int   touchStepMs;     // 触摸每步间隔（毫秒）
    int   dmgMult;         // 伤害倍率
    int   timeMult;        // 转珠时间倍数
    int   autoCooldown;    // 两次自动转珠最小间隔（秒）
    int   gameSpeed;       // 战斗倍速
    int   fastWinMode;     // 1=倍速 2=清场 3=直调
    int   fastWinCooldown; // 快速胜利触发间隔
    BOOL  dryRun;          // 只算不落子
    BOOL  autoStrict;      // 严格校验战斗阶段
} XGConfT;

typedef struct {
    XGConfT       conf;
    XGSettleParams settle;
    BOOL          on[F_COUNT];
} XGState;

extern XGState XG;

void XGLoadConfig(void);
void XGSaveConfig(void);
const char *XGFeatureName(XGFeature f);

#ifdef __cplusplus
}
#endif
#endif
