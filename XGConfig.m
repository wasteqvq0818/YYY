#import "XGConfig.h"

XGState XG;

static NSString *const kKey = @"com.lab.xiugou.prefs";

void XGLoadConfig(void) {
    // 默认值
    XG.conf.maxSteps      = 12;
    XG.conf.solveBudgetMs = 30;
    XG.conf.minCombos     = 3;
    XG.conf.touchStepMs   = 18;
    XG.conf.dmgMult       = 10;
    XG.conf.timeMult      = 3;
    XG.conf.autoCooldown  = 2;
    XG.conf.gameSpeed     = 3;
    XG.conf.fastWinMode   = 2;
    XG.conf.fastWinCooldown = 1;
    XGSettlementDefaults(&XG.settle);
    XG.conf.dryRun        = NO;
    XG.conf.autoStrict    = YES;

    for (int i = 0; i < F_COUNT; i++) XG.on[i] = NO;
    XG.on[F_AUTO_SOLVE] = YES;

    NSDictionary *d = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kKey];
    if (!d) return;

    XG.conf.maxSteps      = [d[@"maxSteps"] intValue]      ?: XG.conf.maxSteps;
    XG.conf.solveBudgetMs = [d[@"solveBudgetMs"] intValue] ?: XG.conf.solveBudgetMs;
    XG.conf.minCombos     = [d[@"minCombos"] intValue]     ?: XG.conf.minCombos;
    XG.conf.touchStepMs   = [d[@"touchStepMs"] intValue]   ?: XG.conf.touchStepMs;
    XG.conf.dmgMult       = [d[@"dmgMult"] intValue]       ?: XG.conf.dmgMult;
    XG.conf.timeMult      = [d[@"timeMult"] intValue]      ?: XG.conf.timeMult;
    XG.conf.autoCooldown  = [d[@"autoCooldown"] intValue]  ?: XG.conf.autoCooldown;
    XG.conf.gameSpeed     = [d[@"gameSpeed"] intValue]     ?: XG.conf.gameSpeed;
    XG.conf.fastWinMode   = [d[@"fastWinMode"] intValue]   ?: XG.conf.fastWinMode;
    XG.conf.fastWinCooldown = [d[@"fastWinCooldown"] intValue] ?: XG.conf.fastWinCooldown;
    XG.conf.dryRun        = [d[@"dryRun"] boolValue];
    XG.conf.autoStrict    = [d[@"autoStrict"] boolValue];

    XGSettleParams *sp = &XG.settle;
    if (d[@"st.waves"])  sp->waves         = [d[@"st.waves"] intValue];
    if (d[@"st.rounds"]) sp->roundsPerWave = [d[@"st.rounds"] intValue];
    if (d[@"st.combos"]) sp->combosPerRound= [d[@"st.combos"] intValue];
    if (d[@"st.steps"])  sp->stepsPerRound = [d[@"st.steps"] intValue];
    if (d[@"st.dmin"])   sp->damageMin     = [d[@"st.dmin"] intValue];
    if (d[@"st.dmax"])   sp->damageMax     = [d[@"st.dmax"] intValue];
    if (d[@"st.mode"])   sp->mode          = [d[@"st.mode"] intValue];
    if (d[@"st.target"]) sp->targetSeconds = [d[@"st.target"] intValue];

    NSArray *flags = d[@"flags"];
    if (flags.count == F_COUNT) {
        for (int i = 0; i < F_COUNT; i++) XG.on[i] = [flags[i] boolValue];
    }
    NSLog(@"[XG] config loaded: steps=%d budget=%dms minCombo=%d",
          XG.conf.maxSteps, XG.conf.solveBudgetMs, XG.conf.minCombos);
}

void XGSaveConfig(void) {
    NSMutableArray *flags = [NSMutableArray arrayWithCapacity:F_COUNT];
    for (int i = 0; i < F_COUNT; i++) [flags addObject:@(XG.on[i])];

    NSDictionary *d = @{
        @"maxSteps":      @(XG.conf.maxSteps),
        @"solveBudgetMs": @(XG.conf.solveBudgetMs),
        @"minCombos":     @(XG.conf.minCombos),
        @"touchStepMs":   @(XG.conf.touchStepMs),
        @"dmgMult":       @(XG.conf.dmgMult),
        @"timeMult":      @(XG.conf.timeMult),
        @"autoCooldown":  @(XG.conf.autoCooldown),
        @"gameSpeed":     @(XG.conf.gameSpeed),
        @"fastWinMode":   @(XG.conf.fastWinMode),
        @"fastWinCooldown": @(XG.conf.fastWinCooldown),
        @"st.waves":      @(XG.settle.waves),
        @"st.rounds":     @(XG.settle.roundsPerWave),
        @"st.combos":     @(XG.settle.combosPerRound),
        @"st.steps":      @(XG.settle.stepsPerRound),
        @"st.dmin":       @(XG.settle.damageMin),
        @"st.dmax":       @(XG.settle.damageMax),
        @"st.mode":       @(XG.settle.mode),
        @"st.target":     @(XG.settle.targetSeconds),
        @"dryRun":        @(XG.conf.dryRun),
        @"autoStrict":    @(XG.conf.autoStrict),
        @"flags":         flags,
    };
    [[NSUserDefaults standardUserDefaults] setObject:d forKey:kKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

const char *XGFeatureName(XGFeature f) {
    switch (f) {
        case F_AUTO_SOLVE: return "自动转珠";
        case F_INF_SKILL:  return "无限技能";
        case F_GOD_MODE:   return "无敌";
        case F_ONE_HIT:    return "秒杀";
        case F_DMG_MULT:   return "伤害倍率";
        case F_LONG_TIME:  return "转珠加时";
        case F_TIME_SCALE: return "战斗倍速";
        case F_FAST_WIN:   return "快速胜利";
        case F_SETTLE_FAKE:return "结算伪造";
        case F_DEBUG_PROBE:return "字段探测";
        default:           return "?";
    }
}
