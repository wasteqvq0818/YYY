#import <UIKit/UIKit.h>

@interface XGOverlay : NSObject
+ (void)install;
@end

// 由 TOSHooks.mm 提供：求解一次但不落子（面板"预览最优解"按钮用）
#ifdef __cplusplus
extern "C" {
#endif

int XGSolvePreview(char *out, int cap);   // 返回 combo 数，out 填路径文本

#ifdef __cplusplus
}
#endif
