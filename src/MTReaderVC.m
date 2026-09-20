//
//  MTReaderVC.m —— 分页阅读器
//  分页：TextKit1 的 NSLayoutManager，一页一个 NSTextContainer，共享同一个 text storage
//        → 分页结果与渲染完全一致，不会串页或漏字
//  翻页：UIPageViewController（仿真翻页 / 平滑滑动 / 无动画）
//  配色：纯色背景 + 自动前景色；亮度用 UIScreen.brightness
//

#import "MTReaderVC.h"

// ============================================================
//  设置项
// ============================================================

static NSString *const kFontSizeKey   = @"reader.fontSize";
static NSString *const kBackgroundKey = @"reader.background";
static NSString *const kBrightnessKey = @"reader.brightness";
static NSString *const kAnimKey       = @"reader.anim";
static NSString *const kProgressKey   = @"reader.progress";

typedef NS_ENUM(NSInteger, MTAnimStyle) {
    MTAnimCurl = 0,     // 仿真翻页
    MTAnimSlide,        // 平滑滑动
    MTAnimNone,         // 直接切换
};

static CGFloat MTFontSize(void) {
    CGFloat v = [[NSUserDefaults standardUserDefaults] doubleForKey:kFontSizeKey];
    return (v >= 12 && v <= 40) ? v : 19.0;
}
static NSInteger MTBackgroundIndex(void) {
    NSInteger v = [[NSUserDefaults standardUserDefaults] integerForKey:kBackgroundKey];
    return (v >= 0 && v < 8) ? v : 1;
}
static MTAnimStyle MTAnimStyleValue(void) {
    NSInteger v = [[NSUserDefaults standardUserDefaults] integerForKey:kAnimKey];
    return (v >= 0 && v <= 2) ? (MTAnimStyle)v : MTAnimCurl;
}
static CGFloat MTBrightness(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d objectForKey:kBrightnessKey] == nil) return UIScreen.mainScreen.brightness;
    return [d doubleForKey:kBrightnessKey];
}

// 8 种纯色背景：0白 1米黄 2护眼绿 3浅灰 4暖粉 5深灰 6夜蓝 7黑
static UIColor *MTBackgroundColorAtIndex(NSInteger i) {
    switch (i) {
        case 0: return [UIColor colorWithRed:1.00 green:1.00 blue:1.00 alpha:1];
        case 1: return [UIColor colorWithRed:0.96 green:0.93 blue:0.86 alpha:1];
        case 2: return [UIColor colorWithRed:0.80 green:0.90 blue:0.80 alpha:1];
        case 3: return [UIColor colorWithRed:0.90 green:0.90 blue:0.92 alpha:1];
        case 4: return [UIColor colorWithRed:0.98 green:0.91 blue:0.88 alpha:1];
        case 5: return [UIColor colorWithRed:0.23 green:0.23 blue:0.25 alpha:1];
        case 6: return [UIColor colorWithRed:0.05 green:0.09 blue:0.14 alpha:1];
        default: return [UIColor colorWithRed:0.00 green:0.00 blue:0.00 alpha:1];
    }
}

static CGFloat MTLuminance(UIColor *c) {
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if (![c getRed:&r green:&g blue:&b alpha:&a]) return 1;
    return 0.299 * r + 0.587 * g + 0.114 * b;
}

/// 背景亮 → 深字；背景暗 → 浅字
static UIColor *MTTextColorFor(UIColor *bg) {
    if (MTLuminance(bg) > 0.60) {
        return [UIColor colorWithRed:0.13 green:0.13 blue:0.15 alpha:1];
    }
    return [UIColor colorWithRed:0.76 green:0.77 blue:0.80 alpha:1];
}

/// 工具栏配色：跟随背景明暗，但稍微拉开层次
static UIColor *MTBarColorFor(UIColor *bg) {
    CGFloat l = MTLuminance(bg);
    if (l > 0.60) return [bg colorWithAlphaComponent:0.96];
    if (l > 0.30) return [bg colorWithAlphaComponent:0.98];
    return [[UIColor colorWithWhite:0.16 alpha:1] colorWithAlphaComponent:0.96];
}

/// 分页边距（正文区域）
static UIEdgeInsets MTPageInsets(void) {
    UIEdgeInsets safe = UIEdgeInsetsZero;
    UIWindow *w = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *win in ((UIWindowScene *)s).windows) {
            if (win.isKeyWindow) { w = win; break; }
        }
        if (w) break;
    }
    if (w) safe = w.safeAreaInsets;
    return UIEdgeInsetsMake(safe.top + 26, 22, safe.bottom + 40, 22);
}

// ============================================================
//  单页绘制视图
// ============================================================

@interface MTPageView : UIView
@property (nonatomic, strong) NSLayoutManager *layoutManager;
@property (nonatomic, strong) NSTextContainer *textContainer;
@property (nonatomic, assign) UIEdgeInsets insets;
@end

@implementation MTPageView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.contentMode = UIViewContentModeRedraw;
    }
    return self;
}

- (void)drawRect:(CGRect)rect {
    if (!self.layoutManager || !self.textContainer) return;
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;
    CGContextSetTextMatrix(ctx, CGAffineTransformIdentity);

    NSRange glyphRange = [self.layoutManager glyphRangeForTextContainer:self.textContainer];
    if (glyphRange.length == 0) return;

    CGPoint origin = CGPointMake(self.insets.left, self.insets.top);
    [self.layoutManager drawBackgroundForGlyphRange:glyphRange atPoint:origin];
    [self.layoutManager drawGlyphsForGlyphRange:glyphRange atPoint:origin];
}

