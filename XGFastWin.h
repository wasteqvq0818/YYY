#ifndef XG_FASTWIN_H
#define XG_FASTWIN_H



#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// ============================================================================
//  快速胜利模块
//
//  三档强度，检测面依次升高（详见 README §5）：
//    档 1  战斗倍速        —— 只改时间流速，游戏自己打完、自己结算。最安全
//    档 2  一击清场        —— 敌人 HP/存活位清零，让游戏自己判定胜利并走正常结算
//    档 3  直接调胜利流程  —— 跳过战斗，直接进结算。最快，但战斗记录会缺字段
//
//  实现要点：档 3 拿到的是「战斗管理器单例 → Win/OnStageClear 方法 → runtime_invoke」，
//  这条链比"改状态机 state"可靠，因为胜负判定和结算上传是绑在同一条流程上的。
// ============================================================================

// 安装（幂等）。装完由 XGAutoTick 按开关调用
void XGFastWinInstall(void);

// 档 2：遍历敌人列表清零 HP 与存活标志，返回处理数量
int  XGFastWinKillAll(void);

// 档 3：直接调用胜利方法，返回 1 = 调用成功
int  XGFastWinForce(void);

// 档 1：设置战斗时间流速（UnityEngine.Time.timeScale）
void XGFastWinSetSpeed(float mult);

// 供面板显示当前状态
NSString *XGFastWinStatus(void);


#ifdef __cplusplus
}
#endif
#endif
