//
//  MTBookshelfVC.m —— 书架：列出 Documents 里的书，支持导入 / 删除 / 继续阅读
//

#import "MTBookshelfVC.h"
#import "MTReaderVC.h"
#import "MTBook.h"

#if __has_include(<UniformTypeIdentifiers/UniformTypeIdentifiers.h>)
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#define MT_HAS_UTTYPE 1
#else
#define MT_HAS_UTTYPE 0
#endif

NSString *const MTBookshelfDidChangeNotification = @"MTBookshelfDidChangeNotification";

@interface MTBookshelfVC () <UIDocumentPickerDelegate>
@property (nonatomic, strong) NSMutableArray<NSString *> *files;
@property (nonatomic, strong) UILabel *emptyLabel;
@end

@implementation MTBookshelfVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"我的书架";
    self.tableView.rowHeight = 70;
    self.files = [NSMutableArray array];

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                      target:self
                                                      action:@selector(importFile)];

    self.emptyLabel = [[UILabel alloc] initWithFrame:self.view.bounds];
    self.emptyLabel.text = @"还没有书\n\n点右上角 + 从「文件」里导入\n支持 TXT / EPUB / Markdown";
    self.emptyLabel.numberOfLines = 0;
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.textColor = [UIColor secondaryLabelColor];
    self.emptyLabel.font = [UIFont systemFontOfSize:15];
    self.tableView.backgroundView = self.emptyLabel;

    self.refreshControl = [[UIRefreshControl alloc] init];
    [self.refreshControl addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reload)
                                                 name:MTBookshelfDidChangeNotification
                                               object:nil];
}

// ---------------- 外部文件导入（用其他 App 打开） ----------------

+ (void)importExternalFileAtURL:(NSURL *)url {
    if (!url || url.lastPathComponent.length == 0) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];

    BOOL access = [url startAccessingSecurityScopedResource];
    NSString *name = url.lastPathComponent;
    NSString *dst = [docs stringByAppendingPathComponent:name];

    // 已经就在书架目录里，不用复制
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

- (NSString *)documentsPath {
    return [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reload];
}

- (void)reload {
    [self.files removeAllObjects];
    NSString *docs = [self documentsPath];
    NSArray *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:docs error:NULL];
    NSArray *ok = @[@"txt", @"epub", @"md", @"markdown"];
    for (NSString *name in items) {
        if ([name hasPrefix:@"."]) continue;
        if ([ok containsObject:name.pathExtension.lowercaseString]) [self.files addObject:name];
    }
    [self.files sortUsingSelector:@selector(localizedStandardCompare:)];
    self.tableView.backgroundView = self.files.count ? nil : self.emptyLabel;
    [self.tableView reloadData];
    [self.refreshControl endRefreshing];
}

// ---------------- 表格 ----------------

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return self.files.count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"book"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                            reuseIdentifier:@"book"];
    NSString *name = self.files[ip.row];
    NSString *path = [[self documentsPath] stringByAppendingPathComponent:name];

    cell.textLabel.text = [name stringByDeletingPathExtension];
    cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    cell.textLabel.numberOfLines = 1;

    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
    double bytes = [attrs[NSFileSize] doubleValue];
    NSString *size = bytes > 1048576
        ? [NSString stringWithFormat:@"%.1f MB", bytes / 1048576.0]
        : [NSString stringWithFormat:@"%.0f KB", bytes / 1024.0];

    NSDictionary *prog = [[NSUserDefaults standardUserDefaults]
                          dictionaryForKey:[name stringByAppendingString:@"#progress"]];
    NSString *progress = @"";
    if (prog) {
        NSInteger ch = [prog[@"chapter"] integerValue];
        progress = [NSString stringWithFormat:@" · 读到第 %ld 章", (long)(ch + 1)];
    }

    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@%@",
                                 name.pathExtension.uppercaseString, size, progress];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSString *name = self.files[ip.row];
    NSString *path = [[self documentsPath] stringByAppendingPathComponent:name];

    UIActivityIndicatorView *spin = [[UIActivityIndicatorView alloc]
                                     initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
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
                    alertControllerWithTitle:@"打不开"
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

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tv
 trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    NSString *name = self.files[ip.row];
    UIContextualAction *del = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleDestructive
                            title:@"删除"
                          handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        NSString *path = [[self documentsPath] stringByAppendingPathComponent:name];
        [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:
            [name stringByAppendingString:@"#progress"]];
        [self reload];
        done(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[del]];
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

        // 重名时自动加序号
        NSInteger n = 1;
        while ([fm fileExistsAtPath:dst]) {
            NSString *base = [name stringByDeletingPathExtension];
            NSString *ext = name.pathExtension;
            dst = [docs stringByAppendingPathComponent:
                   [NSString stringWithFormat:@"%@-%ld.%@", base, (long)n++, ext]];
        }
        NSError *err = nil;
        if ([fm copyItemAtURL:src toURL:[NSURL fileURLWithPath:dst] error:&err]) imported++;
        if (access) [src stopAccessingSecurityScopedResource];
    }

    [self reload];
    if (imported == 0 && urls.count > 0) {
        UIAlertController *a = [UIAlertController
            alertControllerWithTitle:@"导入失败"
                             message:@"可能是不支持的格式，或文件没有下载到本机"
                      preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
    }
}

@end
