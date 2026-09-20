# pending —— 写好但还没接入的功能

这里的文件**不参与编译**（`build.sh` 只编译 `src/*.m`）。
需要启用时，把文件移回 `src/`，并在 `build.sh` 里补上对应框架。

## MTBrowserVC —— 内置书源浏览器

功能：App 内嵌 WKWebView 上网，识别到电子书下载时自动存进书架。

启用步骤：

1. `mv pending/MTBrowserVC.* src/`
2. `build.sh` 的编译参数里加 `-framework WebKit`
3. `MTBookshelfVC.m` 里加一个入口按钮：

```objc
UIBarButtonItem *globe = [[UIBarButtonItem alloc]
    initWithImage:[UIImage systemImageNamed:@"globe"]
            style:UIBarButtonItemStylePlain
           target:self
           action:@selector(openBrowser)];
self.navigationItem.rightBarButtonItems = @[self.navigationItem.rightBarButtonItem, globe];

// 并导入头文件
- (void)openBrowser {
    MTBrowserVC *b = [[MTBrowserVC alloc] init];
    b.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:b animated:YES completion:nil];
}
```

4. 首页地址存在 `NSUserDefaults` 的 `browser.homeURL`，可在浏览器里点「书源」修改。

### 已知注意事项

- 下载会带上 WebView 的 Cookie 和 Referer，否则需要登录的站点会返回 403
- 若站点是纯 http，需要在 `Info.plist` 里放开 ATS（`NSAllowsArbitraryLoads`）
- 下载后通过 `MTBookshelfDidChangeNotification` 让书架刷新
