#import "XGOverlay.h"
#import "XGConfig.h"
#include "TOSBoard.h"
#include <stdio.h>

// ============================================================================
//  悬浮球 + 开关面板
//
//  这里有个 iOS 13+ 的关键坑：
//    新版 App 用 UIScene 生命周期，`[[UIWindow alloc] initWithFrame:]` 创建的窗口
//    不会自动挂到任何 scene 上，结果就是"代码跑了但屏幕上什么都没有"。
//    必须用 `initWithWindowScene:` 创建。
//
//  所以本文件用三层保险：
//    1. 优先用当前 foregroundActive 的 UIWindowScene 建独立窗口（windowLevel 高，最干净）
//    2. 1 秒后若判定窗口没挂上 scene，回退成把球直接加到游戏 keyWindow 上
//    3. 两条都失败则把诊断写进文件，方便远程定位
// ============================================================================

static UIWindow  *g_ballWindow  = nil;
static UIButton  *g_ball        = nil;
static UIWindow  *g_panelWindow = nil;
static UIWindowScene *g_scene   = nil;

// ---------------- 诊断落盘 ----------------
static void XGDiag(NSString *msg) {
    NSLog(@"[XG-UI] %@", msg);
    static NSString *paths[3];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        paths[0] = @"/var/mobile/Documents/XG_ui.log";
        NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        paths[1] = docs ? [docs stringByAppendingPathComponent:@"XG_ui.log"] : nil;
        paths[2] = [NSTemporaryDirectory() stringByAppendingPathComponent:@"XG_ui.log"];
    });
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], msg];
    for (int i = 0; i < 3; i++) {
        if (!paths[i]) continue;
        NSString *dir = [paths[i] stringByDeletingLastPathComponent];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        FILE *f = fopen(paths[i].UTF8String, "a");
        if (f) { fputs(line.UTF8String, f); fclose(f); return; }
    }
}

// ---------------- 找宿主 window 与 scene ----------------
static UIWindowScene *XGFindScene(void) {
    if (@available(iOS 13.0, *)) {
        // 优先前台激活的
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
            if (![s isKindOfClass:[UIWindowScene class]]) continue;
            if (s.activationState == UISceneActivationStateForegroundActive) return (UIWindowScene *)s;
        }
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]]) return (UIWindowScene *)s;
        }
    }
    return nil;
}

static UIWindow *XGHostWindow(void) {
    // keyWindow 优先
    UIWindow *host = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
            if (![s isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)s).windows) {
                if (w.isKeyWindow) { host = w; break; }
            }
            if (host) break;
        }
    }
    if (!host) host = UIApplication.sharedApplication.keyWindow;
    if (!host) {
        for (UIWindow *w in UIApplication.sharedApplication.windows) {
            if (w.windowLevel == UIWindowLevelNormal) { host = w; break; }
        }
    }
    return host;
}

// ---------------- 面板 ----------------
@interface XGPanelVC : UITableViewController
@end

@implementation XGPanelVC

- (instancetype)init {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {}
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"XiuGou";
    self.tableView.backgroundColor = [UIColor colorWithWhite:0.07 alpha:1.0];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"关闭" style:UIBarButtonItemStyleDone
                                        target:self action:@selector(close)];
}

