#import "TouchInjector.h"
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <UIKit/UIKit.h>

// ============================================================================
// IOHIDEvent 私有符号。签名随 iOS 版本变化，所以全部走 dlsym + 运行期校验，
// 不硬链符号（硬链会在某些机型上直接 dylib 加载失败 → 整个 tweak 不生效）。
// ============================================================================
typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef CFTypeRef (*CreateClientFunc)(CFAllocatorRef);
typedef void (*SetMatchingFunc)(IOHIDEventSystemClientRef, CFDictionaryRef);
typedef void (*DispatchEventFunc)(IOHIDEventSystemClientRef, IOHIDEventRef);
typedef void (*SetIntegerFunc)(IOHIDEventRef, IOHIDEventField, int64_t);
typedef void (*SetSenderIDFunc)(IOHIDEventRef, uint64_t);
typedef void (*SetFloatFunc)(IOHIDEventRef, IOHIDEventField, double);
typedef IOHIDEventRef (*CreateFingerFunc)(CFAllocatorRef, AbsoluteTime, uint32_t, uint32_t,
                                          uint32_t, double, double, double,
                                          double, double, uint32_t, uint32_t, uint32_t);
typedef IOHIDEventRef (*CreateHandFunc)(CFAllocatorRef, AbsoluteTime, uint32_t, uint32_t,
                                        uint32_t, uint32_t, uint32_t,
                                        double, double, double, double, double,
                                        uint32_t, uint32_t, u_int32_t);

static CreateClientFunc  p_createClient;
static SetMatchingFunc   p_setMatching;
static DispatchEventFunc p_dispatch;
static SetIntegerFunc    p_setInteger;
static SetSenderIDFunc   p_setSenderID;
static CreateFingerFunc  p_createFinger;
static CreateHandFunc    p_createHand;

@implementation TouchInjector {
    IOHIDEventSystemClientRef _client;
    BOOL _down;
    CGPoint _cur;
    uint64_t _senderID;
}

+ (instancetype)shared {
    static TouchInjector *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [TouchInjector new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        void *h = dlopen("/System/Library/PrivateFrameworks/IOKit.framework/IOKit", RTLD_NOW);
        if (!h) h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
        if (h) {
            p_createClient = (CreateClientFunc)dlsym(h, "IOHIDEventSystemClientCreate");
            p_setMatching  = (SetMatchingFunc)dlsym(h, "IOHIDEventSystemClientSetMatching");
            p_dispatch     = (DispatchEventFunc)dlsym(h, "IOHIDEventSystemClientDispatchEvent");
            p_setInteger   = (SetIntegerFunc)dlsym(h, "IOHIDEventSetIntegerValue");
            p_setSenderID  = (SetSenderIDFunc)dlsym(h, "IOHIDEventSetSenderID");
            p_createFinger = (CreateFingerFunc)dlsym(h, "IOHIDEventCreateDigitizerFingerEvent");
            p_createHand   = (CreateHandFunc)dlsym(h, "IOHIDEventCreateDigitizerEvent");
        }
        // 台机/模拟器上多为 0x0；真机常见 0x8000000D1C / 0x8000000D21，
        // 用 frida 读一遍 IOHIDEventGetSenderID 采样后固定下来最稳。
        _senderID = 0x8000000D1C;
        NSLog(@"[GameAssist] TouchInjector available=%d", self.available);
    }
    return self;
}

- (BOOL)available {
    return p_createClient && p_dispatch && p_createHand && p_createFinger && p_setInteger;
}

- (void)ensureClient {
    if (_client || !p_createClient) return;
    _client = (IOHIDEventSystemClientRef)p_createClient(kCFAllocatorDefault);
    if (_client && p_setMatching) {
        // 只挂触摸屏服务，避免把事件重复投给其它 HID 服务
        NSDictionary *m = @{ @"PrimaryUsagePage": @(0x0D), @"PrimaryUsage": @(0x04) };
        p_setMatching(_client, (__bridge CFDictionaryRef)m);
    }
}

- (IOHIDEventRef)makeHandEvent:(BOOL)down at:(CGPoint)pt {
    if (!p_createFinger || !p_createHand) return NULL;
    // 手指事件：index=2 identity=1 tipPressure 0~1
    IOHIDEventRef finger = p_createFinger(kCFAllocatorDefault,
                                          mach_absolute_time(),
                                          2,              // finger index
                                          1,              // identity
                                          down ? 1 : 0,   // eventMask: tip touch down/up
                                          pt.x, pt.y, 0.0,
                                          down ? 1.0 : 0.0, // tipPressure
                                          0.0,            // twist
                                          0,              // range
                                          down ? 1 : 0,   // touch
                                          0);
    if (!finger) return NULL;

    // 手事件（transducer type hand = 3）包住手指事件
    IOHIDEventRef hand = p_createHand(kCFAllocatorDefault,
                                      mach_absolute_time(),
                                      3,                    // kIOHIDDigitizerTransducerTypeHand
                                      0,                    // index
                                      1,                    // identity
                                      down ? 1 : 0,         // eventMask
                                      0,                    // buttonMask
                                      pt.x, pt.y, 0.0,
                                      0.0, 0.0,
                                      0, down ? 1 : 0, 0);
    return hand ?: finger;
}

- (void)dispatch:(IOHIDEventRef)ev {
    if (!ev) return;
    [self ensureClient];
    if (p_setSenderID) p_setSenderID(ev, _senderID);
    if (p_setInteger)  p_setInteger(ev, (IOHIDEventField)0x1D9, 1); // hand 标记
    if (_client && p_dispatch) p_dispatch(_client, ev);
    CFRelease(ev);
}

- (void)beginAtPoint:(CGPoint)pt inWindow:(UIWindow *)window {
    _cur = pt;
    _down = YES;
    [self dispatch:[self makeHandEvent:YES at:pt]];
}

- (void)moveToPoint:(CGPoint)pt {
    if (!_down) { [self beginAtPoint:pt inWindow:nil]; return; }
    _cur = pt;
    [self dispatch:[self makeHandEvent:YES at:pt]];
}

- (void)end {
    if (!_down) return;
    _down = NO;
    [self dispatch:[self makeHandEvent:NO at:_cur]];
}

@end