@end

// ============================================================
//  单页容器 VC
// ============================================================

@interface MTPageContentVC : UIViewController
@property (nonatomic, strong) NSLayoutManager *layoutManager;
@property (nonatomic, strong) NSTextContainer *textContainer;
@property (nonatomic, assign) UIEdgeInsets textInsets;
@property (nonatomic, strong) UIColor *pageColor;
@property (nonatomic, assign) NSUInteger chapterIndex;
@property (nonatomic, assign) NSUInteger pageIndex;
@end

@implementation MTPageContentVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = self.pageColor ?: UIColor.whiteColor;
    MTPageView *pv = [[MTPageView alloc] initWithFrame:self.view.bounds];
    pv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    pv.layoutManager = self.layoutManager;
    pv.textContainer = self.textContainer;
    pv.insets = self.textInsets;
    [self.view addSubview:pv];
}

@end

// ============================================================
//  设置面板（字号 / 背景色 / 亮度 / 翻页动画）
// ============================================================

@interface MTSettingsPanel : UIView
@property (nonatomic, copy) void (^onFontDelta)(CGFloat delta);
@property (nonatomic, copy) void (^onColorPick)(NSInteger index);
@property (nonatomic, copy) void (^onBrightness)(CGFloat value);
@property (nonatomic, copy) void (^onAnimPick)(NSInteger index);
- (void)refresh;
@end

@implementation MTSettingsPanel {
    UILabel *_fontLabel;
    NSMutableArray<UIButton *> *_swatches;
    UISlider *_brightness;
    UISegmentedControl *_anim;
    UIColor *_titleColor;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    _swatches = [NSMutableArray array];

    // ---- 字号 ----
    UILabel *fontTitle = [self label:@"字号"];
    UIButton *minus = [self pill:@"A-" action:@selector(fontMinus)];
    UIButton *plus  = [self pill:@"A+" action:@selector(fontPlus)];
    _fontLabel = [self label:@"19"];
    _fontLabel.textAlignment = NSTextAlignmentCenter;
    _fontLabel.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightMedium];

    UIStackView *fontRow = [[UIStackView alloc] initWithArrangedSubviews:
                            @[fontTitle, minus, _fontLabel, plus]];
    fontRow.axis = UILayoutConstraintAxisHorizontal;
    fontRow.spacing = 8;
    fontRow.alignment = UIStackViewAlignmentCenter;
    [fontTitle.widthAnchor constraintEqualToConstant:44].active = YES;
    [minus.widthAnchor constraintEqualToConstant:48].active = YES;
    [plus.widthAnchor constraintEqualToConstant:48].active = YES;
    [_fontLabel.widthAnchor constraintEqualToConstant:44].active = YES;

    // ---- 背景色 ----
    UILabel *bgTitle = [self label:@"底色"];
    UIStackView *colorRow = [[UIStackView alloc] init];
    colorRow.axis = UILayoutConstraintAxisHorizontal;
    colorRow.spacing = 8;
    colorRow.alignment = UIStackViewAlignmentCenter;
    colorRow.distribution = UIStackViewDistributionFillEqually;
    for (NSInteger i = 0; i < 8; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.backgroundColor = MTBackgroundColorAtIndex(i);
        b.layer.cornerRadius = 15;
        b.layer.borderWidth = 1;
        b.layer.borderColor = [UIColor colorWithWhite:0.5 alpha:0.35].CGColor;
        b.tag = i;
        b.translatesAutoresizingMaskIntoConstraints = NO;
        [b.heightAnchor constraintEqualToConstant:30].active = YES;
        [b addTarget:self action:@selector(colorTapped:) forControlEvents:UIControlEventTouchUpInside];
        [_swatches addObject:b];
        [colorRow addArrangedSubview:b];
    }
    UIStackView *bgRow = [[UIStackView alloc] initWithArrangedSubviews:@[bgTitle, colorRow]];
    bgRow.axis = UILayoutConstraintAxisHorizontal;
    bgRow.spacing = 8;
    bgRow.alignment = UIStackViewAlignmentCenter;
    [bgTitle.widthAnchor constraintEqualToConstant:44].active = YES;

    // ---- 亮度 ----
    UILabel *sun = [self label:@"☀️"];
    sun.font = [UIFont systemFontOfSize:15];
    _brightness = [[UISlider alloc] init];
    _brightness.minimumValue = 0.0;
    _brightness.maximumValue = 1.0;
    _brightness.value = MTBrightness();
    [_brightness addTarget:self action:@selector(brightnessChanged)
          forControlEvents:UIControlEventValueChanged];
    UILabel *moon = [self label:@"🌙"];
    moon.font = [UIFont systemFontOfSize:15];

    UIStackView *brightRow = [[UIStackView alloc] initWithArrangedSubviews:@[sun, _brightness, moon]];
    brightRow.axis = UILayoutConstraintAxisHorizontal;
    brightRow.spacing = 8;
    brightRow.alignment = UIStackViewAlignmentCenter;
    [sun.widthAnchor constraintEqualToConstant:24].active = YES;
    [moon.widthAnchor constraintEqualToConstant:24].active = YES;

    // ---- 翻页动画 ----
    _anim = [[UISegmentedControl alloc] initWithItems:@[@"仿真翻页", @"平滑滑动", @"无动画"]];
    _anim.selectedSegmentIndex = MTAnimStyleValue();
    [_anim addTarget:self action:@selector(animChanged)
    forControlEvents:UIControlEventValueChanged];

    UIStackView *col = [[UIStackView alloc] initWithArrangedSubviews:
                        @[fontRow, bgRow, brightRow, _anim]];
    col.axis = UILayoutConstraintAxisVertical;
    col.spacing = 12;
    col.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:col];
    [NSLayoutConstraint activateConstraints:@[
        [col.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
        [col.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
        [col.topAnchor constraintEqualToAnchor:self.topAnchor constant:12],
        [col.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-12],
    ]];
    return self;
}

- (UILabel *)label:(NSString *)text {
    UILabel *l = [[UILabel alloc] init];
    l.text = text;
    l.font = [UIFont systemFontOfSize:13];
    l.translatesAutoresizingMaskIntoConstraints = NO;
    return l;
}

- (UIButton *)pill:(NSString *)title action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    b.layer.cornerRadius = 8;
    b.layer.borderWidth = 1;
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b.heightAnchor constraintEqualToConstant:32].active = YES;
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)setTintColor:(UIColor *)tintColor {
    [super setTintColor:tintColor];
    _titleColor = tintColor;
    [self refresh];
}

