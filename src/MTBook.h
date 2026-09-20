//
//  MTBook.h —— 书籍模型与解析器
//  TXT：编码嗅探（BOM / UTF-8 / GB18030）+ 章节自动切分
//  EPUB：container.xml → .opf → spine，逐章提取正文
//

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, MTBookFormat) {
    MTBookFormatTXT = 0,
    MTBookFormatEPUB,
    MTBookFormatMarkdown,
};

@interface MTChapter : NSObject
@property (nonatomic, copy)   NSString *title;
@property (nonatomic, copy)   NSString *text;     // EPUB 直接存；TXT 为 nil，用 range 懒加载
@property (nonatomic, assign) NSRange   range;    // TXT 在全书文本中的位置
@property (nonatomic, assign) BOOL      hasRange;
@end

@interface MTBook : NSObject
@property (nonatomic, copy)   NSString *path;
@property (nonatomic, copy)   NSString *title;
@property (nonatomic, copy)   NSString *author;
@property (nonatomic, assign) MTBookFormat format;
@property (nonatomic, strong) NSArray<MTChapter *> *chapters;
@property (nonatomic, copy)   NSString *plainText;   // TXT 的全文（EPUB 为 nil）

+ (instancetype)bookAtPath:(NSString *)path error:(NSError **)error;

/// 取第 index 章正文（TXT 懒加载切片）
- (NSString *)textOfChapter:(NSUInteger)index;
- (NSUInteger)totalCharacters;

@end

@interface MTTextUtil : NSObject
/// 编码嗅探 + 解码：BOM → UTF-8 → GB18030 → Latin1
+ (NSString *)decodeTextData:(NSData *)data;
/// HTML/XML → 纯文本
+ (NSString *)plainTextFromHTML:(NSString *)html;
/// 压缩多余空行
+ (NSString *)tidyPlainText:(NSString *)text;
@end
