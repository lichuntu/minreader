//
//  MTHTML.m —— HTML/XHTML → 富文本（NSAttributedString）
//  目的：EPUB 不能只当纯文本读，要保住封面图、插图、标题层级、加粗斜体。
//
//  为什么手写扫描器而不是 NSXMLParser：
//  真实 EPUB 里 XHTML 经常不规范（<br> 不闭合、未声明的 &nbsp;），
//  NSXMLParser 会直接罢工。手写扫描器对畸形标签更宽容，坏标签忽略即可。
//

#import <UIKit/UIKit.h>
#import "MTBook.h"
#import "MTZip.h"

// ============================================================
//  构建器
// ============================================================

@interface MTHTMLBuilder : NSObject
@property (nonatomic, strong) NSMutableAttributedString *out;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *styles;
@property (nonatomic, assign) CGFloat fontSize;
@property (nonatomic, strong) UIColor *color;
@property (nonatomic, strong) NSParagraphStyle *paragraphStyle;
@property (nonatomic, strong) MTZipReader *zip;
@property (nonatomic, copy)   NSString *basePath;
@property (nonatomic, assign) CGSize maxSize;
@property (nonatomic, strong) NSMutableDictionary *cache;
@property (nonatomic, copy)   NSString *skipTag;      // 正在跳过的标签（script/style/head）
@property (nonatomic, assign) NSInteger skipDepth;
@end

/// 从样式栈里弹出最近一个匹配的样式
static void MTPopStyle(MTHTMLBuilder *b, NSDictionary *marker) {
    for (NSInteger i = (NSInteger)b.styles.count - 1; i >= 0; i--) {
        NSDictionary *s = b.styles[i];
        BOOL hit = YES;
        for (NSString *k in marker) {
            if (![s[k] isEqual:marker[k]]) { hit = NO; break; }
        }
        if (hit) {
            [b.styles removeObjectAtIndex:i];
            return;
        }
    }
}

/// 从标签属性片段里取引号内的值
static NSString *MTAttrValueIn(NSString *body, NSUInteger index) {
    if (index >= body.length) return nil;
    NSRange eq = [body rangeOfString:@"=" options:0
                               range:NSMakeRange(index, body.length - index)];
    if (eq.location == NSNotFound) return nil;
    NSUInteger p = eq.location + 1;
    if (p >= body.length) return nil;
    unichar q = [body characterAtIndex:p];
    if (q == '"' || q == '\'') {
        NSRange rest = NSMakeRange(p + 1, body.length - p - 1);
        NSRange close = [body rangeOfString:[NSString stringWithCharacters:&q length:1]
                                    options:0 range:rest];
        if (close.location == NSNotFound) return nil;
        return [body substringWithRange:NSMakeRange(p + 1, close.location - p - 1)];
    }
    NSRange rest = NSMakeRange(p, body.length - p);
    NSRange sp = [body rangeOfCharacterFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]
                                       options:0 range:rest];
    NSUInteger end = (sp.location == NSNotFound) ? body.length : sp.location;
    return [body substringWithRange:NSMakeRange(p, end - p)];
}

@implementation MTHTMLBuilder

- (instancetype)init {
    self = [super init];
    if (self) {
        _out = [[NSMutableAttributedString alloc] init];
        _styles = [NSMutableArray array];
    }
    return self;
}

- (NSString *)plain {
    return self.out.string;
}

- (BOOL)endsWithNewline {
    NSString *s = self.out.string;
    return s.length == 0 || [s characterAtIndex:s.length - 1] == '\n';
}

/// 保证当前在一个新段落的开头
- (void)ensureBreak {
    if (self.out.length == 0) return;
    if (![self endsWithNewline]) {
        [self.out appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"
                                                                        attributes:[self currentAttributes]]];
    }
}

- (NSDictionary *)currentAttributes {
    BOOL bold = NO, italic = NO;
    CGFloat scale = 1.0;
    for (NSDictionary *s in self.styles) {
        if ([s[@"bold"] boolValue]) bold = YES;
        if ([s[@"italic"] boolValue]) italic = YES;
        scale *= [s[@"scale"] doubleValue];
    }
    CGFloat size = MAX(8.0, self.fontSize * scale);
    UIFont *font;
    if (bold) {
        font = [UIFont boldSystemFontOfSize:size];
    } else if (italic) {
        font = [UIFont italicSystemFontOfSize:size];
    } else {
        font = [UIFont systemFontOfSize:size];
    }
    NSMutableDictionary *a = [NSMutableDictionary dictionary];
    a[NSFontAttributeName] = font;
    if (self.color) a[NSForegroundColorAttributeName] = self.color;
    if (self.paragraphStyle) a[NSParagraphStyleAttributeName] = self.paragraphStyle;
    return a;
}