- (void)refresh {
    UIColor *c = _titleColor ?: UIColor.labelColor;
    _fontLabel.text = [NSString stringWithFormat:@"%.0f", MTFontSize()];
    for (UIView *v in self.subviews) {
        [self applyColor:c to:v];
    }
    NSInteger sel = MTBackgroundIndex();
    for (UIButton *b in _swatches) {
        b.layer.borderWidth = (b.tag == sel) ? 3 : 1;
        b.layer.borderColor = (b.tag == sel) ? c.CGColor
                                             : [UIColor colorWithWhite:0.5 alpha:0.35].CGColor;
    }
    _anim.selectedSegmentIndex = MTAnimStyleValue();
    _brightness.value = MTBrightness();
}

- (void)applyColor:(UIColor *)c to:(UIView *)v {
    if ([v isKindOfClass:UILabel.class] && v != _fontLabel) {
        [(UILabel *)v setTextColor:c];
    } else if ([v isKindOfClass:UIButton.class]) {
        UIButton *b = (UIButton *)v;
        if (![_swatches containsObject:b]) {
            [b setTitleColor:c forState:UIControlStateNormal];
            b.layer.borderColor = [c colorWithAlphaComponent:0.4].CGColor;
        }
    } else if ([v isKindOfClass:UISegmentedControl.class]) {
        [(UISegmentedControl *)v setTitleTextAttributes:@{NSForegroundColorAttributeName: c}
                                               forState:UIControlStateNormal];
    }
    for (UIView *sub in v.subviews) [self applyColor:c to:sub];
}

- (void)fontMinus { if (self.onFontDelta) self.onFontDelta(-1); }
- (void)fontPlus  { if (self.onFontDelta) self.onFontDelta(1); }
- (void)colorTapped:(UIButton *)b { if (self.onColorPick) self.onColorPick(b.tag); }
- (void)brightnessChanged { if (self.onBrightness) self.onBrightness(_brightness.value); }
- (void)animChanged { if (self.onAnimPick) self.onAnimPick(_anim.selectedSegmentIndex); }

@end

// ============================================================
//  章节目录
// ============================================================

@interface MTChapterListVC : UITableViewController
@property (nonatomic, strong) MTBook *book;
@property (nonatomic, assign) NSUInteger current;
@property (nonatomic, copy)   void (^onPick)(NSUInteger index);
@end

@implementation MTChapterListVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"目录";
    self.tableView.rowHeight = 48;
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                      target:self
                                                      action:@selector(close)];
}

- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return self.book.chapters.count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"c"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                            reuseIdentifier:@"c"];
    cell.textLabel.text = self.book.chapters[ip.row].title;
    cell.textLabel.font = [UIFont systemFontOfSize:15];
    cell.accessoryType = (ip.row == self.current)
        ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (self.onPick) self.onPick(ip.row);
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

// ============================================================
//  一章的排版结果
// ============================================================

@interface MTChapterLayout : NSObject
@property (nonatomic, strong) NSTextStorage *storage;
@property (nonatomic, strong) NSLayoutManager *layoutManager;
@property (nonatomic, strong) NSArray<NSTextContainer *> *containers;
@property (nonatomic, strong) NSArray<NSValue *> *ranges;
@end

@implementation MTChapterLayout
@end

// ============================================================
//  阅读器
// ============================================================

@interface MTReaderVC () <UIPageViewControllerDataSource, UIPageViewControllerDelegate, UIGestureRecognizerDelegate>
@property (nonatomic, strong) MTBook *book;
@property (nonatomic, strong) UIPageViewController *pageVC;
@property (nonatomic, strong) UIView *topBar;
@property (nonatomic, strong) UIView *bottomBar;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *progressLabel;
@property (nonatomic, strong) MTSettingsPanel *settingsPanel;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, MTChapterLayout *> *layouts;

