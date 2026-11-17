#import <UIKit/UIKit.h>

@interface XGOverlay : NSObject
+ (void)install;
@end

// 由 TOSHooks.xm 提供：手动触发一次转珠（调试按钮用）
void XGAutoSolveOnce(void);
int  XGSolvePreview(char *out, int cap);   // 返回 combo 数，out 填路径文本
