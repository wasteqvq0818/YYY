#ifndef XG_CONFIG_H
#define XG_CONFIG_H



#import <Foundation/Foundation.h>
#include "XGSettlement.h"

#ifdef __cplusplus
extern "C" {
#endif

// ============================================================================
//  偏移与类名 —— 全部集中在这里，dump 完一次填完
//  取法见 README「偏移获取 SOP」
// ============================================================================

// ---- 盘面 ----
#define XG_BOARD_ARRAY_OFF     0x00000000   // [TODO] 盘面对象内 → 30 格属性数组
#define XG_BOARD_ELEM_BYTE     1            // 1 = 每格 1 字节, 0 = 每格 int32
#define XG_BOARD_ELEM_INT32    0
#define XG_STATE_OFF           0x00000000   // [TODO] 盘面对象内 → 战斗阶段 state

// ---- 快速胜利：敌人列表与胜利流程 ----
#define XG_BATTLE_ROOT_PTR_OFF   0x00000000   // [TODO] 映像内静态字段 → 战斗管理器指针
#define XG_OFF_ENEMY_LIST        0x00000000   // [TODO] 战斗对象 + off → 敌人 List<Monster>
#define XG_OFF_ENEMY_HP          0x00000000   // [TODO] Monster + off → int32 当前 HP
#define XG_OFF_ENEMY_ALIVE       0x00000000   // [TODO] Monster + off → bool 存活（填 0 表示不写）
// namespace 已不需要：XGIl2Cpp 按类名遍历查找（metadata v39 无法用 dumper）
#define XG_FASTWIN_NS            ""
#define XG_FASTWIN_CLASS         "Settle"      // 实测类名（metadata 提取）
#define XG_FASTWIN_WIN_METHOD    "Win"        // [TODO] 也可能是 OnStageClear / StageFinish
#define XG_FASTWIN_WIN_ARGC      0            // [TODO] 带 bool 参数就填 1
#define XG_FASTWIN_USE_INSTANCE  1            // 1 = 先 invoke get_Instance 拿单例

// ---- 结算伪造（对应原版 xg.settlement.* 那一套）----
#define XG_SETTLE_NS            ""            // [TODO] 结算类的 namespace
#define XG_SETTLE_CLASS         "Settle"        // 实测类名
#define XG_SETTLE_METHOD        "Init"        // [TODO] 接收战报的方法
#define XG_SETTLE_ARGC          5             // [TODO] 参数个数（damage,rounds,combos,steps,seconds）
#define XG_SETTLE_HOOK_SYMBOL   ""            // 方式B：hook 符号名；空 = 走 il2cpp

// ---- 命名空间（IL2CPP 的 namespace 字符串；没有就留空 "" ）----
#define XG_NS_SKILL            ""
#define XG_NS_PLAYER           ""
#define XG_NS_ENEMY            ""
#define XG_NS_BOARD            ""

// ---- 功能开关枚举（顺序要与 XGOverlay 的表格一致）----
typedef enum {
    F_AUTO_SOLVE = 0,   // 自动转珠
    F_INF_SKILL,        // 无限技能
    F_GOD_MODE,         // 无敌
    F_ONE_HIT,          // 秒杀
    F_DMG_MULT,         // 伤害倍率
    F_LONG_TIME,        // 转珠加时
    F_TIME_SCALE,       // 战斗倍速
    F_FAST_WIN,         // 快速胜利（档位见 fastWinMode）
    F_SETTLE_FAKE,      // 结算伪造（生成合规战报）
    F_DEBUG_PROBE,      // 启动时打印关键类的字段/方法（替代 dump.cs）
    F_COUNT
} XGFeature;

typedef struct {
    int   maxSteps;        // 求解最大步数（TOS 单回合通常 8~20 步）
    int   solveBudgetMs;   // 求解时间预算
    int   minCombos;       // 低于该 combo 不落子
    int   touchStepMs;     // 触摸每步间隔（毫秒），太快会被判非法
    int   dmgMult;         // 伤害倍率（整数）
    int   timeMult;        // 转珠时间倍数
    int   autoCooldown;    // 两次自动转珠的最小间隔（秒）
    int   gameSpeed;       // 战斗倍速（2 = 二倍速）
    int   fastWinMode;     // 1=倍速 2=一击清场 3=直接胜利流程
    int   fastWinCooldown; // 快速胜利触发间隔（秒）
    BOOL  dryRun;          // 只算不落子（调试）
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