@property (nonatomic, assign) NSUInteger chapterIndex;
@property (nonatomic, assign) NSUInteger pageIndex;
@property (nonatomic, assign) BOOL barsHidden;
@property (nonatomic, assign) BOOL settingsShown;
@property (nonatomic, assign) BOOL restoring;

@property (nonatomic, assign) CGSize pageSize;      // 正文区尺寸
@property (nonatomic, assign) UIEdgeInsets pageInsets;
@property (nonatomic, assign) CGSize lastLayoutSize;
@end

@implementation MTReaderVC

- (instancetype)initWithBook:(MTBook *)book {
    self = [super init];
    if (self) {
        _book = book;
        _chapterIndex = 0;
        _pageIndex = 0;
        _layouts = [NSMutableDictionary dictionary];
    }
    return self;
}

// ---------------- 生命周期 ----------------

- (void)viewDidLoad {
    [super viewDidLoad];

    UIColor *bg = MTBackgroundColorAtIndex(MTBackgroundIndex());
    self.view.backgroundColor = bg;

    // ---- 分页容器 ----
    [self buildPageViewController];

    // ---- 顶栏 ----
    self.topBar = [[UIView alloc] init];
    self.topBar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.topBar];

    UIButton *back = [self barButton:@"‹ 书架" action:@selector(goBack)];
    UIButton *toc  = [self barButton:@"目录" action:@selector(showTOC)];
    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
    self.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.topBar addSubview:back];
    [self.topBar addSubview:toc];
    [self.topBar addSubview:self.titleLabel];

    // ---- 底栏 ----
    self.bottomBar = [[UIView alloc] init];
    self.bottomBar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.bottomBar];

    UIButton *prev = [self barButton:@"上一章" action:@selector(prevChapter)];
    UIButton *next = [self barButton:@"下一章" action:@selector(nextChapter)];
    UIButton *set  = [self barButton:@"设置" action:@selector(toggleSettings)];
    UIStackView *row1 = [[UIStackView alloc] initWithArrangedSubviews:@[prev, next, set]];
    row1.distribution = UIStackViewDistributionFillEqually;
    row1.translatesAutoresizingMaskIntoConstraints = NO;
    [self.bottomBar addSubview:row1];

    self.progressLabel = [[UILabel alloc] init];
    self.progressLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightRegular];
    self.progressLabel.textAlignment = NSTextAlignmentCenter;
    self.progressLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.bottomBar addSubview:self.progressLabel];

    self.settingsPanel = [[MTSettingsPanel alloc] initWithFrame:CGRectZero];
    self.settingsPanel.translatesAutoresizingMaskIntoConstraints = NO;
    self.settingsPanel.hidden = YES;
    self.settingsPanel.layer.cornerRadius = 14;
    self.settingsPanel.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    self.settingsPanel.clipsToBounds = YES;
    // 注意：必须挂在 self.view 上，不能挂在底栏上。
    // 面板位置在底栏上方（超出底栏 bounds），而 hitTest 不会命中超出父视图范围的子视图，
    // 挂错地方会导致点击穿透到下层页面 → 变成翻页。
    [self.view addSubview:self.settingsPanel];
    __weak typeof(self) ws = self;
    self.settingsPanel.onFontDelta = ^(CGFloat d) { [ws changeFontBy:d]; };
    self.settingsPanel.onColorPick = ^(NSInteger i) { [ws applyBackgroundIndex:i]; };
    self.settingsPanel.onBrightness = ^(CGFloat v) {
        [[NSUserDefaults standardUserDefaults] setDouble:v forKey:kBrightnessKey];
        UIScreen.mainScreen.brightness = v;
    };
    self.settingsPanel.onAnimPick = ^(NSInteger i) { [ws applyAnimStyle:(MTAnimStyle)i]; };

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.topBar.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.topBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.topBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.topBar.bottomAnchor constraintEqualToAnchor:safe.topAnchor constant:44],

        [back.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:8],
        [back.centerYAnchor constraintEqualToAnchor:safe.topAnchor constant:22],
        [toc.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-8],
        [toc.centerYAnchor constraintEqualToAnchor:safe.topAnchor constant:22],
        [self.titleLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.titleLabel.centerYAnchor constraintEqualToAnchor:safe.topAnchor constant:22],
        [self.titleLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:back.trailingAnchor constant:8],
        [self.titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:toc.leadingAnchor constant:-8],

        [self.bottomBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.bottomBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.bottomBar.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.bottomBar.topAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-92],

        [row1.leadingAnchor constraintEqualToAnchor:self.bottomBar.leadingAnchor constant:8],
        [row1.trailingAnchor constraintEqualToAnchor:self.bottomBar.trailingAnchor constant:-8],
        [row1.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-8],
        [row1.heightAnchor constraintEqualToConstant:44],

        [self.progressLabel.leadingAnchor constraintEqualToAnchor:self.bottomBar.leadingAnchor constant:16],
        [self.progressLabel.trailingAnchor constraintEqualToAnchor:self.bottomBar.trailingAnchor constant:-16],
        [self.progressLabel.bottomAnchor constraintEqualToAnchor:row1.topAnchor constant:-6],

        [self.settingsPanel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.settingsPanel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.settingsPanel.bottomAnchor constraintEqualToAnchor:self.bottomBar.topAnchor constant:-6],
    ]];

    [self applyColors];
    [self restoreProgress];
    [self showChapter:self.chapterIndex page:self.pageIndex animated:NO direction:UIPageViewControllerNavigationDirectionForward];
    [self hideBarsAnimated:NO];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    UIScreen.mainScreen.brightness = MTBrightness();
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self saveProgress];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGSize newSize = [self contentSize];
    if (CGSizeEqualToSize(newSize, self.lastLayoutSize)) return;
    if (self.lastLayoutSize.width > 0 && newSize.width > 0) {
        self.lastLayoutSize = newSize;
        [self repaginateKeepingPosition];
    } else {
        self.lastLayoutSize = newSize;
    }
}

