//
//  MTBrowserVC.m —— 内置浏览器
//
//  干两件事：
//    1. 正常上网（可前进后退、地址栏、进度条）
//    2. 识别「下载」并自动存进书架
//
//  下载识别：URL 后缀 / MIME / Content-Disposition 三选一命中即拦。
//  下载时带上 WebView 的 Cookie 和 Referer —— 很多站点不带就 403。
//

#import "MTBrowserVC.h"
#import "MTBookshelfVC.h"
#import <WebKit/WebKit.h>

static NSString *const kHomeURLKey = @"browser.homeURL";

@interface MTBrowserVC () <WKNavigationDelegate, WKUIDelegate>
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) UIView *topBar;
@property (nonatomic, strong) UIView *bottomBar;
@property (nonatomic, strong) UILabel *urlLabel;
@property (nonatomic, strong) UIButton *backBtn;
@property (nonatomic, strong) UIButton *forwardBtn;
@property (nonatomic, strong) UIProgressView *progressBar;
@property (nonatomic, strong) UIAlertController *downloadAlert;
@property (nonatomic, assign) BOOL downloading;
@end

@implementation MTBrowserVC

// ---------------- 首页地址 ----------------

+ (NSString *)homeURLString {
    NSString *v = [[NSUserDefaults standardUserDefaults] stringForKey:kHomeURLKey];
    if (v.length == 0) {
        v = @"https://zh.z-lib.gs";
        [[NSUserDefaults standardUserDefaults] setObject:v forKey:kHomeURLKey];
    }
    if (![v hasPrefix:@"http"]) v = [@"https://" stringByAppendingString:v];
    return v;
}

+ (void)setHomeURLString:(NSString *)url {
    NSString *v = [url stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (v.length == 0) return;
    if (![v hasPrefix:@"http"]) v = [@"https://" stringByAppendingString:v];
    [[NSUserDefaults standardUserDefaults] setObject:v forKey:kHomeURLKey];
}

// ---------------- 生命周期 ----------------

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    [self buildWebView];
    [self buildChrome];

    [self loadHome];
}

- (void)buildWebView {
    WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
    cfg.allowsInlineMediaPlayback = YES;
    // 用默认数据存储：登录状态、cookie 能留住，下次打开不用重新登录
    cfg.websiteDataStore = [WKWebsiteDataStore defaultDataStore];

    self.webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:cfg];
    self.webView.navigationDelegate = self;
    self.webView.UIDelegate = self;
    self.webView.allowsBackForwardNavigationGestures = YES;
    self.webView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.webView];

    [self.webView addObserver:self forKeyPath:@"estimatedProgress"
                      options:NSKeyValueObservingOptionNew context:NULL];
    [self.webView addObserver:self forKeyPath:@"canGoBack"
                      options:NSKeyValueObservingOptionNew context:NULL];
    [self.webView addObserver:self forKeyPath:@"canGoForward"
                      options:NSKeyValueObservingOptionNew context:NULL];
}

