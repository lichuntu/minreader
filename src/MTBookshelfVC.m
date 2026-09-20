//
//  MTBookshelfVC.m —— 书架
//  一行两本卡片，带封面；长按可删除；右上角 + 导入
//

#import "MTBookshelfVC.h"
#import "MTReaderVC.h"
#import "MTBook.h"
#import "MTCover.h"

#if __has_include(<UniformTypeIdentifiers/UniformTypeIdentifiers.h>)
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#define MT_HAS_UTTYPE 1
#else
#define MT_HAS_UTTYPE 0
#endif

NSString *const MTBookshelfDidChangeNotification = @"MTBookshelfDidChangeNotification";

static NSString *const kCellID = @"MTShelfCell";

// ============================================================
//  书架卡片
// ============================================================

@interface MTShelfCell : UICollectionViewCell
@property (nonatomic, strong) UIView *coverWrap;
@property (nonatomic, strong) UIImageView *coverView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subLabel;
@property (nonatomic, strong) UILabel *badge;        // 左上角「读」标记
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, copy)   NSString *bookName;
@end

@implementation MTShelfCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.coverView = [[UIImageView alloc] init];
    self.coverView.contentMode = UIViewContentModeScaleAspectFill;
    self.coverView.clipsToBounds = YES;
    self.coverView.layer.cornerRadius = 8;
    self.coverView.layer.borderWidth = 0.5;
    self.coverView.layer.borderColor = [UIColor colorWithWhite:0.5 alpha:0.25].CGColor;
    self.coverView.backgroundColor = [UIColor tertiarySystemFillColor];
    self.coverView.translatesAutoresizingMaskIntoConstraints = NO;

    // 阴影要放在外层容器上：coverView 自己 clipsToBounds 会把阴影裁掉
    UIView *coverWrap = [[UIView alloc] init];
    coverWrap.layer.shadowColor = UIColor.blackColor.CGColor;
    coverWrap.layer.shadowOpacity = 0.16;
    coverWrap.layer.shadowRadius = 5;
    coverWrap.layer.shadowOffset = CGSizeMake(0, 3);
    coverWrap.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:coverWrap];
    [coverWrap addSubview:self.coverView];

    [NSLayoutConstraint activateConstraints:@[
        [coverWrap.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
        [coverWrap.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
        [coverWrap.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
        [coverWrap.heightAnchor constraintEqualToAnchor:coverWrap.widthAnchor multiplier:1.38],

        [self.coverView.topAnchor constraintEqualToAnchor:coverWrap.topAnchor],
        [self.coverView.leadingAnchor constraintEqualToAnchor:coverWrap.leadingAnchor],
        [self.coverView.trailingAnchor constraintEqualToAnchor:coverWrap.trailingAnchor],
        [self.coverView.bottomAnchor constraintEqualToAnchor:coverWrap.bottomAnchor],
    ]];
    self.coverWrap = coverWrap;

    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    self.titleLabel.numberOfLines = 2;
    self.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;

    self.subLabel = [[UILabel alloc] init];
    self.subLabel.font = [UIFont systemFontOfSize:11];
    self.subLabel.textColor = [UIColor secondaryLabelColor];
    self.subLabel.numberOfLines = 1;
    self.subLabel.translatesAutoresizingMaskIntoConstraints = NO;

    self.badge = [[UILabel alloc] init];
    self.badge.font = [UIFont systemFontOfSize:10 weight:UIFontWeightBold];
    self.badge.textColor = UIColor.whiteColor;
    self.badge.backgroundColor = [UIColor systemBlueColor];
    self.badge.textAlignment = NSTextAlignmentCenter;
    self.badge.layer.cornerRadius = 4;
    self.badge.clipsToBounds = YES;
    self.badge.translatesAutoresizingMaskIntoConstraints = NO;
    self.badge.text = @"读中";

    self.spinner = [[UIActivityIndicatorView alloc]
                    initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    self.spinner.hidesWhenStopped = YES;
    [self.contentView addSubview:self.spinner];

    [self.contentView addSubview:self.titleLabel];
    [self.contentView addSubview:self.subLabel];
    [self.contentView addSubview:self.badge];

    [NSLayoutConstraint activateConstraints:@[
        [self.titleLabel.topAnchor constraintEqualToAnchor:coverWrap.bottomAnchor constant:7],
        [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:2],
        [self.titleLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-2],

        [self.subLabel.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:2],
        [self.subLabel.leadingAnchor constraintEqualToAnchor:self.titleLabel.leadingAnchor],
        [self.subLabel.trailingAnchor constraintEqualToAnchor:self.titleLabel.trailingAnchor],

        [self.badge.topAnchor constraintEqualToAnchor:self.coverView.topAnchor constant:6],
        [self.badge.leadingAnchor constraintEqualToAnchor:self.coverView.leadingAnchor constant:6],
        [self.badge.widthAnchor constraintEqualToConstant:32],
        [self.badge.heightAnchor constraintEqualToConstant:16],

        [self.spinner.centerXAnchor constraintEqualToAnchor:self.coverView.centerXAnchor],
        [self.spinner.centerYAnchor constraintEqualToAnchor:self.coverView.centerYAnchor],
    ]];
    return self;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.coverView.image = nil;
    self.bookName = nil;
    self.badge.hidden = YES;
    [self.spinner stopAnimating];
}

@end

// ============================================================
//  书架
// ============================================================

@interface MTBookshelfVC () <UIDocumentPickerDelegate, UICollectionViewDataSource, UICollectionViewDelegate>
@property (nonatomic, strong) UICollectionView *collection;
@property (nonatomic, strong) NSMutableArray<NSString *> *files;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) NSMutableSet<NSString *> *loadingCovers;
@end

@implementation MTBookshelfVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"我的书架";
    self.files = [NSMutableArray array];
    self.loadingCovers = [NSMutableSet set];

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                      target:self
                                                      action:@selector(importFile)];

    [self buildCollection];
    [self buildEmptyView];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reload)
                                                 name:MTBookshelfDidChangeNotification
                                               object:nil];
}

