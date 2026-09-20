//
//  MTBookshelfVC.h
//

#import <UIKit/UIKit.h>

@interface MTBookshelfVC : UIViewController

/// 把外部传入的文件复制进书架（供「用其他 App 打开」使用）
+ (void)importExternalFileAtURL:(NSURL *)url;

@end

/// 书架内容变化时广播，收到后应刷新
extern NSString *const MTBookshelfDidChangeNotification;
