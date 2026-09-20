//
//  MTReaderVC.m —— 阅读界面
//  滚动阅读 + 章节切换 + 字号/主题调节 + 进度记忆
//

#import "MTReaderVC.h"

// ---------------- 全局设置 ----------------

static NSString *const kFontSizeKey = @"reader.fontSize";
static NSString *const kThemeKey    = @"reader.theme";
static NSString *const kProgressKey = @"reader.progress";

static CGFloat MTReaderFontSize(void) {
    CGFloat v = [[NSUserDefaults standardUserDefaults] doubleForKey:kFontSizeKey];
    return (v >= 12 && v <= 34) ? v : 19.0;
}
static void MTSetReaderFontSize(CGFloat v) {
    [[NSUserDefaults standardUserDefaults] setDouble:v forKey:kFontSizeKey];
}
static MTReaderTheme MTReaderCurrentTheme(void) {
    NSInteger v = [[NSUserDefaults standardUserDefaults] integerForKey:kThemeKey];
    return (v >= 0 && v <= 2) ? (MTReaderTheme)v : MTReaderThemeLight;
}
static void MTSetReaderTheme(MTReaderTheme t) {
    [[NSUserDefaults standardUserDefaults] setInteger:t forKey:kThemeKey];
}

static UIColor *MTBackgroundColor(MTReaderTheme t) {
    switch (t) {
        case MTReaderThemeSepia: return [UIColor colorWithRed:0.96 green:0.93 blue:0.85 alpha:1];
        case MTReaderThemeDark:  return [UIColor colorWithRed:0.07 green:0.07 blue:0.08 alpha:1];
        default:                 return [UIColor colorWithRed:0.99 green:0.99 blue:1.00 alpha:1];
    }
}
static UIColor *MTTextColor(MTReaderTheme t) {
    switch (t) {
        case MTReaderThemeSepia: return [UIColor colorWithRed:0.27 green:0.23 blue:0.17 alpha:1];
        case MTReaderThemeDark:  return [UIColor colorWithRed:0.74 green:0.75 blue:0.78 alpha:1];
        default:                 return [UIColor colorWithRed:0.11 green:0.11 blue:0.13 alpha:1];
    }
}
static UIColor *MTBarColor(MTReaderTheme t) {
    switch (t) {
        case MTReaderThemeSepia: return [UIColor colorWithRed:0.90 green:0.86 blue:0.77 alpha:0.97];
        case MTReaderThemeDark:  return [UIColor colorWithRed:0.14 green:0.14 blue:0.16 alpha:0.97];
        default:                 return [UIColor colorWithRed:0.96 green:0.96 blue:0.97 alpha:0.97];
    }
}

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
    MTChapter *ch = self.book.chapters[ip.row];
    cell.textLabel.text = ch.title;
    cell.textLabel.font = [UIFont systemFontOfSize:15];
    cell.textLabel.numberOfLines = 1;
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
//  阅读器
// ============================================================

@interface MTReaderVC () <UIGestureRecognizerDelegate, UITextViewDelegate>
@property (nonatomic, strong) MTBook *book;
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) UIView *topBar;
@property (nonatomic, strong) UIView *bottomBar;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *progressLabel;
@property (nonatomic, assign) NSUInteger chapterIndex;
@property (nonatomic, assign) CGFloat pendingRestoreRatio;
@property (nonatomic, assign) BOOL barsHidden;
@end

@implementation MTReaderVC