// ---------------- 分页核心 ----------------

- (UIEdgeInsets)pageInsetsNow {
    return MTPageInsets();
}

/// 正文区用的尺寸（决定一页能放多少字）
- (CGSize)contentSize {
    UIEdgeInsets in = [self pageInsetsNow];
    CGSize s = self.view.bounds.size;
    CGFloat w = s.width - in.left - in.right;
    CGFloat h = s.height - in.top - in.bottom;
    if (w < 80) w = 80;
    if (h < 80) h = 80;
    return CGSizeMake(w, h);
}

- (MTChapterLayout *)layoutForChapter:(NSUInteger)index {
    if (index >= self.book.chapters.count) return nil;
    MTChapterLayout *cached = self.layouts[@(index)];
    if (cached) return cached;

    CGSize size = [self contentSize];
    UIColor *bg = MTBackgroundColorAtIndex(MTBackgroundIndex());
    UIColor *fg = MTTextColorFor(bg);
    CGFloat fontSize = MTFontSize();

    NSAttributedString *attr = [self.book attributedTextForChapter:index
                                                          fontSize:fontSize
                                                             color:fg
                                                           maxSize:size];
    if (attr.length == 0) {
        attr = [[NSAttributedString alloc] initWithString:@"（本章没有可显示的内容）"
                                             attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:fontSize]}];
    }

    NSTextStorage *ts = [[NSTextStorage alloc] initWithAttributedString:attr];
    NSLayoutManager *lm = [[NSLayoutManager alloc] init];
    [ts addLayoutManager:lm];

    NSMutableArray<NSTextContainer *> *containers = [NSMutableArray array];
    NSMutableArray<NSValue *> *ranges = [NSMutableArray array];

    NSUInteger guard = 0;
    while (YES) {
        if (guard++ > 4000) break;                       // 极端情况保护
        if (ranges.count > 0 &&
            NSMaxRange(ranges.lastObject.rangeValue) >= ts.length) break;

        NSTextContainer *tc = [[NSTextContainer alloc] initWithSize:size];
        tc.lineFragmentPadding = 0;
        [lm addTextContainer:tc];

        NSRange glyphRange = [lm glyphRangeForTextContainer:tc];
        NSRange charRange = [lm characterRangeForGlyphRange:glyphRange
                                           actualGlyphRange:NULL];
        if (charRange.length == 0) {
            [lm removeTextContainerAtIndex:lm.textContainers.count - 1];
            break;
        }
        [containers addObject:tc];
        [ranges addObject:[NSValue valueWithRange:charRange]];
    }
    if (ranges.count == 0) {
        [containers addObject:[[NSTextContainer alloc] initWithSize:size]];
        [ranges addObject:[NSValue valueWithRange:NSMakeRange(0, 0)]];
        [lm addTextContainer:containers.lastObject];
    }

    MTChapterLayout *lay = [MTChapterLayout new];
    lay.storage = ts;
    lay.layoutManager = lm;
    lay.containers = containers;
    lay.ranges = ranges;
    self.layouts[@(index)] = lay;

    // 缓存不要太贪心
    if (self.layouts.count > 4) {
        for (NSNumber *k in self.layouts.allKeys) {
            NSInteger d = labs((long)k.integerValue - (long)index);
            if (d > 1) [self.layouts removeObjectForKey:k];
        }
    }
    return lay;
}

- (void)clearLayouts {
    [self.layouts removeAllObjects];
}

- (MTPageContentVC *)contentVCForChapter:(NSUInteger)ch page:(NSUInteger)pg {
    MTChapterLayout *lay = [self layoutForChapter:ch];
    if (!lay || pg >= lay.containers.count) return nil;

    UIColor *bg = MTBackgroundColorAtIndex(MTBackgroundIndex());
    MTPageContentVC *vc = [[MTPageContentVC alloc] init];
    vc.layoutManager = lay.layoutManager;
    vc.textContainer = lay.containers[pg];
    vc.textInsets = [self pageInsetsNow];
    vc.pageColor = bg;
    vc.chapterIndex = ch;
    vc.pageIndex = pg;
    return vc;
}

- (void)showChapter:(NSUInteger)ch page:(NSUInteger)pg
           animated:(BOOL)animated
          direction:(UIPageViewControllerNavigationDirection)dir {
    if (self.book.chapters.count == 0) return;
    if (ch >= self.book.chapters.count) ch = self.book.chapters.count - 1;

    MTChapterLayout *lay = [self layoutForChapter:ch];
    NSUInteger count = lay ? lay.ranges.count : 0;
    if (count == 0) count = 1;
    if (pg >= count) pg = count - 1;

    MTPageContentVC *vc = [self contentVCForChapter:ch page:pg];
    if (!vc) return;

    self.chapterIndex = ch;
    self.pageIndex = pg;

    __weak typeof(self) ws = self;
    [self.pageVC setViewControllers:@[vc] direction:dir animated:animated
                         completion:^(BOOL finished) { [ws updateChrome]; }];

    [self updateChrome];
    [self prewarmNeighbours];
}