- (void)buildChrome {
    UIColor *bar = [UIColor secondarySystemBackgroundColor];

    // ---- 顶栏 ----
    self.topBar = [[UIView alloc] init];
    self.topBar.backgroundColor = bar;
    self.topBar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.topBar];

    UIButton *close = [self button:@"关闭" action:@selector(closeTapped)];
    [self.topBar addSubview:close];

    self.urlLabel = [[UILabel alloc] init];
    self.urlLabel.font = [UIFont systemFontOfSize:13];
    self.urlLabel.textColor = [UIColor secondaryLabelColor];
    self.urlLabel.textAlignment = NSTextAlignmentCenter;
    self.urlLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    self.urlLabel.userInteractionEnabled = YES;
    self.urlLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.urlLabel addGestureRecognizer:
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(editURL)]];
    [self.topBar addSubview:self.urlLabel];

    UIButton *refresh = [self button:@"刷新" action:@selector(reloadTapped)];
    [self.topBar addSubview:refresh];

    self.progressBar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleBar];
    self.progressBar.translatesAutoresizingMaskIntoConstraints = NO;
    self.progressBar.progressTintColor = [UIColor systemBlueColor];
    [self.topBar addSubview:self.progressBar];

    // ---- 底栏 ----
    self.bottomBar = [[UIView alloc] init];
    self.bottomBar.backgroundColor = bar;
    self.bottomBar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.bottomBar];

    self.backBtn = [self button:@"‹" action:@selector(goBack)];
    self.forwardBtn = [self button:@"›" action:@selector(goForward)];
    UIButton *home = [self button:@"⌂" action:@selector(loadHome)];
    UIButton *settings = [self button:@"书源" action:@selector(editHome)];
    self.backBtn.titleLabel.font = [UIFont systemFontOfSize:26];
    self.forwardBtn.titleLabel.font = [UIFont systemFontOfSize:26];

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:
                        @[self.backBtn, self.forwardBtn, home, settings]];
    row.distribution = UIStackViewDistributionFillEqually;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [self.bottomBar addSubview:row];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.topBar.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.topBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.topBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.topBar.bottomAnchor constraintEqualToAnchor:safe.topAnchor constant:46],

        [close.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:8],
        [close.centerYAnchor constraintEqualToAnchor:safe.topAnchor constant:23],
        [refresh.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-8],
        [refresh.centerYAnchor constraintEqualToAnchor:safe.topAnchor constant:23],
        [self.urlLabel.leadingAnchor constraintEqualToAnchor:close.trailingAnchor constant:6],
        [self.urlLabel.trailingAnchor constraintEqualToAnchor:refresh.leadingAnchor constant:-6],
        [self.urlLabel.centerYAnchor constraintEqualToAnchor:safe.topAnchor constant:23],

        [self.progressBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.progressBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.progressBar.bottomAnchor constraintEqualToAnchor:self.topBar.bottomAnchor],
        [self.progressBar.heightAnchor constraintEqualToConstant:2],

        [self.bottomBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.bottomBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.bottomBar.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.bottomBar.topAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-46],

        [row.leadingAnchor constraintEqualToAnchor:self.bottomBar.leadingAnchor],
        [row.trailingAnchor constraintEqualToAnchor:self.bottomBar.trailingAnchor],
        [row.topAnchor constraintEqualToAnchor:self.bottomBar.topAnchor],
        [row.bottomAnchor constraintEqualToAnchor:self.bottomBar.bottomAnchor],

        [self.webView.topAnchor constraintEqualToAnchor:self.topBar.bottomAnchor],
        [self.webView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.webView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.webView.bottomAnchor constraintEqualToAnchor:self.bottomBar.topAnchor],
    ]];

    [self updateNavButtons];
}

- (UIButton *)button:(NSString *)title action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:15];
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    return b;
}

- (void)dealloc {
    @try {
        [self.webView removeObserver:self forKeyPath:@"estimatedProgress"];
        [self.webView removeObserver:self forKeyPath:@"canGoBack"];
        [self.webView removeObserver:self forKeyPath:@"canGoForward"];
    } @catch (NSException *e) { }
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                        change:(NSDictionary *)change context:(void *)context {
    if (object != self.webView) return;
    if ([keyPath isEqualToString:@"estimatedProgress"]) {
        CGFloat p = self.webView.estimatedProgress;
        self.progressBar.hidden = (p >= 1.0);
        [self.progressBar setProgress:p animated:YES];
    } else {
        [self updateNavButtons];
    }
}

- (void)updateNavButtons {
    self.backBtn.enabled = self.webView.canGoBack;
    self.forwardBtn.enabled = self.webView.canGoForward;
    self.backBtn.alpha = self.webView.canGoBack ? 1.0 : 0.35;
    self.forwardBtn.alpha = self.webView.canGoForward ? 1.0 : 0.35;
}

- (void)updateURL {
    NSURL *u = self.webView.URL;
    self.urlLabel.text = u ? u.absoluteString : @"输入网址";
}

// ---------------- 导航 ----------------

- (void)loadHome {
    NSString *h = [MTBrowserVC homeURLString];
    NSURL *u = [NSURL URLWithString:h];
    if (!u) { [self promptURL]; return; }
    [self.webView loadRequest:[NSURLRequest requestWithURL:u]];
}

- (void)closeTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)reloadTapped {
    if (self.webView.URL) [self.webView reload];
    else [self loadHome];
}