- (void)appendText:(NSString *)raw {
    if (raw.length == 0) return;
    NSString *text = [MTTextUtil decodeEntities:raw];
    // HTML 规则：连续空白折叠成一个空格
    text = [text stringByReplacingOccurrencesOfString:@"[\\s\\u00A0\\u3000]+"
                                            withString:@" "
                                               options:NSRegularExpressionSearch
                                                 range:NSMakeRange(0, text.length)];
    if (text.length == 0) return;

    // 段落开头的空格丢掉
    if ([self endsWithNewline]) {
        while (text.length > 0 && [text characterAtIndex:0] == ' ') {
            text = [text substringFromIndex:1];
        }
    }
    if (text.length == 0) return;

    // 整块空白且已经在段落开头 → 无意义
    if ([self endsWithNewline] && [text isEqualToString:@" "]) return;

    [self.out appendAttributedString:[[NSAttributedString alloc] initWithString:text
                                                                    attributes:[self currentAttributes]]];
}

- (void)appendLineBreak {
    [self.out appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"
                                                                    attributes:[self currentAttributes]]];
}

// ---------------- 图片 ----------------

- (void)appendImageWithSrc:(NSString *)src {
    if (src.length == 0 || !self.zip) return;

    NSString *clean = src;
    NSRange q = [clean rangeOfString:@"#"];
    if (q.location != NSNotFound) clean = [clean substringToIndex:q.location];
    if (clean.length == 0) return;

    NSString *full = [MTTextUtil normalizeZipPath:clean relativeTo:self.basePath];
    if (full.length == 0) return;

    UIImage *img = nil;
    if (self.cache) {
        img = self.cache[full];
    }
    if (!img) {
        NSData *d = [self.zip dataForName:full];
        if (d) img = [UIImage imageWithData:d];
        if (img && self.cache) self.cache[full] = img;
    }
    if (!img || img.size.width < 1) return;

    CGFloat maxW = MAX(60, self.maxSize.width);
    CGFloat maxH = MAX(60, self.maxSize.height * 0.92);
    CGFloat w = img.size.width;
    CGFloat h = img.size.height;
    CGFloat scale = MIN(1.0, MIN(maxW / w, maxH / h));
    w *= scale;
    h *= scale;
    if (w < 1 || h < 1) return;

    [self ensureBreak];

    NSTextAttachment *att = [[NSTextAttachment alloc] init];
    att.image = img;
    att.bounds = CGRectMake(0, -2, w, h);

    NSMutableDictionary *a = [[self currentAttributes] mutableCopy];
    a[NSAttachmentAttributeName] = att;
    [self.out appendAttributedString:[[NSAttributedString alloc] initWithString:@"\uFFFC"
                                                                    attributes:a]];

    [self ensureBreak];
}

// ---------------- 收尾 ----------------

- (void)normalize {
    NSMutableAttributedString *s = self.out;

    NSUInteger guard = 0;
    NSUInteger i = 0;
    while (i + 2 < s.length && guard++ < 100000) {
        if ([[s.string substringWithRange:NSMakeRange(i, 3)] isEqualToString:@"\n\n\n"]) {
            [s deleteCharactersInRange:NSMakeRange(i, 1)];
        } else {
            i++;
        }
    }
    while (s.length > 0) {
        unichar c = [s.string characterAtIndex:0];
        if (c == '\n' || c == ' ' || c == '\t') [s deleteCharactersInRange:NSMakeRange(0, 1)];
        else break;
    }
    while (s.length > 0) {
        unichar c = [s.string characterAtIndex:s.length - 1];
        if (c == '\n' || c == ' ' || c == '\t') [s deleteCharactersInRange:NSMakeRange(s.length - 1, 1)];
        else break;
    }
}

@end

// ============================================================
//  MTTextUtil 分类实现
// ============================================================

@implementation MTTextUtil (HTML)

+ (NSString *)normalizeZipPath:(NSString *)path relativeTo:(NSString *)base {
    NSString *decoded = path;
    if ([path containsString:@"%"] || ![path canBeConvertedToEncoding:NSASCIIStringEncoding]) {
        NSString *d = [path stringByRemovingPercentEncoding];
        if (d) decoded = d;
    }
    NSString *combined = (base.length > 0)
        ? [base stringByAppendingPathComponent:decoded]
        : decoded;
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *c in [combined componentsSeparatedByString:@"/"]) {
        if ([c isEqualToString:@"."]) continue;
        if ([c isEqualToString:@".."]) {
            if (parts.count) [parts removeLastObject];
            continue;
        }
        [parts addObject:c];
    }
    return [parts componentsJoinedByString:@"/"];
}