- (void)close {
    g_panelWindow.hidden = YES;
    g_panelWindow = nil;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 2; }

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    return s == 0 ? @"功能" : @"参数 / 调试";
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return s == 0 ? F_COUNT : 4;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                                 reuseIdentifier:nil];
    c.backgroundColor = [UIColor colorWithWhite:0.13 alpha:1.0];
    c.textLabel.textColor = [UIColor whiteColor];
    c.detailTextLabel.textColor = [UIColor colorWithWhite:0.7 alpha:1.0];

    if (ip.section == 0) {
        XGFeature f = (XGFeature)ip.row;
        const char *nm = XGFeatureName(f);
        c.textLabel.text = nm ? [NSString stringWithUTF8String:nm] : @"?";
        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = XG.on[f];
        sw.tag = 1000 + ip.row;
        [sw addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged];
        c.accessoryView = sw;
    } else {
        switch (ip.row) {
            case 0: c.textLabel.text = @"最大步数";
                    c.detailTextLabel.text = [NSString stringWithFormat:@"%d", XG.conf.maxSteps]; break;
            case 1: c.textLabel.text = @"求解预算(ms)";
                    c.detailTextLabel.text = [NSString stringWithFormat:@"%d", XG.conf.solveBudgetMs]; break;
            case 2: c.textLabel.text = @"最低 combo";
                    c.detailTextLabel.text = [NSString stringWithFormat:@"%d", XG.conf.minCombos]; break;
            case 3: c.textLabel.text = @"▶ 预览最优解";
                    c.textLabel.textColor = [UIColor colorWithRed:0.35 green:0.9 blue:0.55 alpha:1.0]; break;
        }
    }
    return c;
}

- (void)toggle:(UISwitch *)sw {
    int idx = (int)sw.tag - 1000;
    if (idx >= 0 && idx < F_COUNT) {
        XG.on[idx] = sw.on;
        XGSaveConfig();
        XGDiag([NSString stringWithFormat:@"toggle %d -> %d", idx, sw.on]);
    }
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section != 1) return;

    if (ip.row == 3) {
        char buf[512] = {0};
        int combo = XGSolvePreview(buf, sizeof(buf));
        UIAlertController *a = [UIAlertController
            alertControllerWithTitle:[NSString stringWithFormat:@"combo = %d", combo]
                             message:[NSString stringWithUTF8String:buf]
                      preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }

    NSString *title = (ip.row == 0) ? @"最大步数" : (ip.row == 1 ? @"求解预算(ms)" : @"最低 combo");
    int *slot = (ip.row == 0) ? &XG.conf.maxSteps
               : (ip.row == 1 ? &XG.conf.solveBudgetMs : &XG.conf.minCombos);
    int current = *slot;

    UIAlertController *a = [UIAlertController alertControllerWithTitle:title
                                                              message:nil
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.keyboardType = UIKeyboardTypeNumberPad;
        tf.text = [NSString stringWithFormat:@"%d", current];
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *act) {
        int v = [a.textFields.firstObject.text intValue];
        if (v > 0) { *slot = v; XGSaveConfig(); [tv reloadData]; }
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

@end

// ---------------- 安装 ----------------
@implementation XGOverlay

+ (void)install {
    XGDiag(@"install 开始");

    dispatch_async(dispatch_get_main_queue(), ^{
        g_scene = XGFindScene();
        XGDiag([NSString stringWithFormat:@"scene=%@", g_scene ? @"有" : @"nil"]);

        // ---- 三层保险的第 1 层：独立窗口（必须绑 scene）----
        UIWindow *ballWin = nil;
        if (g_scene) {
            ballWin = [[UIWindow alloc] initWithWindowScene:g_scene];
            XGDiag(@"用 initWithWindowScene 建窗口");
        } else {
            ballWin = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
            XGDiag(@"scene 为 nil，退回 initWithFrame（可能不显示）");
        }
        g_ballWindow = ballWin;

        CGFloat x = [[NSUserDefaults standardUserDefaults] floatForKey:@"ballX"];
        CGFloat y = [[NSUserDefaults standardUserDefaults] floatForKey:@"ballY"];
        if (x == 0 && y == 0) { x = 16; y = 140; }
        ballWin.frame = CGRectMake(x, y, 60, 60);
        ballWin.windowLevel = UIWindowLevelAlert + 200;
        ballWin.backgroundColor = [UIColor clearColor];
        ballWin.rootViewController = [UIViewController new];
        ballWin.rootViewController.view.backgroundColor = [UIColor clearColor];
        ballWin.hidden = NO;

        g_ball = [UIButton buttonWithType:UIButtonTypeCustom];
        g_ball.frame = CGRectMake(0, 0, 60, 60);
        g_ball.layer.cornerRadius = 30;
        g_ball.backgroundColor = [UIColor colorWithRed:0.10 green:0.85 blue:0.45 alpha:0.9];
        [g_ball setTitle:@"XG" forState:UIControlStateNormal];
        g_ball.titleLabel.font = [UIFont boldSystemFontOfSize:17];
        [g_ball addTarget:self action:@selector(tapBall) forControlEvents:UIControlEventTouchUpInside];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)];
        [g_ball addGestureRecognizer:pan];
        [ballWin.rootViewController.view addSubview:g_ball];

        XGDiag([NSString stringWithFormat:@"窗口就绪 frame=%@ level=%.0f",
                NSStringFromCGRect(ballWin.frame), ballWin.windowLevel]);

        // ---- 第 2 层：1 秒后自检，没挂上 scene 就改成挂在游戏 keyWindow 上 ----
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            BOOL attached = NO;
            if (@available(iOS 13.0, *)) {
                attached = (g_ballWindow.windowScene != nil);
            } else {
                attached = g_ballWindow.isKeyWindow || !g_ballWindow.isHidden;
            }
            XGDiag([NSString stringWithFormat:@"自检 attached=%d hidden=%d windowScene=%@",
                    attached, g_ballWindow.isHidden, g_ballWindow.windowScene ? @"有" : @"nil"]);

            if (!attached) {
                UIWindow *host = XGHostWindow();
                XGDiag([NSString stringWithFormat:@"回退方案：host=%@", host ? @"有" : @"nil"]);
                if (!host) { XGDiag(@"找不到宿主窗口，UI 无法显示"); return; }

                // 把球从独立窗口搬出来，直接挂到游戏 window 上
                [g_ball removeFromSuperview];
                g_ball.frame = CGRectMake(x, y, 60, 60);
                g_ball.autoresizingMask = UIViewAutoresizingNone;
                [host addSubview:g_ball];
                [host bringSubviewToFront:g_ball];

                // 独立窗口收掉，避免留一个空窗口
                g_ballWindow.hidden = YES;
                XGDiag(@"已挂到 keyWindow，球应该可见了");
            } else {
                XGDiag(@"独立窗口正常，球应该在左上角 (16,140)");
            }
        });
    });
}