- (void)goBack { if (self.webView.canGoBack) [self.webView goBack]; }
- (void)goForward { if (self.webView.canGoForward) [self.webView goForward]; }

- (void)editURL {
    [self promptURL];
}

- (void)promptURL {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"打开网址"
                                                              message:nil
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = self.webView.URL.absoluteString ?: [MTBrowserVC homeURLString];
        tf.keyboardType = UIKeyboardTypeURL;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"前往" style:UIAlertActionStyleDefault
                                       handler:^(UIAlertAction *act) {
        NSString *v = a.textFields.firstObject.text;
        NSString *s = [v stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (s.length == 0) return;
        if (![s hasPrefix:@"http"]) s = [@"https://" stringByAppendingString:s];
        NSURL *u = [NSURL URLWithString:s];
        if (u) [self.webView loadRequest:[NSURLRequest requestWithURL:u]];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)editHome {
    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:@"书源网址"
                         message:@"下载的书会自动加入书架。支持 EPUB / TXT / MOBI / PDF / AZW3 等。"
                  preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = [MTBrowserVC homeURLString];
        tf.keyboardType = UIKeyboardTypeURL;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault
                                       handler:^(UIAlertAction *act) {
        [MTBrowserVC setHomeURLString:a.textFields.firstObject.text];
        [self loadHome];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"清除 Cookie" style:UIAlertActionStyleDestructive
                                       handler:^(UIAlertAction *act) {
        WKWebsiteDataStore *store = self.webView.configuration.websiteDataStore;
        NSSet *types = [WKWebsiteDataStore allWebsiteDataTypes];
        [store removeDataOfTypes:types modifiedSince:[NSDate dateWithTimeIntervalSince1970:0]
                       completionHandler:^{ }];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

// ---------------- 拦截下载 ----------------

- (BOOL)isDownloadableExtension:(NSString *)ext {
    static NSSet *set = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSSet setWithArray:@[@"epub", @"mobi", @"azw3", @"azw", @"fb2", @"txt",
                                    @"pdf", @"djvu", @"cbz", @"zip", @"rar", @"doc", @"docx"]];
    });
    return [set containsObject:ext.lowercaseString];
}

- (BOOL)isDownloadableMIME:(NSString *)mime {
    if (mime.length == 0) return NO;
    static NSArray *list = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        list = @[@"application/epub+zip", @"application/x-mobipocket-ebook",
                 @"application/vnd.amazon.ebook", @"application/octet-stream",
                 @"application/x-rar", @"application/zip", @"application/pdf",
                 @"application/x-msdownload", @"application/x-download",
                 @"binary/octet-stream", @"application/mobi"];
    });
    for (NSString *m in list) if ([mime hasPrefix:m]) return YES;
    return NO;
}

- (void)webView:(WKWebView *)webView
    decidePolicyForNavigationResponse:(WKNavigationResponse *)navigationResponse
                      decisionHandler:(void (^)(WKNavigationResponsePolicy))decisionHandler {

    NSURLResponse *resp = navigationResponse.response;
    NSURL *url = resp.URL;

    NSString *mime = resp.MIMEType.lowercaseString ?: @"";
    NSString *ext = url.pathExtension ?: @"";
    NSString *disposition = @"";
    if ([resp isKindOfClass:NSHTTPURLResponse.class]) {
        id d = ((NSHTTPURLResponse *)resp).allHeaderFields[@"Content-Disposition"];
        if ([d isKindOfClass:NSString.class]) disposition = [d lowercaseString];
    }

    BOOL hit = [self isDownloadableExtension:ext]
            || [disposition containsString:@"attachment"]
            || ([self isDownloadableMIME:mime] && ![mime hasPrefix:@"text/html"]);

    if (hit) {
        decisionHandler(WKNavigationResponsePolicyCancel);
        [self downloadURL:url response:resp];
        return;
    }
    decisionHandler(WKNavigationResponsePolicyAllow);
}

