#ifndef XG_SETTLEMENT_H
#define XG_SETTLEMENT_H

#import <Foundation/Foundation.h>
#include <stdint.h>

// ============================================================================
//  结算伪造模块（XiuGou 的核心手法）
//
//  逆向 XiuGou.dylib 得到的结论：
//    它只导入 vm_read_overwrite（读），没有 vm_write/mach_vm_write（写）。
//    也就是说它不"改血量杀怪"，而是构造一份**看起来合理的战斗统计**，
//    交给游戏自己的结算/上报流程 —— 服务端拿到的是一份自洽战报。
//
//    这一点被它的参数面板直接证实：
//      每波回合数 / 每回合连击数 / 每回合转珠步数 / 每回合时间 / 换波时间
//      首消组数 / 每组符石数 / 伤害倍率
//      快速胜利：阶段 %d / %s / 轮回 %d-%d      目标 %llu 秒
//      xg.settlement.{mode,ranges,custom,damage.%d,ranges}
//
//  本模块做同一件事：按参数生成战报 → 写进游戏的结算对象。
// ============================================================================

#define XG_MAX_ROUNDS 64

typedef struct {
    // --- 战斗统计参数（对应它面板上的每一项）---
    int  waves;               // 波数
    int  roundsPerWave;       // 每波回合数
    int  combosPerRound;      // 每回合连击数
    int  stepsPerRound;       // 每回合转珠步数
    int  roundSeconds;        // 每回合时间（秒）
    int  waveSwitchSeconds;   // 换波时间（秒）
    int  firstClearGroups;    // 首消组数
    int  orbsPerGroup;        // 每组符石数

    // --- 伤害：区间随机比固定值安全得多（固定值一眼假）---
    int  mode;                // 0=区间随机 1=固定 2=自定义逐回合
    int  damageMin;
    int  damageMax;
    int  damageFixed;

    // --- 目标总耗时（0 = 不约束，按回合数自然累加）---
    int  targetSeconds;

    // --- 抖动幅度（%）。0 = 完全按参数，越大越像真人 ---
    int  jitterPercent;
} XGSettleParams;

typedef struct {
    int     rounds;                  // 总回合数
    int     combos;                  // 总连击
    int     steps;                   // 总转珠步数
    int     waves;                   // 波数
    int64_t damage;                  // 总伤害
    int     seconds;                 // 总耗时
    int     perRoundDamage[XG_MAX_ROUNDS];
    int     perRoundCombos[XG_MAX_ROUNDS];
    int     perRoundSteps[XG_MAX_ROUNDS];
} XGSettleReport;

// 参数默认值（对齐它面板的出厂值）
void XGSettlementDefaults(XGSettleParams *p);

// 按参数生成一份战报。返回 0 = 参数不合法
int  XGSettlementGenerate(const XGSettleParams *p, XGSettleReport *out);

// 把战报写进游戏结算流程。返回 1 = 成功
// 两种落地方式见 .m 里的说明（A: 直接构造结算对象；B: hook 上报前的构造点）
int  XGSettlementApply(const XGSettleReport *r);

// 给人看的摘要（面板/日志显示）
NSString *XGSettlementDescribe(const XGSettleReport *r);

// 安装（幂等）
void XGSettlementInstall(void);

#endif