- (void)prewarmNeighbours {
    NSUInteger ch = self.chapterIndex;
    MTChapterLayout *lay = self.layouts[@(ch)];
    NSUInteger count = lay ? lay.ranges.count : 0;
    if (count == 0 || self.pageIndex + 2 < count) return;

    NSMutableArray<NSNumber *> *todo = [NSMutableArray array];
    if (ch + 1 < self.book.chapters.count) [todo addObject:@(ch + 1)];
    if (ch > 0) [todo addObject:@(ch - 1)];
    if (todo.count == 0) return;

    __weak typeof(self) ws = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        typeof(self) ss = ws;
        if (!ss) return;
        for (NSNumber *n in todo) [ss layoutForChapter:n.unsignedIntegerValue];
    });
}

// ---------------- 翻页 ----------------

- (nullable UIViewController *)pageViewController:(UIPageViewController *)pvc
                    viewControllerBeforeViewController:(MTPageContentVC *)vc {
    if (vc.pageIndex > 0) return [self contentVCForChapter:vc.chapterIndex page:vc.pageIndex - 1];
    if (vc.chapterIndex > 0) {
        NSUInteger prev = vc.chapterIndex - 1;
        MTChapterLayout *lay = [self layoutForChapter:prev];
        if (!lay || lay.ranges.count == 0) return nil;
        return [self contentVCForChapter:prev page:lay.ranges.count - 1];
    }
    return nil;
}

- (nullable UIViewController *)pageViewController:(UIPageViewController *)pvc
                     viewControllerAfterViewController:(MTPageContentVC *)vc {
    MTChapterLayout *lay = [self layoutForChapter:vc.chapterIndex];
    if (lay && vc.pageIndex + 1 < lay.ranges.count) {
        return [self contentVCForChapter:vc.chapterIndex page:vc.pageIndex + 1];
    }
    if (vc.chapterIndex + 1 < self.book.chapters.count) {
        MTPageContentVC *next = [self contentVCForChapter:vc.chapterIndex + 1 page:0];
        if (next) return next;
    }
    return nil;
}

- (void)pageViewController:(UIPageViewController *)pvc
       didFinishAnimating:(BOOL)finished
  previousViewControllers:(NSArray<UIViewController *> *)previous
      transitionCompleted:(BOOL)completed {
    if (!completed) return;
    MTPageContentVC *cur = pvc.viewControllers.firstObject;
    if ([cur isKindOfClass:MTPageContentVC.class]) {
        self.chapterIndex = cur.chapterIndex;
        self.pageIndex = cur.pageIndex;
    }
    [self updateChrome];
    [self saveProgress];
    [self prewarmNeighbours];
}

- (void)turnPage:(BOOL)forward {
    MTChapterLayout *lay = self.layouts[@(self.chapterIndex)];
    NSUInteger count = lay ? lay.ranges.count : 0;

    if (forward) {
        if (self.pageIndex + 1 < count) {
            [self jumpTo:self.chapterIndex page:self.pageIndex + 1
             animated:[self animates] direction:UIPageViewControllerNavigationDirectionForward];
        } else if (self.chapterIndex + 1 < self.book.chapters.count) {
            [self jumpTo:self.chapterIndex + 1 page:0
             animated:[self animates] direction:UIPageViewControllerNavigationDirectionForward];
        }
    } else {
        if (self.pageIndex > 0) {
            [self jumpTo:self.chapterIndex page:self.pageIndex - 1
             animated:[self animates] direction:UIPageViewControllerNavigationDirectionReverse];
        } else if (self.chapterIndex > 0) {
            NSUInteger prev = self.chapterIndex - 1;
            MTChapterLayout *pl = [self layoutForChapter:prev];
            NSUInteger last = pl && pl.ranges.count ? pl.ranges.count - 1 : 0;
            [self jumpTo:prev page:last
             animated:[self animates] direction:UIPageViewControllerNavigationDirectionReverse];
        }
    }
}

- (BOOL)animates { return MTAnimStyleValue() != MTAnimNone; }

- (void)jumpTo:(NSUInteger)ch page:(NSUInteger)pg
    animated:(BOOL)animated
   direction:(UIPageViewControllerNavigationDirection)dir {
    [self showChapter:ch page:pg animated:animated direction:dir];
    [self saveProgress];
}

- (void)prevChapter {
    if (self.chapterIndex == 0) return;
    [self jumpTo:self.chapterIndex - 1 page:0
     animated:[self animates] direction:UIPageViewControllerNavigationDirectionReverse];
}

- (void)nextChapter {
    if (self.chapterIndex + 1 >= self.book.chapters.count) return;
    [self jumpTo:self.chapterIndex + 1 page:0
     animated:[self animates] direction:UIPageViewControllerNavigationDirectionForward];
}

// ---------------- 设置 ----------------

- (void)applyColors {
    UIColor *bg = MTBackgroundColorAtIndex(MTBackgroundIndex());
    UIColor *bar = MTBarColorFor(bg);
    UIColor *fg = MTTextColorFor(bar);
    self.view.backgroundColor = bg;
    self.topBar.backgroundColor = bar;
    self.bottomBar.backgroundColor = bar;
    self.settingsPanel.backgroundColor = bar;
    self.titleLabel.textColor = fg;
    self.progressLabel.textColor = fg;
    self.settingsPanel.tintColor = fg;
    [self recolorButtonsIn:self.topBar color:fg];
    [self recolorButtonsIn:self.bottomBar color:fg];
    [self setNeedsStatusBarAppearanceUpdate];
}