+ (NSAttributedString *)attributedStringFromHTML:(NSString *)html
                                             zip:(MTZipReader *)zip
                                        basePath:(NSString *)basePath
                                        fontSize:(CGFloat)fontSize
                                           color:(UIColor *)color
                                         maxSize:(CGSize)maxSize
                                      imageCache:(NSMutableDictionary *)cache {
    if (html.length == 0) return [[NSAttributedString alloc] initWithString:@""];

    MTHTMLBuilder *b = [MTHTMLBuilder new];
    b.fontSize = fontSize;
    b.color = color;
    b.zip = zip;
    b.basePath = basePath;
    b.maxSize = maxSize;
    b.cache = cache;

    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle defaultParagraphStyle].mutableCopy;
    ps.lineSpacing = fontSize * 0.45;
    ps.paragraphSpacing = fontSize * 0.5;
    b.paragraphStyle = ps;

    // 块级 / 内联 / 跳过 标签集合
    NSSet *block = [NSSet setWithArray:@[@"p", @"div", @"h1", @"h2", @"h3", @"h4", @"h5", @"h6",
                                         @"li", @"ul", @"ol", @"blockquote", @"tr", @"table",
                                         @"section", @"article", @"header", @"footer", @"figure",
                                         @"figcaption", @"br", @"hr", @"pre", @"dl", @"dt", @"dd",
                                         @"body", @"html", @"center"]];
    NSSet *skip = [NSSet setWithArray:@[@"script", @"style", @"head", @"title", @"meta", @"link",
                                        @"svg", @"path", @"defs", @"symbol"]];
    NSDictionary *scaleFor = @{@"h1": @1.55, @"h2": @1.35, @"h3": @1.22,
                               @"h4": @1.12, @"h5": @1.06, @"h6": @1.0};

    NSRegularExpression *tagRe = [NSRegularExpression
        regularExpressionWithPattern:@"<[^>]*>"
                             options:0 error:NULL];

    NSUInteger pos = 0;
    NSUInteger guard = 0;
    while (pos < html.length && guard++ < 200000) {
        NSRange search = NSMakeRange(pos, html.length - pos);
        NSTextCheckingResult *m = [tagRe firstMatchInString:html options:0 range:search];

        // 标签之间的文本
        NSUInteger textEnd = m ? m.range.location : html.length;
        if (textEnd > pos) {
            if (b.skipTag == nil) {
                [b appendText:[html substringWithRange:NSMakeRange(pos, textEnd - pos)]];
            }
        }
        if (!m) break;
        pos = NSMaxRange(m.range);

        NSString *tag = [html substringWithRange:m.range];

        // 注释 / 声明
        if ([tag hasPrefix:@"<!"] || [tag hasPrefix:@"<?"]) continue;

        BOOL closing = [tag hasPrefix:@"</"];
        NSString *body = [tag substringWithRange:NSMakeRange(closing ? 2 : 1,
                                                             MAX(0, (NSInteger)tag.length - (closing ? 3 : 2)))];

        // 取标签名
        NSRange nameEnd = [body rangeOfCharacterFromSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *name = (nameEnd.location == NSNotFound ? body : [body substringToIndex:nameEnd.location])
                          .lowercaseString;
        name = [name stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/ "]];
        if (name.length == 0) continue;

        // ---- 跳过区（script/style/svg）----
        if (b.skipTag) {
            if ([name isEqualToString:b.skipTag]) {
                if (closing) {
                    if (b.skipDepth <= 1) { b.skipTag = nil; b.skipDepth = 0; }
                    else b.skipDepth--;
                } else if (![body hasSuffix:@"/"]) {
                    b.skipDepth++;
                }
            }
            continue;
        }
        if (!closing && ([skip containsObject:name] || [name isEqualToString:@"image"])) {
            if (![body hasSuffix:@"/"]) { b.skipTag = name; b.skipDepth = 1; }
            continue;
        }

        // ---- 图片 ----
        if ([name isEqualToString:@"img"]) {
            if (!closing) {
                NSRange srcRange = [body rangeOfString:@"src" options:NSCaseInsensitiveSearch];
                if (srcRange.location != NSNotFound) {
                    NSString *src = MTAttrValueIn(body, srcRange.location + srcRange.length);
                    if (src.length) [b appendImageWithSrc:src];
                }
            }
            continue;
        }

        // ---- 换行 / 分割线 ----
        if ([name isEqualToString:@"br"]) {
            if (!closing) [b appendLineBreak];
            continue;
        }
        if ([name isEqualToString:@"hr"]) {
            if (!closing) { [b ensureBreak]; [b appendLineBreak]; }
            continue;
        }

        // ---- 块级 ----
        if ([block containsObject:name]) {
            if (closing) [b ensureBreak];
            else {
                [b ensureBreak];
                NSNumber *scale = scaleFor[name];
                if (scale) {
                    [b.styles addObject:@{@"bold": @YES, @"scale": scale}];
                }
            }
            continue;
        }

        // ---- 内联 ----
        if (closing) {
            // 从栈顶往回找同名（栈里只存属性，靠计数不便；这里按简单规则弹出最近一个同类型）
            if ([@[@"b", @"strong"] containsObject:name]) {
                MTPopStyle(b, @{@"bold": @YES});
            } else if ([@[@"i", @"em"] containsObject:name]) {
                MTPopStyle(b, @{@"italic": @YES});
            } else if (scaleFor[name]) {
                MTPopStyle(b, @{@"bold": @YES});
            }
        } else {
            if ([@[@"b", @"strong"] containsObject:name]) {
                [b.styles addObject:@{@"bold": @YES}];
            } else if ([@[@"i", @"em"] containsObject:name]) {
                [b.styles addObject:@{@"italic": @YES}];
            }
        }
    }

    [b normalize];
    return b.out;
}

@end