// 处理 target="_blank" / window.open：直接在当前 WebView 打开，别开新窗口
- (WKWebView *)webView:(WKWebView *)webView
    createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
               forNavigationAction:(WKNavigationAction *)action
                    windowFeatures:(WKWindowFeatures *)features {
    if (!action.targetFrame.isMainFrame) {
        [webView loadRequest:action.request];
    }
    return nil;
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    [self updateURL];
    self.progressBar.hidden = YES;
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation
         withError:(NSError *)error {
    self.progressBar.hidden = YES;
    [self updateURL];
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation
         withError:(NSError *)error {
    self.progressBar.hidden = YES;
}

// ---------------- 下载 ----------------

- (NSString *)filenameFromResponse:(NSURLResponse *)resp url:(NSURL *)url {
    NSString *name = nil;

    if ([resp isKindOfClass:NSHTTPURLResponse.class]) {
        id raw = ((NSHTTPURLResponse *)resp).allHeaderFields[@"Content-Disposition"];
        if ([raw isKindOfClass:NSString.class]) {
            NSString *d = raw;
            // filename*=UTF-8''xxx 优先
            NSRange star = [d rangeOfString:@"filename*=" options:NSCaseInsensitiveSearch];
            if (star.location != NSNotFound) {
                NSString *rest = [d substringFromIndex:NSMaxRange(star)];
                NSRange q = [rest rangeOfString:@"''"];
                if (q.location != NSNotFound) rest = [rest substringFromIndex:NSMaxRange(q)];
                NSRange semi = [rest rangeOfString:@";"];
                if (semi.location != NSNotFound) rest = [rest substringToIndex:semi.location];
                name = [[rest stringByTrimmingCharactersInSet:
                         [NSCharacterSet characterSetWithCharactersInString:@"\"' "]]
                        stringByRemovingPercentEncoding];
            }
            if (name.length == 0) {
                NSRange plain = [d rangeOfString:@"filename=" options:NSCaseInsensitiveSearch];
                if (plain.location != NSNotFound) {
                    NSString *rest = [d substringFromIndex:NSMaxRange(plain)];
                    NSRange semi = [rest rangeOfString:@";"];
                    if (semi.location != NSNotFound) rest = [rest substringToIndex:semi.location];
                    name = [rest stringByTrimmingCharactersInSet:
                            [NSCharacterSet characterSetWithCharactersInString:@"\"' "]];
                }
            }
        }
    }

    if (name.length == 0) {
        name = url.lastPathComponent.stringByRemovingPercentEncoding;
    }
    if (name.length == 0) name = @"下载的书";

    // 没有扩展名就按 MIME 补
    if (name.pathExtension.length == 0) {
        NSString *mime = resp.MIMEType.lowercaseString ?: @"";
        NSString *ext = nil;
        if ([mime containsString:@"epub"]) ext = @"epub";
        else if ([mime containsString:@"mobipocket"] || [mime containsString:@"mobi"]) ext = @"mobi";
        else if ([mime containsString:@"pdf"]) ext = @"pdf";
        else if ([mime containsString:@"amazon"]) ext = @"azw3";
        else if ([mime containsString:@"text/plain"]) ext = @"txt";
        if (ext) name = [name stringByAppendingPathExtension:ext];
    }

    // 清掉路径分隔符，防止写到目录外
    name = [name stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    name = [name stringByReplacingOccurrencesOfString:@":" withString:@"_"];
    return name;
}

- (void)downloadURL:(NSURL *)url response:(NSURLResponse *)resp {
    if (self.downloading) return;
    self.downloading = YES;

    NSString *name = [self filenameFromResponse:resp url:url];
    [self showDownloadAlert:name];

    __weak typeof(self) ws = self;
    // 有些站点靠 UA 判断是否允许下载，拿 WebView 的真实 UA 最稳
    [self.webView evaluateJavaScript:@"navigator.userAgent"
                   completionHandler:^(id ua, NSError *err) {
        typeof(self) ss = ws;
        if (!ss) return;

        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
        req.timeoutInterval = 120;
        if ([ua isKindOfClass:NSString.class] && [ua length] > 0) {
            [req setValue:ua forHTTPHeaderField:@"User-Agent"];
        }
        NSString *referer = ss.webView.URL.absoluteString ?: url.absoluteString;
        if (referer.length) [req setValue:referer forHTTPHeaderField:@"Referer"];

        // 带上 WebView 的 Cookie —— 不带的话登录站点会 403
        [ss.webView.configuration.websiteDataStore.httpCookieStore
            getAllCookies:^(NSArray<NSHTTPCookie *> *cookies) {
            NSDictionary *headers = [NSHTTPCookie requestHeaderFieldsWithCookies:cookies];
            for (NSString *k in headers) [req setValue:headers[k] forHTTPHeaderField:k];
            [ss startDownloadTask:req name:name];
        }];
    }];
}

- (void)startDownloadTask:(NSURLRequest *)req name:(NSString *)name {
    __weak typeof(self) ws = self;
    NSURLSessionDownloadTask *task = [[NSURLSession sharedSession]
        downloadTaskWithRequest:req
              completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) ss = ws;
            if (!ss) return;
            ss.downloading = NO;

            if (error || !location) {
                [ss finishDownloadWithTitle:@"下载失败"
                                    message:error.localizedDescription ?: @"网络错误，请重试"];
                return;
            }

            NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:location.path
                                                                              error:NULL];
            unsigned long long size = [a[NSFileSize] unsignedLongLongValue];
            if (size < 1024) {
                [ss finishDownloadWithTitle:@"下载失败"
                                    message:@"文件太小，可能没有下载到正文（试试先在该网站登录）"];
                return;
            }

            NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                                  NSUserDomainMask, YES) firstObject];
            NSString *dst = [docs stringByAppendingPathComponent:name];
            NSFileManager *fm = [NSFileManager defaultManager];
            NSInteger n = 1;
            while ([fm fileExistsAtPath:dst]) {
                NSString *base = [name stringByDeletingPathExtension];
                NSString *ext = name.pathExtension;
                dst = [docs stringByAppendingPathComponent:
                       [NSString stringWithFormat:@"%@-%ld.%@", base, (long)n++, ext]];
            }

            NSError *mvErr = nil;
            if ([fm moveItemAtURL:location toURL:[NSURL fileURLWithPath:dst] error:&mvErr]) {
                // 通知书架刷新
                [[NSNotificationCenter defaultCenter]
                    postNotificationName:MTBookshelfDidChangeNotification object:nil];
                [ss finishDownloadWithTitle:@"已加入书架"
                                    message:[NSString stringWithFormat:@"%@\n%.1f MB",
                                             dst.lastPathComponent, size / 1048576.0]];
            } else {
                [ss finishDownloadWithTitle:@"保存失败"
                                    message:mvErr.localizedDescription ?: @"无法写入"];
            }
        });
    }];
    [task resume];
}

- (void)showDownloadAlert:(NSString *)name {
    self.downloadAlert = [UIAlertController alertControllerWithTitle:@"开始下载"
                                                            message:name
                                                     preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:self.downloadAlert animated:YES completion:nil];
}

- (void)finishDownloadWithTitle:(NSString *)title message:(NSString *)msg {
    if (self.downloadAlert) {
        [self.downloadAlert dismissViewControllerAnimated:YES completion:^{
            self.downloadAlert = nil;
            UIAlertController *a = [UIAlertController alertControllerWithTitle:title
                                                                      message:msg
                                                               preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:a animated:YES completion:nil];
        }];
    } else {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:title
                                                                  message:msg
                                                           preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
    }
}

@end