+ (void)pan:(UIPanGestureRecognizer *)g {
    UIView *v = g.view;
    CGPoint d = [g translationInView:v.superview];
    CGPoint c = v.center;
    c.x += d.x; c.y += d.y;

    // 限制在屏幕内
    CGFloat w = v.bounds.size.width, h = v.bounds.size.height;
    CGSize sc = UIScreen.mainScreen.bounds.size;
    c.x = MAX(w / 2, MIN(sc.width - w / 2, c.x));
    c.y = MAX(h / 2 + 20, MIN(sc.height - h / 2, c.y));
    v.center = c;
    [g setTranslation:CGPointZero inView:v.superview];

    if (g.state == UIGestureRecognizerStateEnded) {
        [[NSUserDefaults standardUserDefaults] setFloat:c.x forKey:@"ballX"];
        [[NSUserDefaults standardUserDefaults] setFloat:c.y forKey:@"ballY"];
    }
}

+ (void)tapBall {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_panelWindow) { g_panelWindow.hidden = NO; return; }

        UIWindow *panel = nil;
        if (g_scene) {
            panel = [[UIWindow alloc] initWithWindowScene:g_scene];
        } else {
            panel = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
        }
        panel.frame = UIScreen.mainScreen.bounds;
        panel.windowLevel = UIWindowLevelAlert + 300;

        UINavigationController *nav =
            [[UINavigationController alloc] initWithRootViewController:[XGPanelVC new]];
        nav.navigationBar.barStyle = UIBarStyleBlack;
        panel.rootViewController = nav;
        panel.hidden = NO;
        g_panelWindow = panel;
        XGDiag(@"面板打开");
    });
}

@end
