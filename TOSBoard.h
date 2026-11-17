#ifndef TOS_BOARD_H
#define TOS_BOARD_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ============================================================================
//  神魔之塔（Tower of Saviors）盘面模型与自动转珠求解器
//  盘面：6 列 × 5 行 = 30 格，索引 idx = y * 6 + x
//  属性编码（按游戏内 enum 顺序，若你的 dump 顺序不同，改 tos_attr_name 即可）：
//      0=水 1=火 2=木 3=光 4=暗 5=心  -1=空/特殊珠(强化、心转等)
// ============================================================================

#define TOS_W        6
#define TOS_H        5
#define TOS_SIZE     (TOS_W * TOS_H)
#define TOS_MAXPATH  32

typedef struct {
    int8_t attr[TOS_SIZE];   // 每格属性；-1 表示不参与匹配的特殊珠
} TOSBoard;

typedef struct {
    int8_t  path[TOS_MAXPATH]; // 起点 → … → 终点，格子索引
    int     len;               // 路径长度（步数 = len-1）
    int     combos;            // 首轮消除的 combo 数
    int     cleared;           // 首轮消除的珠子数
    int     score;             // 综合评分（越大越好）
} TOSSolution;

// 求解：在 timeBudgetMs 内搜索不超过 maxSteps 步的最优拖动路径
// 返回 1 = 找到解，0 = 无解
int  tos_solve(const TOSBoard *b, int maxSteps, int timeBudgetMs,
               TOSSolution *out, int outCap);

// 模拟一条路径作用到盘面上（原地修改）
void tos_apply_path(TOSBoard *b, const int8_t *path, int len);

// 统计一个盘面的首轮 combo / 消除数
void tos_eval(const TOSBoard *b, int *combos, int *cleared);

// 调试打印（一行 6 个属性）
void tos_dump(const TOSBoard *b);

const char *tos_attr_name(int a);

#endif

#ifdef __cplusplus
}
#endif