- (void)buildCollection {
    UICollectionViewFlowLayout *layout = [[UICollectionViewFlowLayout alloc] init];
    CGFloat w = self.view.bounds.size.width;
    CGFloat side = 20;
    CGFloat gap = 16;
    CGFloat cellW = (w - side * 2 - gap) / 2.0;
    layout.itemSize = CGSizeMake(cellW, cellW * 1.38 + 42);
    layout.sectionInset = UIEdgeInsetsMake(16, side, 24, side);
    layout.minimumInteritemSpacing = gap;
    layout.minimumLineSpacing = 22;

    self.collection = [[UICollectionView alloc] initWithFrame:self.view.bounds
                                         collectionViewLayout:layout];
    self.collection.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.collection.backgroundColor = [UIColor systemBackgroundColor];
    self.collection.dataSource = self;
    self.collection.delegate = self;
    self.collection.alwaysBounceVertical = YES;
    [self.collection registerClass:MTShelfCell.class forCellWithReuseIdentifier:kCellID];
    [self.view addSubview:self.collection];

    UIRefreshControl *rc = [[UIRefreshControl alloc] init];
    [rc addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
    self.collection.refreshControl = rc;
}

- (void)buildEmptyView {
    self.emptyLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 260, 200)];
    self.emptyLabel.text = @"书架是空的\n\n点右上角 + 导入电子书\n支持 TXT / EPUB / Markdown";
    self.emptyLabel.numberOfLines = 0;
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.textColor = [UIColor secondaryLabelColor];
    self.emptyLabel.font = [UIFont systemFontOfSize:15];
    self.emptyLabel.center = CGPointMake(self.view.bounds.size.width / 2, 220);
    self.emptyLabel.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    [self.view addSubview:self.emptyLabel];
}

// ---------------- 文件 ----------------

- (NSString *)documentsPath {
    return [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reload];
}

