#import "XGOverlay.h"
#import "XGConfig.h"
#include "TOSBoard.h"
#include <stdio.h>

// ============================================================================
//  悬浮球 + 极简面板（v8）
//
//  iOS 13+ 的坑（已解决）：App 用 UIScene 生命周期时，
//  `[[UIWindow alloc] initWithFrame:]` 建的窗口不会挂到 scene 上，屏幕上看不到。
//  必须用 `initWithWindowScene:`。这里用三层保险：scene 窗口 → keyWindow 回退 → 诊断落盘。
// ============================================================================

static UIWindow  *g_ballWindow  = nil;
static UIButton  *g_ball        = nil;
static UIWindow  *g_panelWindow = nil;
static UIWindowScene *g_scene   = nil;

static void XGDiag(NSString *msg) {
    NSLog(@"[XG-UI] %@", msg);
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], msg];
    NSString *p = @"/var/mobile/Documents/XG_ui.log";
    NSString *dir = [p stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:nil];
    FILE *f = fopen(p.UTF8String, "a");
    if (f) { fputs(line.UTF8String, f); fclose(f); }
}

static UIWindowScene *XGFindScene(void) {
    if (@available(iOS 13.0, *)) {
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
    self.title = @"直接胜利";
    self.tableView.backgroundColor = [UIColor colorWithWhite:0.07 alpha:1.0];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"关闭" style:UIBarButtonItemStyleDone
                                        target:self action:@selector(close)];
    [self refreshHeader];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshHeader];
}

- (void)refreshHeader {
    BOOL hooked = XGInlineCount() > 0;
    NSString *stateLine = hooked ? [NSString stringWithFormat:@"✅ inline hook 已装（%d 个）", XGInlineCount()] : @"⭕️ 未装 inline hook";
    UIColor *color = hooked ? [UIColor colorWithRed:0.4 green:0.9 blue:0.5 alpha:1.0]
                            : [UIColor colorWithWhite:0.75 alpha:1.0];
    const char *sm;
    if (XGPatchEnemyCount() > 0) sm = XGPatchMsg();
    else if (XGCallRan())      sm = XGCallDieMsg();
    else if (XGKillRan())      sm = XGKillMessage();
    else if (XGZBRan())        sm = XGZBMessage();
    else if (XGZeroHits() > 0) sm = XGZeroMessage();
    else if (XGSkipHits() > 0) sm = XGSkipMessage();
    else                       sm = XGScanMessage();
    NSString *text = [NSString stringWithFormat:@"%@\n计数：HP %d｜isDead %d｜CheckDie %d｜验证 %d\n%@",
        stateLine, XGCntCurHP2(), XGCntIsDead2(), XGCntCheckDie2(), XGCntVerify2(),
        (sm && sm[0]) ? [NSString stringWithUTF8String:sm] : @""];

    UIFont *font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    CGSize maxSz = CGSizeMake(self.tableView.bounds.size.width - 32, CGFLOAT_MAX);
    CGRect r = [text boundingRectWithSize:maxSz
                                  options:NSStringDrawingUsesLineFragmentOrigin
                               attributes:@{NSFontAttributeName: font}
                                  context:nil];

    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, maxSz.width, r.size.height + 24)];
    UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(16, 12, maxSz.width - 16, r.size.height)];
    lbl.numberOfLines = 0;
    lbl.font = font;
    lbl.textColor = color;
    lbl.text = text;
    [box addSubview:lbl];
    self.tableView.tableHeaderView = box;
}

