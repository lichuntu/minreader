//
//  MTReaderVC.h
//

#import <UIKit/UIKit.h>
#import "MTBook.h"

typedef NS_ENUM(NSInteger, MTReaderTheme) {
    MTReaderThemeLight = 0,
    MTReaderThemeSepia,
    MTReaderThemeDark,
};

@interface MTReaderVC : UIViewController
- (instancetype)initWithBook:(MTBook *)book;
@end
