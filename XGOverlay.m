#import "XGOverlay.h"
#import "XGConfig.h"
#include "TOSBoard.h"
#include <stdio.h>

// ============================================================================
//  悬浮球 + 开关面板
//  · 球走独立 UIWindow（windowLevel 高于游戏），可拖动，位置存 NSUserDefaults
//  · 面板是 UITableView：功能开关 + 参数 + 调试按钮
// ============================================================================

static UIWindow  *g_ballWindow = nil;
static UIButton  *g_ball       = nil;
static UIWindow  *g_panelWindow = nil;

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
        c.textLabel.text = [NSString stringWithUTF8String:XGFeatureName(f)];
        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = XG.on[f];
        sw.tag = 1000 + ip.row;
        [sw addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged];
        c.accessoryView = sw;
    } else {
        switch (ip.row) {
            case 0:
                c.textLabel.text = @"最大步数";
                c.detailTextLabel.text = [NSString stringWithFormat:@"%d", XG.conf.maxSteps];
                break;
            case 1:
                c.textLabel.text = @"求解预算(ms)";
                c.detailTextLabel.text = [NSString stringWithFormat:@"%d", XG.conf.solveBudgetMs];
                break;
            case 2:
                c.textLabel.text = @"最低 combo";
                c.detailTextLabel.text = [NSString stringWithFormat:@"%d", XG.conf.minCombos];
                break;
            case 3:
                c.textLabel.text = @"▶ 预览最优解";
                c.textLabel.textColor = [UIColor colorWithRed:0.35 green:0.9 blue:0.55 alpha:1.0];
                break;
        }
    }
    return c;
}

- (void)toggle:(UISwitch *)sw {
    int idx = (int)sw.tag - 1000;
    if (idx >= 0 && idx < F_COUNT) {
        XG.on[idx] = sw.on;
        XGSaveConfig();
        NSLog(@"[XG] %s -> %d", XGFeatureName((XGFeature)idx), sw.on);
    }
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section != 1) return;

    if (ip.row == 3) {
        char buf[512] = {0};
        int combo = XGSolvePreview(buf, sizeof(buf));
        UIAlertController *a = [UIAlertController alertControllerWithTitle:
                                    [NSString stringWithFormat:@"combo = %d", combo]
                                    message:[NSString stringWithUTF8String:buf]
                                    preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
    } else {
        // 点参数行 → 弹出输入框改值
        NSString *titles[] = { @"最大步数", @"求解预算(ms)", @"最低 combo" };
        int *targets[] = { &XG.conf.maxSteps, &XG.conf.solveBudgetMs, &XG.conf.minCombos };
        UIAlertController *a = [UIAlertController alertControllerWithTitle:titles[ip.row]
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleAlert];
        [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.keyboardType = UIKeyboardTypeNumberPad;
            tf.text = [NSString stringWithFormat:@"%d", *targets[ip.row]];
        }];
        [a addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *act) {
            int v = [a.textFields.firstObject.text intValue];
            if (v > 0) { *targets[ip.row] = v; XGSaveConfig(); [tv reloadData]; }
        }]];
        [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
    }
}

@end

@implementation XGOverlay

+ (void)install {
    dispatch_async(dispatch_get_main_queue(), ^{
        // ---- 悬浮球 ----
        g_ballWindow = [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, 56, 56)];
        g_ballWindow.windowLevel = UIWindowLevelAlert + 200;
        g_ballWindow.backgroundColor = [UIColor clearColor];
        g_ballWindow.rootViewController = [UIViewController new];

        g_ball = [UIButton buttonWithType:UIButtonTypeCustom];
        g_ball.frame = CGRectMake(0, 0, 56, 56);
        g_ball.layer.cornerRadius = 28;
        g_ball.backgroundColor = [UIColor colorWithRed:0.1 green:0.85 blue:0.45 alpha:0.85];
        [g_ball setTitle:@"XG" forState:UIControlStateNormal];
        g_ball.titleLabel.font = [UIFont boldSystemFontOfSize:16];
        [g_ball addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:(id)self
                                                                          action:@selector(pan:)]];
        [g_ball addTarget:self action:@selector(tapBall) forControlEvents:UIControlEventTouchUpInside];
        [g_ballWindow.rootViewController.view addSubview:g_ball];

        // 位置记忆
        CGFloat x = [[NSUserDefaults standardUserDefaults] floatForKey:@"ballX"] ?: 12;
        CGFloat y = [[NSUserDefaults standardUserDefaults] floatForKey:@"ballY"] ?: 140;
        g_ballWindow.frame = CGRectMake(x, y, 56, 56);
        g_ballWindow.hidden = NO;
    });
}

+ (void)pan:(UIPanGestureRecognizer *)g {
    CGPoint d = [g translationInView:g.view];
    CGRect f = g_ballWindow.frame;
    f.origin.x += d.x;
    f.origin.y += d.y;
    g_ballWindow.frame = f;
    [g setTranslation:CGPointZero inView:g.view];

    if (g.state == UIGestureRecognizerStateEnded) {
        [[NSUserDefaults standardUserDefaults] setFloat:f.origin.x forKey:@"ballX"];
        [[NSUserDefaults standardUserDefaults] setFloat:f.origin.y forKey:@"ballY"];
    }
}

+ (void)tapBall {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_panelWindow) { g_panelWindow.hidden = NO; return; }

        g_panelWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        g_panelWindow.windowLevel = UIWindowLevelAlert + 300;
        UINavigationController *nav =
            [[UINavigationController alloc] initWithRootViewController:[XGPanelVC new]];
        nav.navigationBar.barStyle = UIBarStyleBlack;
        g_panelWindow.rootViewController = nav;
        g_panelWindow.hidden = NO;
    });
}

@end