- (void)reload {
    NSString *docs = [self documentsPath];
    NSArray *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:docs error:NULL];
    NSArray *ok = @[@"txt", @"epub", @"md", @"markdown"];
    NSMutableArray *list = [NSMutableArray array];
    for (NSString *n in items) {
        if ([n hasPrefix:@"."]) continue;      // 跳过 .covers 等隐藏目录
        if ([ok containsObject:n.pathExtension.lowercaseString]) [list addObject:n];
    }
    [list sortUsingSelector:@selector(localizedStandardCompare:)];
    self.files = list;

    self.emptyLabel.hidden = (list.count > 0);
    [self.collection reloadData];
    [self.collection.refreshControl endRefreshing];

    // 后台预热封面
    NSMutableArray *paths = [NSMutableArray array];
    for (NSString *n in list) [paths addObject:[docs stringByAppendingPathComponent:n]];
    [MTCover prewarmCovers:paths];
}

// ---------------- 外部导入 ----------------

+ (void)importExternalFileAtURL:(NSURL *)url {
    if (!url || url.lastPathComponent.length == 0) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];

    BOOL access = [url startAccessingSecurityScopedResource];
    NSString *name = url.lastPathComponent;
    NSString *dst = [docs stringByAppendingPathComponent:name];

    if (![url.path isEqualToString:dst]) {
        NSInteger n = 1;
        while ([fm fileExistsAtPath:dst]) {
            NSString *base = [name stringByDeletingPathExtension];
            NSString *ext = name.pathExtension;
            dst = [docs stringByAppendingPathComponent:
                   [NSString stringWithFormat:@"%@-%ld.%@", base, (long)n++, ext]];
        }
        [fm copyItemAtURL:url toURL:[NSURL fileURLWithPath:dst] error:NULL];
    }
    if (access) [url stopAccessingSecurityScopedResource];

    [[NSNotificationCenter defaultCenter] postNotificationName:MTBookshelfDidChangeNotification
                                                        object:nil];
}

// ---------------- CollectionView ----------------

- (NSInteger)collectionView:(UICollectionView *)cv numberOfItemsInSection:(NSInteger)s {
    return self.files.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)cv
                  cellForItemAtIndexPath:(NSIndexPath *)ip {
    MTShelfCell *cell = [cv dequeueReusableCellWithReuseIdentifier:kCellID forIndexPath:ip];
    NSString *name = self.files[ip.row];
    NSString *path = [[self documentsPath] stringByAppendingPathComponent:name];

    cell.bookName = name;
    cell.titleLabel.text = [name stringByDeletingPathExtension];

    // 副标题：格式 · 大小 · 进度
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
    double bytes = [attrs[NSFileSize] doubleValue];
    NSString *size = bytes > 1048576
        ? [NSString stringWithFormat:@"%.1fMB", bytes / 1048576.0]
        : [NSString stringWithFormat:@"%.0fKB", bytes / 1024.0];
    NSDictionary *prog = [[NSUserDefaults standardUserDefaults]
                          dictionaryForKey:[name stringByAppendingString:@"#progress"]];
    NSString *progress = @"";
    if (prog) progress = [NSString stringWithFormat:@" · 第%ld章", (long)([prog[@"chapter"] integerValue] + 1)];
    cell.subLabel.text = [NSString stringWithFormat:@"%@ · %@%@",
                          name.pathExtension.uppercaseString, size, progress];
    cell.badge.hidden = (prog == nil);

    // 封面
    UIImage *cached = [MTCover coverForPath:path];   // 有缓存会立刻返回
    if (cached) {
        cell.coverView.image = cached;
        [cell.spinner stopAnimating];
    } else {
        cell.coverView.image = nil;
        [cell.spinner startAnimating];
        __weak MTShelfCell *weakCell = cell;
        __weak typeof(self) weakSelf = self;
        NSString *expect = name;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            UIImage *img = [MTCover coverForPath:path];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!img) return;
                if (![weakCell.bookName isEqualToString:expect]) return;   // 复用了，丢弃
                weakCell.coverView.image = img;
                [weakCell.spinner stopAnimating];
                (void)weakSelf;
            });
        });
    }
    return cell;
}

- (void)collectionView:(UICollectionView *)cv didSelectItemAtIndexPath:(NSIndexPath *)ip {
    [cv deselectItemAtIndexPath:ip animated:YES];
    [self openBookNamed:self.files[ip.row]];
}

