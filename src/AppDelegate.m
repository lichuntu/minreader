//
//  AppDelegate.m
//

#import "AppDelegate.h"
#import "MTBookshelfVC.h"

@implementation MTAppDelegate

- (BOOL)application:(UIApplication *)application
        didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    MTBookshelfVC *shelf = [[MTBookshelfVC alloc] initWithStyle:UITableViewStylePlain];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:shelf];

    // 深色模式下导航栏也不刺眼
    UINavigationBarAppearance *ap = [[UINavigationBarAppearance alloc] init];
    [ap configureWithDefaultBackground];
    nav.navigationBar.standardAppearance = ap;
    nav.navigationBar.scrollEdgeAppearance = ap;

    self.window.rootViewController = nav;
    [self.window makeKeyAndVisible];

    // 冷启动时由「用其他 App 打开」带进来的文件
    NSURL *url = launchOptions[UIApplicationLaunchOptionsURLKey];
    if (url) [MTBookshelfVC importExternalFileAtURL:url];

    NSLog(@"[MinReader] launched on iOS %@", UIDevice.currentDevice.systemVersion);
    return YES;
}

- (BOOL)application:(UIApplication *)app
            openURL:(NSURL *)url
            options:(NSDictionary<UIApplicationOpenURLOptionsKey, id> *)options {
    [MTBookshelfVC importExternalFileAtURL:url];
    return YES;
}

@end