- (void)recolorButtonsIn:(UIView *)root color:(UIColor *)c {
    for (UIView *v in root.subviews) {
        if ([v isKindOfClass:UIButton.class]) {
            [(UIButton *)v setTitleColor:c forState:UIControlStateNormal];
        } else if ([v isKindOfClass:UIStackView.class]) {
            [self recolorButtonsIn:v color:c];
        }
    }
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    UIColor *bg = MTBackgroundColorAtIndex(MTBackgroundIndex());
    return MTLuminance(bg) > 0.6 ? UIStatusBarStyleDarkContent : UIStatusBarStyleLightContent;
}

- (void)applyBackgroundIndex:(NSInteger)index {
    [[NSUserDefaults standardUserDefaults] setInteger:index forKey:kBackgroundKey];
    [self applyColors];
    [self.settingsPanel refresh];

    // 只换颜色不用重新分页：直接刷新所有已排版章节的前景色
    UIColor *fg = MTTextColorFor(MTBackgroundColorAtIndex(index));
    for (NSNumber *k in self.layouts.allKeys) {
        MTChapterLayout *lay = self.layouts[k];
        [lay.storage addAttribute:NSForegroundColorAttributeName
                            value:fg
                            range:NSMakeRange(0, lay.storage.length)];
    }
    // 重建当前页（容器 VC 的底色也要换）
    [self showChapter:self.chapterIndex page:self.pageIndex animated:NO
            direction:UIPageViewControllerNavigationDirectionForward];
}

- (void)changeFontBy:(CGFloat)delta {
    CGFloat v = MTFontSize() + delta;
    v = MAX(12, MIN(40, v));
    [[NSUserDefaults standardUserDefaults] setDouble:v forKey:kFontSizeKey];
    [self.settingsPanel refresh];
    [self repaginateKeepingPosition];
}

- (NSUInteger)charOffsetOfCurrentPage {
    MTChapterLayout *lay = self.layouts[@(self.chapterIndex)];
    if (!lay || self.pageIndex >= lay.ranges.count) return 0;
    return lay.ranges[self.pageIndex].rangeValue.location;
}

- (NSUInteger)pageForCharOffset:(NSUInteger)offset chapter:(NSUInteger)ch {
    MTChapterLayout *lay = [self layoutForChapter:ch];
    if (!lay) return 0;
    for (NSUInteger i = 0; i < lay.ranges.count; i++) {
        NSRange r = lay.ranges[i].rangeValue;
        if (offset >= r.location && offset < NSMaxRange(r)) return i;
        if (offset < r.location) return i;
    }
    return lay.ranges.count ? lay.ranges.count - 1 : 0;
}

- (void)repaginateKeepingPosition {
    NSUInteger ch = self.chapterIndex;
    NSUInteger offset = [self charOffsetOfCurrentPage];
    [self clearLayouts];
    MTChapterLayout *lay = [self layoutForChapter:ch];
    if (!lay) return;
    NSUInteger page = [self pageForCharOffset:offset chapter:ch];
    [self showChapter:ch page:page animated:NO
            direction:UIPageViewControllerNavigationDirectionForward];
}

- (void)applyAnimStyle:(MTAnimStyle)style {
    [[NSUserDefaults standardUserDefaults] setInteger:style forKey:kAnimKey];
    [self buildPageViewController];
    [self showChapter:self.chapterIndex page:self.pageIndex animated:NO
            direction:UIPageViewControllerNavigationDirectionForward];
    [self.settingsPanel refresh];
}

- (void)buildPageViewController {
    if (self.pageVC) {
        [self.pageVC willMoveToParentViewController:nil];
        [self.pageVC.view removeFromSuperview];
        [self.pageVC removeFromParentViewController];
        self.pageVC = nil;
    }
    MTAnimStyle style = MTAnimStyleValue();
    UIPageViewControllerTransitionStyle ts =
        (style == MTAnimCurl) ? UIPageViewControllerTransitionStylePageCurl
                              : UIPageViewControllerTransitionStyleScroll;

    UIPageViewController *pvc = [[UIPageViewController alloc]
        initWithTransitionStyle:ts
          navigationOrientation:UIPageViewControllerNavigationOrientationHorizontal
                        options:nil];
    pvc.dataSource = self;
    pvc.delegate = self;
    if (ts == UIPageViewControllerTransitionStylePageCurl) {
        pvc.doubleSided = NO;
    }

    [self addChildViewController:pvc];
    pvc.view.frame = self.view.bounds;
    pvc.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view insertSubview:pvc.view atIndex:0];
    [pvc didMoveToParentViewController:self];
    self.pageVC = pvc;

    // 「无动画」模式：关掉系统翻页手势，改用自己的手势
    if (style == MTAnimNone) {
        for (UIGestureRecognizer *g in pvc.gestureRecognizers) g.enabled = NO;
        for (UIView *sub in pvc.view.subviews) {
            if ([sub isKindOfClass:UIScrollView.class]) {
                UIScrollView *sv = (UIScrollView *)sub;
                sv.scrollEnabled = NO;
                sv.panGestureRecognizer.enabled = NO;
            }
        }
    }

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                         action:@selector(pageTapped:)];
    tap.delegate = self;
    [self.pageVC.view addGestureRecognizer:tap];

    if (style == MTAnimNone) {
        UISwipeGestureRecognizer *l = [[UISwipeGestureRecognizer alloc] initWithTarget:self
                                                                               action:@selector(pageSwiped:)];
        l.direction = UISwipeGestureRecognizerDirectionLeft;
        [self.pageVC.view addGestureRecognizer:l];
        UISwipeGestureRecognizer *r = [[UISwipeGestureRecognizer alloc] initWithTarget:self
                                                                               action:@selector(pageSwiped:)];
        r.direction = UISwipeGestureRecognizerDirectionRight;
        [self.pageVC.view addGestureRecognizer:r];
    }
}