// 长按菜单：删除 / 重命名
- (UIContextMenuConfiguration *)collectionView:(UICollectionView *)cv
    contextMenuConfigurationForItemAtIndexPath:(NSIndexPath *)ip point:(CGPoint)p {
    NSString *name = self.files[ip.row];
    __weak typeof(self) weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil
        previewProvider:nil
        actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) {
        UIAction *del = [UIAction actionWithTitle:@"删除"
                                            image:[UIImage systemImageNamed:@"trash"]
                                       identifier:nil
                                          handler:^(UIAction *a) {
            [weakSelf confirmDelete:name];
        }];
        del.attributes = UIMenuElementAttributesDestructive;
        return [UIMenu menuWithTitle:name children:@[del]];
    }];
}

- (void)confirmDelete:(NSString *)name {
    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:[NSString stringWithFormat:@"删除《%@》？", [name stringByDeletingPathExtension]]
                         message:@"同时会清除该书的阅读进度和缓存封面"
                  preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive
                                       handler:^(UIAlertAction *act) {
        NSString *path = [[self documentsPath] stringByAppendingPathComponent:name];
        [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:
            [name stringByAppendingString:@"#progress"]];
        [self reload];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

// ---------------- 打开 ----------------

- (void)openBookNamed:(NSString *)name {
    NSString *path = [[self documentsPath] stringByAppendingPathComponent:name];

    UIActivityIndicatorView *spin = [[UIActivityIndicatorView alloc]
                                     initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    spin.center = self.view.center;
    [self.view addSubview:spin];
    [spin startAnimating];
    self.view.userInteractionEnabled = NO;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *err = nil;
        MTBook *book = [MTBook bookAtPath:path error:&err];
        dispatch_async(dispatch_get_main_queue(), ^{
            [spin stopAnimating];
            [spin removeFromSuperview];
            self.view.userInteractionEnabled = YES;

            if (!book) {
                UIAlertController *a = [UIAlertController
                    alertControllerWithTitle:@"打不开这本书"
                                     message:err.localizedDescription ?: @"解析失败"
                              preferredStyle:UIAlertControllerStyleAlert];
                [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:a animated:YES completion:nil];
                return;
            }
            MTReaderVC *reader = [[MTReaderVC alloc] initWithBook:book];
            reader.modalPresentationStyle = UIModalPresentationFullScreen;
            [self presentViewController:reader animated:YES completion:nil];
        });
    });
}

// ---------------- 导入 ----------------

- (void)importFile {
#if MT_HAS_UTTYPE
    if (@available(iOS 14.0, *)) {
        UIDocumentPickerViewController *p =
            [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeData]
                                                                       asCopy:YES];
        p.delegate = self;
        p.allowsMultipleSelection = YES;
        [self presentViewController:p animated:YES completion:nil];
        return;
    }
#endif
    UIDocumentPickerViewController *p =
        [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.data"]
                                                               inMode:UIDocumentPickerModeImport];
    p.delegate = self;
    p.allowsMultipleSelection = YES;
    [self presentViewController:p animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)c
 didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSString *docs = [self documentsPath];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSInteger imported = 0;

    for (NSURL *src in urls) {
        BOOL access = [src startAccessingSecurityScopedResource];
        NSString *name = src.lastPathComponent;
        NSString *dst = [docs stringByAppendingPathComponent:name];
        NSInteger n = 1;
        while ([fm fileExistsAtPath:dst]) {
            NSString *base = [name stringByDeletingPathExtension];
            NSString *ext = name.pathExtension;
            dst = [docs stringByAppendingPathComponent:
                   [NSString stringWithFormat:@"%@-%ld.%@", base, (long)n++, ext]];
        }
        if ([fm copyItemAtURL:src toURL:[NSURL fileURLWithPath:dst] error:NULL]) imported++;
        if (access) [src stopAccessingSecurityScopedResource];
    }

    [self reload];
    if (imported == 0 && urls.count > 0) {
        UIAlertController *a = [UIAlertController
            alertControllerWithTitle:@"导入失败"
                             message:@"可能是不支持的格式，或文件还没下载到本机"
                      preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
    }
}

@end
