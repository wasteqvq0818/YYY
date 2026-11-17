#import <Foundation/Foundation.h>

/// 触摸注入（自瞄用）。用于那些"朝向完全由触摸输入驱动"的 FPS/MOBA。
/// 走私有 API IOHIDEventSystemClient，把合成的手指事件直接送进 HID 事件流，
/// 不经过 UIKit 的 hit-testing，因此对"只 patch 触摸回调"的轻量反作弊也有效。
@interface TouchInjector : NSObject
+ (instancetype)shared;
- (void)beginAtPoint:(CGPoint)pt inWindow:(UIWindow *)window;
- (void)moveToPoint:(CGPoint)pt;
- (void)end;
@property (nonatomic, readonly) BOOL available;
@end