// ---------------- 交互 ----------------

- (void)pageTapped:(UITapGestureRecognizer *)g {
    CGPoint p = [g locationInView:self.pageVC.view];
    CGFloat w = self.pageVC.view.bounds.size.width;
    if (p.x < w * 0.28) {
        [self turnPage:NO];
    } else if (p.x > w * 0.72) {
        [self turnPage:YES];
    } else {
        [self toggleBars];
    }
}

- (void)pageSwiped:(UISwipeGestureRecognizer *)g {
    [self turnPage:(g.direction == UISwipeGestureRecognizerDirectionLeft)];
}

- (void)goBack {
    [self saveProgress];
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)toggleBars {
    if (self.barsHidden) [self showBars]; else [self hideBarsAnimated:YES];
}

- (void)toggleSettings {
    self.settingsShown = !self.settingsShown;
    self.settingsPanel.hidden = !self.settingsShown;
    if (self.settingsShown) [self.settingsPanel refresh];
}

- (void)showBars {
    self.barsHidden = NO;
    self.topBar.hidden = NO;
    self.bottomBar.hidden = NO;
    self.topBar.alpha = 0;
    self.bottomBar.alpha = 0;
    [UIView animateWithDuration:0.2 animations:^{
        self.topBar.alpha = 1;
        self.bottomBar.alpha = 1;
    }];
    [self updateChrome];
}

- (void)hideBarsAnimated:(BOOL)animated {
    self.barsHidden = YES;
    self.settingsShown = NO;
    self.settingsPanel.hidden = YES;
    void (^done)(void) = ^{
        self.topBar.hidden = YES;
        self.bottomBar.hidden = YES;
    };
    if (!animated) { done(); return; }
    [UIView animateWithDuration:0.2 animations:^{
        self.topBar.alpha = 0;
        self.bottomBar.alpha = 0;
    } completion:^(BOOL f) { done(); }];
}

- (void)showTOC {
    MTChapterListVC *toc = [[MTChapterListVC alloc] initWithStyle:UITableViewStylePlain];
    toc.book = self.book;
    toc.current = self.chapterIndex;
    __weak typeof(self) ws = self;
    toc.onPick = ^(NSUInteger idx) {
        [ws jumpTo:idx page:0 animated:NO direction:UIPageViewControllerNavigationDirectionForward];
    };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:toc];
    [self presentViewController:nav animated:YES completion:nil];
}

- (UIButton *)barButton:(NSString *)title action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    return b;
}

// ---------------- 进度 ----------------

- (void)updateChrome {
    MTChapterLayout *lay = self.layouts[@(self.chapterIndex)];
    NSUInteger pages = lay ? lay.ranges.count : 1;
    if (pages == 0) pages = 1;
    NSUInteger total = self.book.chapters.count;
    CGFloat within = (CGFloat)(self.pageIndex + 1) / (CGFloat)pages;
    CGFloat pct = ((CGFloat)self.chapterIndex + within) / (CGFloat)MAX(total, (NSUInteger)1) * 100.0;

    self.titleLabel.text = [NSString stringWithFormat:@"%@ · %@",
                            self.book.title ?: @"",
                            self.book.chapters[self.chapterIndex].title ?: @""];
    self.progressLabel.text = [NSString stringWithFormat:@"%lu/%lu 章 · 第 %lu/%lu 页 · %.0f%%",
                               (unsigned long)(self.chapterIndex + 1), (unsigned long)total,
                               (unsigned long)(self.pageIndex + 1), (unsigned long)pages, pct];
}

- (NSString *)progressKey {
    return [self.book.path.lastPathComponent stringByAppendingString:@"#progress"];
}

- (void)saveProgress {
    if (self.restoring) return;
    NSDictionary *v = @{@"chapter": @(self.chapterIndex), @"page": @(self.pageIndex)};
    [[NSUserDefaults standardUserDefaults] setObject:v forKey:[self progressKey]];
}

- (void)restoreProgress {
    self.restoring = YES;
    NSDictionary *v = [[NSUserDefaults standardUserDefaults] dictionaryForKey:[self progressKey]];
    if (v) {
        NSInteger ch = [v[@"chapter"] integerValue];
        NSInteger pg = [v[@"page"] integerValue];
        if (ch >= 0 && (NSUInteger)ch < self.book.chapters.count) self.chapterIndex = (NSUInteger)ch;
        if (pg >= 0) self.pageIndex = (NSUInteger)pg;
    }
    self.restoring = NO;
}

@end
