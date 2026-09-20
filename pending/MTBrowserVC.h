//
//  MTBrowserVC.h —— 内置浏览器（书源）
//

#import <UIKit/UIKit.h>

@interface MTBrowserVC : UIViewController

/// 首页地址（可在设置里改）
+ (NSString *)homeURLString;
+ (void)setHomeURLString:(NSString *)url;

@end
