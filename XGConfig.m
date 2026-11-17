#import "XGConfig.h"

XGState XG;

static NSString *const kKey = @"com.lab.xiugou.prefs";

void XGLoadConfig(void) {
    XG.conf.maxSteps      = 12;
    XG.conf.solveBudgetMs = 30;
    XG.conf.minCombos     = 3;
    XG.conf.scanIntervalMs = 1500;
    XG.conf.dryRun        = NO;

    for (int i = 0; i < F_COUNT; i++) XG.on[i] = NO;
    // 默认开着：装完进战斗就自动清场。想关就从面板关。
    XG.on[F_FAST_WIN] = YES;

    NSDictionary *d = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kKey];
    if (!d) {
        NSLog(@"[XG] 无存档，使用默认配置（直接胜利=开）");
        return;
    }
    XG.conf.scanIntervalMs = [d[@"scanIntervalMs"] intValue] ?: XG.conf.scanIntervalMs;
    XG.conf.dryRun         = [d[@"dryRun"] boolValue];

    NSArray *flags = d[@"flags"];
    if (flags.count == F_COUNT) {
        for (int i = 0; i < F_COUNT; i++) XG.on[i] = [flags[i] boolValue];
    }
    NSLog(@"[XG] 配置已加载: 直接胜利=%d 扫描间隔=%dms", XG.on[F_FAST_WIN], XG.conf.scanIntervalMs);
}

void XGSaveConfig(void) {
    NSMutableArray *flags = [NSMutableArray arrayWithCapacity:F_COUNT];
    for (int i = 0; i < F_COUNT; i++) [flags addObject:@(XG.on[i])];

    NSDictionary *d = @{
        @"scanIntervalMs": @(XG.conf.scanIntervalMs),
        @"dryRun":         @(XG.conf.dryRun),
        @"flags":          flags,
    };
    [[NSUserDefaults standardUserDefaults] setObject:d forKey:kKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

const char *XGFeatureName(XGFeature f) {
    switch (f) {
        case F_FAST_WIN: return "直接胜利";
        default:         return "?";
    }
}