- (void)close {
    g_panelWindow.hidden = YES;
    g_panelWindow = nil;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 2; }

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    return s == 0 ? @"操作" : @"跳关参数（游戏里显示的 3/7 就填 3 和 7）";
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return s == 0 ? 6 : 2;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                                 reuseIdentifier:nil];
    c.backgroundColor = [UIColor colorWithWhite:0.13 alpha:1.0];
    c.textLabel.textColor = [UIColor whiteColor];
    c.detailTextLabel.textColor = [UIColor colorWithWhite:0.65 alpha:1.0];
    c.detailTextLabel.font = [UIFont systemFontOfSize:11];

    if (ip.section == 1) {
        if (ip.row == 0) {
            c.textLabel.text = [NSString stringWithFormat:@"当前第几关：%d", XG.conf.stageCurrent];
        } else {
            c.textLabel.text = [NSString stringWithFormat:@"总共几关：%d", XG.conf.stageTotal];
        }
        c.detailTextLabel.text = @"点一下改数字";
        return c;
    }

    if (ip.row == 0) {
        c.textLabel.text = XGKillAllRunning() ? [NSString stringWithFormat:@"💀 连续杀：进行中（已 %d）", XGKillAllCount()] : @"💀 连续杀光敌人（走死亡流程）";
        c.textLabel.textColor = [UIColor colorWithRed:0.3 green:1.0 blue:0.5 alpha:1.0];
        c.detailTextLabel.text = @"每 0.25 秒调一次 EnemyDie，逐个杀到列表空";
    } else if (ip.row == 1) {
        c.textLabel.text = @"🧹 手动清空当前敌人";
        c.detailTextLabel.text = XGClearMsg() && XGClearMsg()[0] ? [NSString stringWithUTF8String:XGClearMsg()] : @"清空 BattleZoneEnemy（只点一次）";
    } else if (ip.row == 2) {
        BOOL on = XGInlineCount() > 0;
        c.textLabel.text = on ? @"🔨 inline hook 已装" : @"🔨 装 inline hook（备用）";
        c.detailTextLabel.text = @"改函数机器码";
    } else if (ip.row == 3) {
        c.textLabel.text = @"⚡ 扫描并清场（旧，可能崩）";
        c.detailTextLabel.text = @"按旧偏移改，可能命中历史对象";
    } else if (ip.row == 4) {
        c.textLabel.text = @"📋 导出游戏偏好设置（plist）";
        c.detailTextLabel.text = @"看 MH_CACHE_GAMEPLAY_DATA_* —— XiuGou 可能改的就是这个";
    } else {
        c.textLabel.text = @"🔄 刷新状态";
        c.detailTextLabel.text = @"扫描是后台跑的，状态不会自动刷";
    }
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];

    if (ip.section == 1) {
        int *slot = (ip.row == 0) ? &XG.conf.stageCurrent : &XG.conf.stageTotal;
        NSString *title = (ip.row == 0) ? @"当前第几关" : @"总共几关";
        int cur = *slot;
        UIAlertController *a = [UIAlertController alertControllerWithTitle:title
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleAlert];
        [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.keyboardType = UIKeyboardTypeNumberPad;
            tf.text = [NSString stringWithFormat:@"%d", cur];
        }];
        [a addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *act) {
            int v = [a.textFields.firstObject.text intValue];
            if (v > 0) { *slot = v; XGSaveConfig(); [tv reloadData]; [self refreshHeader]; }
        }]];
        [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }

    if (ip.row == 0) {
        if (XGKillAllRunning()) XGKillAllStop();
        else XGKillAllStart();
        [self refreshHeader];
        for (int i = 1; i <= 6; i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ [self refreshHeader]; [tv reloadData]; });
        }
        [self refreshHeader];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self refreshHeader]; });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(16 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self refreshHeader]; [tv reloadData]; });
    } else if (ip.row == 1) {
        XGClearBattleZone();
        [self refreshHeader];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self refreshHeader]; [tv reloadData]; });
    } else if (ip.row == 2) {
        if (XGInlineCount() == 0) XGInstallInlineHooks();
        [self refreshHeader]; [tv reloadData];
    } else if (ip.row == 3) {
        XGScanAsync();
        [self refreshHeader];
    } else if (ip.row == 4) {
        XGDumpPrefsAsync();
        [self refreshHeader];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self refreshHeader]; });
    } else {
        [self refreshHeader]; [tv reloadData];
    }
}

@end

// ---------------- 安装 ----------------
@implementation XGOverlay

+ (void)install {
    XGDiag(@"install 开始");
    dispatch_async(dispatch_get_main_queue(), ^{
        g_scene = XGFindScene();

        UIWindow *ballWin = g_scene
            ? [[UIWindow alloc] initWithWindowScene:g_scene]
            : [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
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
        g_ball.backgroundColor = [UIColor colorWithRed:0.10 green:0.85 blue:0.45 alpha:0.92];
        [g_ball setTitle:@"XG" forState:UIControlStateNormal];
        g_ball.titleLabel.font = [UIFont boldSystemFontOfSize:17];
        [g_ball addTarget:self action:@selector(tapBall) forControlEvents:UIControlEventTouchUpInside];
        [g_ball addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                          action:@selector(pan:)]];
        [ballWin.rootViewController.view addSubview:g_ball];

        // 1 秒后自检：窗口没挂上 scene 就改成挂在游戏 keyWindow 上
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            BOOL attached = YES;
            if (@available(iOS 13.0, *)) attached = (g_ballWindow.windowScene != nil);
            if (!attached) {
                UIWindow *host = XGHostWindow();
                if (host) {
                    [g_ball removeFromSuperview];
                    g_ball.frame = CGRectMake(x, y, 60, 60);
                    [host addSubview:g_ball];
                    [host bringSubviewToFront:g_ball];
                    g_ballWindow.hidden = YES;
                    XGDiag(@"回退到 keyWindow");
                }
            } else {
                XGDiag(@"独立窗口正常");
            }
        });
    });
}

+ (void)pan:(UIPanGestureRecognizer *)g {
    UIView *v = g.view;
    CGPoint d = [g translationInView:v.superview];
    CGPoint c = v.center;
    c.x += d.x; c.y += d.y;

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

        UIWindow *panel = g_scene
            ? [[UIWindow alloc] initWithWindowScene:g_scene]
            : [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
        panel.frame = UIScreen.mainScreen.bounds;
        panel.windowLevel = UIWindowLevelAlert + 300;

        UINavigationController *nav =
            [[UINavigationController alloc] initWithRootViewController:[XGPanelVC new]];
        nav.navigationBar.barStyle = UIBarStyleBlack;
        panel.rootViewController = nav;
        panel.hidden = NO;
        g_panelWindow = panel;
    });
}

@end
