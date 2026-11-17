#include "TOSBoard.h"
#include <stdio.h>
#include <string.h>
#include <time.h>

// ============================================================================
//  盘面模拟
// ============================================================================

void tos_apply_path(TOSBoard *b, const int8_t *path, int len) {
    if (len < 2) return;
    int8_t dragged = b->attr[path[0]];
    for (int i = 0; i < len - 1; i++) {
        b->attr[path[i]] = b->attr[path[i + 1]];
    }
    b->attr[path[len - 1]] = dragged;
}

// ============================================================================
//  消除统计（只算首轮：新珠未知，落珠后无法预测）
// ============================================================================

void tos_eval(const TOSBoard *b, int *combos, int *cleared) {
    uint8_t hit[TOS_SIZE];
    memset(hit, 0, sizeof(hit));

    // 横向
    for (int y = 0; y < TOS_H; y++) {
        int x = 0;
        while (x < TOS_W) {
            int a = b->attr[y * TOS_W + x];
            int run = 1;
            while (x + run < TOS_W && b->attr[y * TOS_W + x + run] == a) run++;
            if (a >= 0 && run >= 3) {
                for (int k = 0; k < run; k++) hit[y * TOS_W + x + k] = 1;
            }
            x += run;
        }
    }
    // 纵向
    for (int x = 0; x < TOS_W; x++) {
        int y = 0;
        while (y < TOS_H) {
            int a = b->attr[y * TOS_W + x];
            int run = 1;
            while (y + run < TOS_H && b->attr[(y + run) * TOS_W + x] == a) run++;
            if (a >= 0 && run >= 3) {
                for (int k = 0; k < run; k++) hit[(y + k) * TOS_W + x] = 1;
            }
            y += run;
        }
    }

    // combo 数 = 独立消除组数（十字交叉算 2 组，这里按"段"计，符合游戏表现）
    int c = 0, n = 0;
    for (int y = 0; y < TOS_H; y++) {
        int x = 0;
        while (x < TOS_W) {
            int a = b->attr[y * TOS_W + x], run = 1;
            while (x + run < TOS_W && b->attr[y * TOS_W + x + run] == a) run++;
            if (a >= 0 && run >= 3) c++;
            x += run;
        }
    }
    for (int x = 0; x < TOS_W; x++) {
        int y = 0;
        while (y < TOS_H) {
            int a = b->attr[y * TOS_W + x], run = 1;
            while (y + run < TOS_H && b->attr[(y + run) * TOS_W + x] == a) run++;
            if (a >= 0 && run >= 3) c++;
            y += run;
        }
    }
    for (int i = 0; i < TOS_SIZE; i++) if (hit[i]) n++;

    if (combos)  *combos = c;
    if (cleared) *cleared = n;
}

// ============================================================================
//  求解器：自避走动 DFS + 时间预算 + 同色优先扩展
//
//  为什么不是 A*：转珠的"价值"不是到某点的最短距离，而是整条路径的消除收益，
//  目标函数在叶子上才可评估 → 走 DFS + 全局最优 + 时间截断，和商业插件的做法一致。
// ============================================================================

typedef struct {
    const TOSBoard *src;
    int      maxSteps;
    uint64_t deadlineUs;
    int      nodes;
    int      bestScore;
    int      bestCombos;
    TOSSolution best;
    int8_t   path[TOS_MAXPATH];
    uint8_t  visited[TOS_SIZE];
} SolverCtx;

static uint64_t now_us(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000ULL + (uint64_t)ts.tv_nsec / 1000ULL;
}

// 扩展顺序：先试与被拖珠同属性的邻居（更容易成组，靠前的解更有希望刷新最优）
static int order_neighbors(int cur, int out[4]) {
    int cx = cur % TOS_W, cy = cur / TOS_W;
    int n = 0;
    if (cy > 0)          out[n++] = cur - TOS_W;  // 上
    if (cy < TOS_H - 1)  out[n++] = cur + TOS_W;  // 下
    if (cx > 0)          out[n++] = cur - 1;      // 左
    if (cx < TOS_W - 1)  out[n++] = cur + 1;      // 右
    return n;
}

static void dfs(SolverCtx *ctx, int depth, int cur) {
    if (++ctx->nodes % 256 == 0 && now_us() > ctx->deadlineUs) return;

    if (depth >= 2) {
        TOSBoard tmp = *ctx->src;
        tos_apply_path(&tmp, ctx->path, depth);
        int combos = 0, cleared = 0;
        tos_eval(&tmp, &combos, &cleared);

        // 评分：combo 为王，其次消除量，同等条件下偏好短路径（易操作、耗时低）
        int score = combos * 10000 + cleared * 100 - depth;
        if (score > ctx->bestScore) {
            ctx->bestScore = score;
            ctx->bestCombos = combos;
            ctx->best.len = depth;
            ctx->best.combos = combos;
            ctx->best.cleared = cleared;
            ctx->best.score = score;
            memcpy(ctx->best.path, ctx->path, (size_t)depth);
        }
    }

    if (depth >= ctx->maxSteps) return;

    int nb[4];
    int cnt = order_neighbors(cur, nb);
    int8_t draggedAttr = ctx->src->attr[ctx->path[0]];

    // 同色优先：把同属性邻居提到前面
    for (int i = 0; i < cnt; i++) {
        for (int j = i + 1; j < cnt; j++) {
            int si = (ctx->src->attr[nb[i]] == draggedAttr);
            int sj = (ctx->src->attr[nb[j]] == draggedAttr);
            if (!si && sj) { int t = nb[i]; nb[i] = nb[j]; nb[j] = t; }
        }
    }

    for (int i = 0; i < cnt; i++) {
        int nx = nb[i];
        if (ctx->visited[nx]) continue;
        ctx->visited[nx] = 1;
        ctx->path[depth] = (int8_t)nx;
        dfs(ctx, depth + 1, nx);
        ctx->visited[nx] = 0;
        if (now_us() > ctx->deadlineUs) return;
    }
}

int tos_solve(const TOSBoard *b, int maxSteps, int timeBudgetMs,
              TOSSolution *out, int outCap) {
    if (!b || !out || outCap < 1) return 0;
    if (maxSteps > TOS_MAXPATH - 1) maxSteps = TOS_MAXPATH - 1;
    if (maxSteps < 1) return 0;

    SolverCtx ctx;
    memset(&ctx, 0, sizeof(ctx));
    ctx.src = b;
    ctx.maxSteps = maxSteps;
    ctx.deadlineUs = now_us() + (uint64_t)(timeBudgetMs > 0 ? timeBudgetMs : 20) * 1000ULL;
    ctx.bestScore = -1;

    // 每个起点都试一遍（30 个起点，选全局最优）
    for (int s = 0; s < TOS_SIZE; s++) {
        memset(ctx.visited, 0, sizeof(ctx.visited));
        ctx.visited[s] = 1;
        ctx.path[0] = (int8_t)s;
        dfs(&ctx, 1, s);
        if (now_us() > ctx.deadlineUs) break;
    }

    if (ctx.bestScore <= 0) return 0;
    *out = ctx.best;
    return 1;
}

// ============================================================================
//  调试
// ============================================================================

const char *tos_attr_name(int a) {
    static const char *n[] = { "水", "火", "木", "光", "暗", "心" };
    return (a >= 0 && a < 6) ? n[a] : "·";
}

void tos_dump(const TOSBoard *b) {
    for (int y = 0; y < TOS_H; y++) {
        for (int x = 0; x < TOS_W; x++) {
            printf("%s ", tos_attr_name(b->attr[y * TOS_W + x]));
        }
        printf("\n");
    }
}