- (instancetype)initWithBook:(MTBook *)book {
    self = [super init];
    if (self) {
        _book = book;
        _chapterIndex = 0;
        _pendingRestoreRatio = -1;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    MTReaderTheme theme = MTReaderCurrentTheme();
    self.view.backgroundColor = MTBackgroundColor(theme);

    // ---- 正文 ----
    self.textView = [[UITextView alloc] initWithFrame:self.view.bounds];
    self.textView.editable = NO;
    self.textView.selectable = YES;
    self.textView.alwaysBounceVertical = YES;
    self.textView.showsVerticalScrollIndicator = YES;
    self.textView.textContainerInset = UIEdgeInsetsMake(24, 20, 40, 20);
    self.textView.layoutManager.allowsNonContiguousLayout = YES;
    self.textView.backgroundColor = UIColor.clearColor;
    self.textView.delegate = self;
    self.textView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.textView];

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
    UIButton *smaller = [self barButton:@"A-" action:@selector(fontSmaller)];
    UIButton *bigger  = [self barButton:@"A+" action:@selector(fontBigger)];
    UIButton *themeBtn = [self barButton:@"主题" action:@selector(cycleTheme)];

    self.progressLabel = [[UILabel alloc] init];
    self.progressLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightRegular];
    self.progressLabel.textAlignment = NSTextAlignmentCenter;
    self.progressLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.bottomBar addSubview:self.progressLabel];

    UIStackView *row1 = [[UIStackView alloc] initWithArrangedSubviews:@[prev, next, smaller, bigger, themeBtn]];
    row1.distribution = UIStackViewDistributionFillEqually;
    row1.translatesAutoresizingMaskIntoConstraints = NO;
    [self.bottomBar addSubview:row1];

    // ---- 约束 ----
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.textView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.textView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.textView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.textView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],

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
    ]];

    // ---- 手势 ----
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                          action:@selector(toggleBars)];
    tap.delegate = self;
    [self.textView addGestureRecognizer:tap];

    UISwipeGestureRecognizer *swL = [[UISwipeGestureRecognizer alloc] initWithTarget:self
                                                                              action:@selector(swiped:)];
    swL.direction = UISwipeGestureRecognizerDirectionLeft;
    [self.view addGestureRecognizer:swL];
    UISwipeGestureRecognizer *swR = [[UISwipeGestureRecognizer alloc] initWithTarget:self
                                                                              action:@selector(swiped:)];
    swR.direction = UISwipeGestureRecognizerDirectionRight;
    [self.view addGestureRecognizer:swR];

    [self applyTheme];
    [self restoreProgress];
    [self loadChapter:self.chapterIndex restoreRatio:self.pendingRestoreRatio];
    [self hideBarsAnimated:NO];
}

- (UIButton *)barButton:(NSString *)title action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    return b;
}

// ---------------- 主题 ----------------

- (void)applyTheme {
    MTReaderTheme t = MTReaderCurrentTheme();
    self.view.backgroundColor = MTBackgroundColor(t);
    self.topBar.backgroundColor = MTBarColor(t);
    self.bottomBar.backgroundColor = MTBarColor(t);
    self.titleLabel.textColor = MTTextColor(t);
    self.progressLabel.textColor = MTTextColor(t);
    for (UIView *v in self.topBar.subviews) {
        if ([v isKindOfClass:UIButton.class]) [(UIButton *)v setTitleColor:MTTextColor(t)
                                                                 forState:UIControlStateNormal];
    }
    for (UIView *v in self.bottomBar.subviews) {
        if ([v isKindOfClass:UIStackView.class]) {
            for (UIView *b in v.subviews) {
                if ([b isKindOfClass:UIButton.class])
                    [(UIButton *)b setTitleColor:MTTextColor(t) forState:UIControlStateNormal];
            }
        }
    }
    [self setNeedsStatusBarAppearanceUpdate];
    [self renderChapterText];
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return MTReaderCurrentTheme() == MTReaderThemeDark
        ? UIStatusBarStyleLightContent : UIStatusBarStyleDarkContent;
}

- (void)cycleTheme {
    MTReaderTheme next = (MTReaderTheme)((MTReaderCurrentTheme() + 1) % 3);
    MTSetReaderTheme(next);
    [self applyTheme];
}

// ---------------- 章节 ----------------

- (void)loadChapter:(NSUInteger)index restoreRatio:(CGFloat)ratio {
    if (self.book.chapters.count == 0) return;
    if (index >= self.book.chapters.count) index = self.book.chapters.count - 1;

    self.chapterIndex = index;
    MTChapter *ch = self.book.chapters[index];
    self.titleLabel.text = [NSString stringWithFormat:@"%@ · %@",
                            self.book.title ?: @"", ch.title ?: @""];
    [self renderChapterText];

    // 恢复滚动位置
    CGFloat r = ratio;
    if (r < 0) r = 0;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.textView layoutIfNeeded];
        CGFloat maxY = MAX(0, self.textView.contentSize.height - self.textView.bounds.size.height);
        self.textView.contentOffset = CGPointMake(0, maxY * r);
        [self updateProgressLabel];
    });
}

- (void)renderChapterText {
    if (self.book.chapters.count == 0) return;
    NSString *body = [self.book textOfChapter:self.chapterIndex];
    NSString *title = self.book.chapters[self.chapterIndex].title ?: @"";

    CGFloat size = MTReaderFontSize();
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle defaultParagraphStyle].mutableCopy;
    ps.lineSpacing = size * 0.42;
    ps.paragraphSpacing = size * 0.55;
    ps.firstLineHeadIndent = 0;

    NSDictionary *bodyAttr = @{
        NSFontAttributeName: [UIFont systemFontOfSize:size],
        NSForegroundColorAttributeName: MTTextColor(MTReaderCurrentTheme()),
        NSParagraphStyleAttributeName: ps,
    };
    NSDictionary *titleAttr = @{
        NSFontAttributeName: [UIFont boldSystemFontOfSize:size * 1.15],
        NSForegroundColorAttributeName: MTTextColor(MTReaderCurrentTheme()),
        NSParagraphStyleAttributeName: ps,
    };

    NSMutableAttributedString *out = [[NSMutableAttributedString alloc] init];
    if (self.book.chapters.count > 1 && title.length) {
        [out appendAttributedString:[[NSAttributedString alloc] initWithString:
                                     [title stringByAppendingString:@"\n\n"] attributes:titleAttr]];
    }
    [out appendAttributedString:[[NSAttributedString alloc] initWithString:body attributes:bodyAttr]];
    self.textView.attributedText = out;
}

