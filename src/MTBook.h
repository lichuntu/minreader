//
//  MTBook.h —— 书籍模型与解析器
//  TXT：编码嗅探（BOM / UTF-8 / GB18030）+ 章节自动切分
//  EPUB：container.xml → .opf → spine，逐章提取正文，保留图片与基本格式
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@class MTZipReader;

typedef NS_ENUM(NSInteger, MTBookFormat) {
    MTBookFormatTXT = 0,
    MTBookFormatEPUB,
    MTBookFormatMarkdown,
};

@interface MTChapter : NSObject
@property (nonatomic, copy)   NSString *title;
@property (nonatomic, copy)   NSString *text;      // 纯文本（TXT 为 nil，用 range 懒加载）
@property (nonatomic, copy)   NSString *html;      // EPUB：原始 XHTML，用于带图排版
@property (nonatomic, copy)   NSString *basePath;  // EPUB：该章文件所在目录（解析相对路径）
@property (nonatomic, assign) NSRange   range;     // TXT 在全书文本中的位置
@property (nonatomic, assign) BOOL      hasRange;
@end

@interface MTBook : NSObject
@property (nonatomic, copy)   NSString *path;
@property (nonatomic, copy)   NSString *title;
@property (nonatomic, copy)   NSString *author;
@property (nonatomic, assign) MTBookFormat format;
@property (nonatomic, strong) NSArray<MTChapter *> *chapters;
@property (nonatomic, copy)   NSString *plainText;   // TXT 的全文（EPUB 为 nil）
@property (nonatomic, strong) MTZipReader *zip;      // EPUB：保持打开用于读图片
@property (nonatomic, strong) NSMutableDictionary *imageCache;

+ (instancetype)bookAtPath:(NSString *)path error:(NSError **)error;

/// 取第 index 章正文（TXT 懒加载切片）
- (NSString *)textOfChapter:(NSUInteger)index;

/// 按当前字号/正文色生成该章的富文本（EPUB 会带上图片、颜色与标题层级）
- (NSAttributedString *)attributedTextForChapter:(NSUInteger)index
                                        fontSize:(CGFloat)fontSize
                                           color:(UIColor *)color
                                      background:(UIColor *)background
                                         maxSize:(CGSize)maxSize;

/// 该章正文字数（目录里显示用）
- (NSUInteger)characterCountOfChapter:(NSUInteger)index;

- (NSUInteger)totalCharacters;
@end

@interface MTTextUtil : NSObject
/// 编码嗅探 + 解码：BOM → UTF-8 → GB18030 → Big5 → Latin1
+ (NSString *)decodeTextData:(NSData *)data;
/// HTML/XML → 纯文本（解析失败时的兜底）
+ (NSString *)plainTextFromHTML:(NSString *)html;
/// HTML/XML → 富文本（保留段落、标题、粗体、斜体、图片）
+ (NSAttributedString *)attributedStringFromHTML:(NSString *)html
                                             zip:(MTZipReader *)zip
                                        basePath:(NSString *)basePath
                                        fontSize:(CGFloat)fontSize
                                           color:(UIColor *)color
                                      background:(UIColor *)background
                                         maxSize:(CGSize)maxSize
                                      imageCache:(NSMutableDictionary *)cache;
/// 规范 EPUB 内部相对路径（处理 ../ 与百分号编码）
+ (NSString *)normalizeZipPath:(NSString *)path relativeTo:(NSString *)base;
/// HTML 实体解码
+ (NSString *)decodeEntities:(NSString *)text;
+ (NSString *)tidyPlainText:(NSString *)text;
@end
