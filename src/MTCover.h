//
//  MTCover.h —— 书籍封面
//  EPUB：从书里抽出真正的封面图
//  TXT/MD：按文件名生成一张纯色封面（苹果自带绘图，不需要素材）
//

#import <UIKit/UIKit.h>

@interface MTCover : NSObject

/// 取封面（带磁盘缓存，第一次稍慢，之后是读文件）
+ (UIImage *)coverForPath:(NSString *)path;

/// 后台批量预热，书架滚动更顺
+ (void)prewarmCovers:(NSArray<NSString *> *)paths;

/// 清空缓存（换了封面样式时用）
+ (void)clearCache;

@end