- (void)prevChapter {
    if (self.chapterIndex == 0) return;
    [self saveProgress];
    [self loadChapter:self.chapterIndex - 1 restoreRatio:0];
}

- (void)nextChapter {
    if (self.chapterIndex + 1 >= self.book.chapters.count) return;
    [self saveProgress];
    [self loadChapter:self.chapterIndex + 1 restoreRatio:0];
}

- (void)showTOC {
    MTChapterListVC *toc = [[MTChapterListVC alloc] initWithStyle:UITableViewStylePlain];
    toc.book = self.book;
    toc.current = self.chapterIndex;
    __weak typeof(self) weakSelf = self;
    toc.onPick = ^(NSUInteger idx) {
        [weakSelf saveProgress];
        [weakSelf loadChapter:idx restoreRatio:0];
    };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:toc];
    [self presentViewController:nav animated:YES completion:nil];
}

// ---------------- 字号 ----------------

- (void)fontSmaller { [self changeFontBy:-2]; }
- (void)fontBigger  { [self changeFontBy:2]; }

- (void)changeFontBy:(CGFloat)delta {
    CGFloat v = MTReaderFontSize() + delta;
    v = MAX(12, MIN(34, v));
    MTSetReaderFontSize(v);
    CGFloat ratio = [self currentScrollRatio];
    [self renderChapterText];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.textView layoutIfNeeded];
        CGFloat maxY = MAX(0, self.textView.contentSize.height - self.textView.bounds.size.height);
        self.textView.contentOffset = CGPointMake(0, maxY * ratio);
    });
}

// ---------------- 进度 ----------------

- (CGFloat)currentScrollRatio {
    CGFloat maxY = self.textView.contentSize.height - self.textView.bounds.size.height;
    if (maxY <= 1) return 0;
    return MAX(0, MIN(1, self.textView.contentOffset.y / maxY));
}

- (void)updateProgressLabel {
    NSUInteger total = self.book.chapters.count;
    CGFloat r = [self currentScrollRatio];
    CGFloat pct = total > 1
        ? ((self.chapterIndex + r) / total) * 100.0
        : r * 100.0;
    self.progressLabel.text = [NSString stringWithFormat:@"%lu/%lu 章 · %.0f%%",
                               (unsigned long)(self.chapterIndex + 1), (unsigned long)total, pct];
}

- (NSString *)progressKey {
    return [self.book.path.lastPathComponent stringByAppendingString:@"#progress"];
}

- (void)saveProgress {
    NSDictionary *v = @{@"chapter": @(self.chapterIndex),
                        @"ratio": @([self currentScrollRatio])};
    [[NSUserDefaults standardUserDefaults] setObject:v forKey:[self progressKey]];
}

- (void)restoreProgress {
    NSDictionary *v = [[NSUserDefaults standardUserDefaults] dictionaryForKey:[self progressKey]];
    if (!v) return;
    NSInteger ch = [v[@"chapter"] integerValue];
    if (ch >= 0 && (NSUInteger)ch < self.book.chapters.count) self.chapterIndex = (NSUInteger)ch;
    self.pendingRestoreRatio = [v[@"ratio"] doubleValue];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self saveProgress];
}

// ---------------- 交互 ----------------

- (void)goBack {
    [self saveProgress];
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)toggleBars {
    if (self.barsHidden) [self showBars]; else [self hideBarsAnimated:YES];
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
    [self updateProgressLabel];
}

- (void)hideBarsAnimated:(BOOL)animated {
    self.barsHidden = YES;
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

- (void)swiped:(UISwipeGestureRecognizer *)g {
    if (g.direction == UISwipeGestureRecognizerDirectionLeft) [self nextChapter];
    else [self prevChapter];
}

// 点击正文才切换工具栏；拖动/选中文字不触发
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return [other isKindOfClass:UIPanGestureRecognizer.class];
}

- (void)scrollViewDidScroll:(UIScrollView *)sv {
    if (!self.barsHidden) [self updateProgressLabel];
}

@end
