//
//  MTHTML.m —— HTML/XHTML → 富文本（NSAttributedString）
//
//  支持的样式来源（按优先级从低到高）：
//    1. 标签语义（h1-h6 / b / strong / i / em / p ...）
//    2. 外部样式表 <link rel="stylesheet" href="xxx.css">   ← EPUB 的样式主要在这里
//    3. 内嵌 <style>...</style>
//    4. 标签的 class="..." 属性
//    5. 标签的 style="..." 内联属性
//
//  只做「能明显看出来」的样式：颜色、粗细、斜体、字号缩放。
//  不做盒模型/浮动/定位 —— 那是浏览器的事，阅读器重排后没意义。
//

#import <UIKit/UIKit.h>
#import "MTBook.h"
#import "MTZip.h"

static NSString *MTAttrValueIn(NSString *body, NSUInteger index);

// ============================================================
//  颜色小工具
// ============================================================

static CGFloat MTLum(UIColor *c) {
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if (![c getRed:&r green:&g blue:&b alpha:&a]) {
        CGFloat w = 0;
        if ([c getWhite:&w alpha:&a]) return w;
        return 1;
    }
    return 0.299 * r + 0.587 * g + 0.114 * b;
}

static UIColor *MTMix(UIColor *a, UIColor *b, CGFloat t) {
    CGFloat ar=0, ag=0, ab=0, aa=1, br=0, bg=0, bb=0, ba=1;
    [a getRed:&ar green:&ag blue:&ab alpha:&aa];
    [b getRed:&br green:&bg blue:&bb alpha:&ba];
    return [UIColor colorWithRed:ar+(br-ar)*t green:ag+(bg-ag)*t blue:ab+(bb-ab)*t alpha:1];
}

/// 保证颜色在给定背景上看得见：和背景亮度差太小时，往反方向推
static UIColor *MTLegible(UIColor *c, UIColor *bg) {
    if (!c || !bg) return c;
    CGFloat lb = MTLum(bg), lc = MTLum(c);
    if (fabs(lb - lc) >= 0.30) return c;
    if (lb < 0.5) return MTMix(c, UIColor.whiteColor, 0.75);   // 深底 → 提亮
    return MTMix(c, UIColor.blackColor, 0.70);                 // 浅底 → 压暗
}

/// CSS 颜色值 → UIColor（支持 #rgb / #rrggbb / rgb() / rgba() / 若干具名色）
static UIColor *MTColorFromCSS(NSString *raw) {
    if (raw.length == 0) return nil;
    NSString *v = [raw stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]].lowercaseString;
    if ([v isEqualToString:@"inherit"] || [v isEqualToString:@"initial"] ||
        [v isEqualToString:@"transparent"] || [v isEqualToString:@"currentcolor"]) return nil;

    if ([v hasPrefix:@"#"]) {
        NSString *h = [v substringFromIndex:1];
        unsigned int r = 0, g = 0, b = 0;
        if (h.length == 3) {
            NSString *rr = [NSString stringWithFormat:@"%c%c", [h characterAtIndex:0], [h characterAtIndex:0]];
            NSString *gg = [NSString stringWithFormat:@"%c%c", [h characterAtIndex:1], [h characterAtIndex:1]];
            NSString *bb = [NSString stringWithFormat:@"%c%c", [h characterAtIndex:2], [h characterAtIndex:2]];
            sscanf(rr.UTF8String, "%x", &r);
            sscanf(gg.UTF8String, "%x", &g);
            sscanf(bb.UTF8String, "%x", &b);
            return [UIColor colorWithRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:1];
        }
        if (h.length >= 6) {
            sscanf([h substringToIndex:2].UTF8String, "%x", &r);
            sscanf([[h substringWithRange:NSMakeRange(2,2)] UTF8String], "%x", &g);
            sscanf([[h substringWithRange:NSMakeRange(4,2)] UTF8String], "%x", &b);
            return [UIColor colorWithRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:1];
        }
        return nil;
    }
    if ([v hasPrefix:@"rgb"]) {
        NSRange open = [v rangeOfString:@"("];
        NSRange close = [v rangeOfString:@")"];
        if (open.location == NSNotFound || close.location == NSNotFound) return nil;
        NSString *inner = [v substringWithRange:NSMakeRange(NSMaxRange(open),
                                                            close.location - NSMaxRange(open))];
        NSArray *parts = [inner componentsSeparatedByString:@","];
        if (parts.count < 3) return nil;
        CGFloat comp[3];
        for (int i = 0; i < 3; i++) {
            NSString *p = [parts[i] stringByTrimmingCharactersInSet:
                           [NSCharacterSet whitespaceCharacterSet]];
            if ([p hasSuffix:@"%"]) comp[i] = MAX(0, MIN(1, p.doubleValue / 100.0));
            else comp[i] = MAX(0, MIN(1, p.doubleValue / 255.0));
        }
        return [UIColor colorWithRed:comp[0] green:comp[1] blue:comp[2] alpha:1];
    }

    static NSDictionary *named = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        named = @{
            @"black": UIColor.blackColor, @"white": UIColor.whiteColor,
            @"red": [UIColor colorWithRed:0.86 green:0.15 blue:0.15 alpha:1],
            @"green": [UIColor colorWithRed:0.13 green:0.55 blue:0.13 alpha:1],
            @"blue": [UIColor colorWithRed:0.13 green:0.31 blue:0.85 alpha:1],
            @"gray": UIColor.grayColor, @"grey": UIColor.grayColor,
            @"silver": [UIColor colorWithWhite:0.75 alpha:1],
            @"purple": [UIColor colorWithRed:0.50 green:0.19 blue:0.72 alpha:1],
            @"orange": [UIColor colorWithRed:0.95 green:0.55 blue:0.10 alpha:1],
            @"brown": [UIColor colorWithRed:0.55 green:0.35 blue:0.20 alpha:1],
            @"maroon": [UIColor colorWithRed:0.50 green:0.13 blue:0.13 alpha:1],
            @"navy": [UIColor colorWithRed:0.10 green:0.15 blue:0.45 alpha:1],
            @"teal": [UIColor colorWithRed:0.10 green:0.50 blue:0.50 alpha:1],
            @"darkred": [UIColor colorWithRed:0.55 green:0.05 blue:0.05 alpha:1],
            @"darkblue": [UIColor colorWithRed:0.05 green:0.10 blue:0.45 alpha:1],
            @"darkgreen": [UIColor colorWithRed:0.05 green:0.30 blue:0.10 alpha:1],
            @"darkgray": [UIColor darkGrayColor], @"darkgrey": [UIColor darkGrayColor],
            @"lightgray": [UIColor lightGrayColor], @"lightgrey": [UIColor lightGrayColor],
            @"gold": [UIColor colorWithRed:0.85 green:0.65 blue:0.13 alpha:1],
            @"pink": [UIColor colorWithRed:0.95 green:0.55 blue:0.65 alpha:1],
            @"olive": [UIColor colorWithRed:0.50 green:0.50 blue:0.10 alpha:1],
            @"crimson": [UIColor colorWithRed:0.86 green:0.08 blue:0.24 alpha:1],
            @"indigo": [UIColor colorWithRed:0.29 green:0.10 blue:0.55 alpha:1],
        };
    });
    return named[v];
}

// ============================================================
//  极简 CSS：只抽颜色 / 粗细 / 斜体 / 字号
// ============================================================

/// "color:#f00; font-weight:bold" → @{color, bold, italic, scale}
static NSDictionary *MTDeclarations(NSString *decl) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    if (decl.length == 0) return out;
    NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];

    for (NSString *pair in [decl componentsSeparatedByString:@";"]) {
        NSRange colon = [pair rangeOfString:@":"];
        if (colon.location == NSNotFound) continue;
        NSString *key = [[pair substringToIndex:colon.location]
                         stringByTrimmingCharactersInSet:ws].lowercaseString;
        NSString *val = [[pair substringFromIndex:colon.location + 1]
                         stringByTrimmingCharactersInSet:ws].lowercaseString;
        if (key.length == 0 || val.length == 0) continue;

        if ([key isEqualToString:@"color"]) {
            UIColor *c = MTColorFromCSS(val);
            if (c) out[@"color"] = c;
        } else if ([key isEqualToString:@"font-weight"]) {
            if ([val containsString:@"bold"] || val.integerValue >= 600) out[@"bold"] = @YES;
        } else if ([key isEqualToString:@"font-style"]) {
            if ([val containsString:@"italic"] || [val containsString:@"oblique"]) out[@"italic"] = @YES;
        } else if ([key isEqualToString:@"text-decoration"]) {
            if ([val containsString:@"underline"]) out[@"underline"] = @YES;
        } else if ([key isEqualToString:@"font-size"]) {
            if ([val containsString:@"smaller"]) out[@"scale"] = @0.85;
            else if ([val containsString:@"larger"]) out[@"scale"] = @1.18;
            else if ([val hasSuffix:@"%"]) {
                CGFloat s = val.doubleValue / 100.0;
                if (s >= 0.5 && s <= 2.5) out[@"scale"] = @(s);
            } else if ([val hasSuffix:@"em"] || [val hasSuffix:@"rem"]) {
                CGFloat s = val.doubleValue;
                if (s >= 0.5 && s <= 2.5) out[@"scale"] = @(s);
            }
        }
    }
    return out;
}

/// 从选择器里取关键标识：优先最后一个 .class，否则标签名
static NSString *MTRuleKey(NSString *selector) {
    NSString *s = [selector stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (s.length == 0) return nil;
    NSArray *classes = [s componentsSeparatedByString:@"."];
    if (classes.count > 1) {
        NSString *last = classes.lastObject;
        // 去掉伪类 / 组合符
        NSCharacterSet *cut = [NSCharacterSet characterSetWithCharactersInString:@": [>+~"];
        NSRange r = [last rangeOfCharacterFromSet:cut];
        if (r.location != NSNotFound) last = [last substringToIndex:r.location];
        last = [last stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (last.length) return [@"." stringByAppendingString:last];
    }
    // 纯标签选择器
    NSRange r = [s rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@" :[>+~"]];
    if (r.location != NSNotFound) s = [s substringToIndex:r.location];
    s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (s.length == 0 || [s hasPrefix:@"."] || [s hasPrefix:@"#"] || [s hasPrefix:@"*"]) return nil;
    return [@"@tag:" stringByAppendingString:s];
}

/// 解析 CSS 文本 → @{ ".class"/"@tag:x" : attrs }
static NSDictionary *MTCSSRules(NSString *css) {
    NSMutableDictionary *rules = [NSMutableDictionary dictionary];
    if (css.length == 0) return rules;

    NSMutableString *src = [css mutableCopy];
    // 去注释
    NSRegularExpression *cmt = [NSRegularExpression
        regularExpressionWithPattern:@"\\/\\*.*?\\*\\/" options:NSRegularExpressionDotMatchesLineSeparators error:NULL];
    [cmt replaceMatchesInString:src options:0 range:NSMakeRange(0, src.length) withTemplate:@""];
    // 去 @media / @font-face 等 at-rule 的头部（保留内部规则，够用）
    NSRegularExpression *at = [NSRegularExpression
        regularExpressionWithPattern:@"@[a-zA-Z-]+[^{;]*;" options:0 error:NULL];
    [at replaceMatchesInString:src options:0 range:NSMakeRange(0, src.length) withTemplate:@""];

    NSRegularExpression *ruleRe = [NSRegularExpression
        regularExpressionWithPattern:@"([^{}]+)\\{([^}]*)\\}" options:0 error:NULL];
    for (NSTextCheckingResult *m in [ruleRe matchesInString:src options:0
                                                      range:NSMakeRange(0, src.length)]) {
        NSString *selector = [src substringWithRange:[m rangeAtIndex:1]];
        NSString *decl = [src substringWithRange:[m rangeAtIndex:2]];
        NSDictionary *attrs = MTDeclarations(decl);
        if (attrs.count == 0) continue;

        for (NSString *one in [selector componentsSeparatedByString:@","]) {
            NSString *key = MTRuleKey(one);
            if (!key) continue;
            NSMutableDictionary *merged = [rules[key] mutableCopy];
            if (!merged) merged = [NSMutableDictionary dictionary];
            [merged addEntriesFromDictionary:attrs];
            rules[key] = merged;
        }
    }
    return rules;
}

/// 收集 CSS：外部 <link rel=stylesheet> + 内嵌 <style>
static NSString *MTCollectCSS(NSString *html, MTZipReader *zip, NSString *basePath) {
    NSMutableString *css = [NSMutableString string];

    // 内嵌
    NSRegularExpression *styleRe = [NSRegularExpression
        regularExpressionWithPattern:@"<style[^>]*>(.*?)</style>"
                             options:NSRegularExpressionDotMatchesLineSeparators | NSRegularExpressionCaseInsensitive
                               error:NULL];
    for (NSTextCheckingResult *m in [styleRe matchesInString:html options:0
                                                       range:NSMakeRange(0, html.length)]) {
        [css appendString:[html substringWithRange:[m rangeAtIndex:1]]];
        [css appendString:@"\n"];
    }

    // 外部
    if (zip) {
        NSRegularExpression *linkRe = [NSRegularExpression
            regularExpressionWithPattern:@"<link[^>]*>"
                                 options:NSRegularExpressionCaseInsensitive error:NULL];
        NSRegularExpression *hrefRe = [NSRegularExpression
            regularExpressionWithPattern:@"href\\s*=\\s*[\"']([^\"']+)[\"']"
                                 options:NSRegularExpressionCaseInsensitive error:NULL];
        for (NSTextCheckingResult *m in [linkRe matchesInString:html options:0
                                                         range:NSMakeRange(0, html.length)]) {
            NSString *tag = [html substringWithRange:m.range];
            NSString *low = tag.lowercaseString;
            if (![low containsString:@"stylesheet"] && ![low containsString:@".css"]) continue;
            NSTextCheckingResult *h = [hrefRe firstMatchInString:tag options:0
                                                           range:NSMakeRange(0, tag.length)];
            if (!h) continue;
            NSString *href = [tag substringWithRange:[h rangeAtIndex:1]];
            NSString *path = [MTTextUtil normalizeZipPath:href relativeTo:basePath];
            NSString *fileCSS = [zip stringForName:path];
            if (fileCSS.length) {
                [css appendString:fileCSS];
                [css appendString:@"\n"];
            }
        }
    }
    return css;
}

// ============================================================
//  构建器
// ============================================================

@interface MTHTMLBuilder : NSObject
@property (nonatomic, strong) NSMutableAttributedString *out;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *styles;   // 每层带 "tag"
@property (nonatomic, assign) CGFloat fontSize;
@property (nonatomic, strong) UIColor *baseColor;
@property (nonatomic, strong) UIColor *background;
@property (nonatomic, strong) NSParagraphStyle *paragraphStyle;
@property (nonatomic, strong) MTZipReader *zip;
@property (nonatomic, copy)   NSString *basePath;
@property (nonatomic, assign) CGSize maxSize;
@property (nonatomic, strong) NSMutableDictionary *cache;
@property (nonatomic, strong) NSDictionary *css;
@property (nonatomic, copy)   NSString *skipTag;
@property (nonatomic, assign) NSInteger skipDepth;
@end

static BOOL MTEndsWithNewline(NSMutableAttributedString *s) {
    return s.length == 0 || [s.string characterAtIndex:s.length - 1] == '\n';
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

- (void)ensureBreak {
    if (self.out.length == 0) return;
    if (!MTEndsWithNewline(self.out)) {
        [self.out appendAttributedString:[[NSAttributedString alloc]
            initWithString:@"\n" attributes:[self currentAttributes]]];
    }
}

- (void)pushStyle:(NSDictionary *)attrs forTag:(NSString *)tag {
    if (attrs.count == 0) return;
    NSMutableDictionary *e = [attrs mutableCopy];
    e[@"tag"] = tag;
    [self.styles addObject:e];
}

/// 关闭标签：弹出最近一个同名层，以及它上面的所有层（容错畸形 HTML）
- (void)popTag:(NSString *)name {
    for (NSInteger i = (NSInteger)self.styles.count - 1; i >= 0; i--) {
        NSString *t = self.styles[i][@"tag"];
        if ([t isEqualToString:name]) {
            [self.styles removeObjectsInRange:NSMakeRange(i, self.styles.count - i)];
            return;
        }
    }
}

- (NSDictionary *)currentAttributes {
    BOOL bold = NO, italic = NO, underline = NO;
    CGFloat scale = 1.0;
    UIColor *cssColor = nil;
    for (NSDictionary *s in self.styles) {
        if ([s[@"bold"] boolValue]) bold = YES;
        if ([s[@"italic"] boolValue]) italic = YES;
        if ([s[@"underline"] boolValue]) underline = YES;
        if (s[@"scale"]) scale *= [s[@"scale"] doubleValue];
        if (s[@"color"]) cssColor = s[@"color"];      // 后进覆盖
    }
    CGFloat size = MAX(8.0, self.fontSize * MIN(2.5, MAX(0.5, scale)));
    UIFont *font;
    if (bold) font = [UIFont boldSystemFontOfSize:size];
    else if (italic) font = [UIFont italicSystemFontOfSize:size];
    else font = [UIFont systemFontOfSize:size];

    UIColor *fg = cssColor ? MTLegible(cssColor, self.background) : self.baseColor;

    NSMutableDictionary *a = [NSMutableDictionary dictionary];
    a[NSFontAttributeName] = font;
    if (fg) a[NSForegroundColorAttributeName] = fg;
    if (self.paragraphStyle) a[NSParagraphStyleAttributeName] = self.paragraphStyle;
    if (underline) a[NSUnderlineStyleAttributeName] = @(NSUnderlineStyleSingle);
    return a;
}

- (void)appendText:(NSString *)raw {
    if (raw.length == 0) return;
    NSString *text = [MTTextUtil decodeEntities:raw];
    text = [text stringByReplacingOccurrencesOfString:@"[\\s\\u00A0\\u3000]+"
                                            withString:@" "
                                               options:NSRegularExpressionSearch
                                                 range:NSMakeRange(0, text.length)];
    if (text.length == 0) return;

    if (MTEndsWithNewline(self.out)) {
        while (text.length > 0 && [text characterAtIndex:0] == ' ') {
            text = [text substringFromIndex:1];
        }
    }
    if (text.length == 0) return;

    [self.out appendAttributedString:[[NSAttributedString alloc]
        initWithString:text attributes:[self currentAttributes]]];
}

- (void)appendLineBreak {
    [self.out appendAttributedString:[[NSAttributedString alloc]
        initWithString:@"\n" attributes:[self currentAttributes]]];
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

    UIImage *img = self.cache ? self.cache[full] : nil;
    if (!img) {
        NSData *d = [self.zip dataForName:full];
        if (d) img = [UIImage imageWithData:d];
        if (img && self.cache) self.cache[full] = img;
    }
    if (!img || img.size.width < 1) return;

    CGFloat maxW = MAX(60, self.maxSize.width);
    CGFloat maxH = MAX(60, self.maxSize.height * 0.92);
    CGFloat w = img.size.width, h = img.size.height;
    CGFloat scale = MIN(1.0, MIN(maxW / w, maxH / h));
    w *= scale; h *= scale;
    if (w < 1 || h < 1) return;

    [self ensureBreak];

    NSTextAttachment *att = [[NSTextAttachment alloc] init];
    att.image = img;
    att.bounds = CGRectMake(0, -2, w, h);

    NSMutableDictionary *a = [[self currentAttributes] mutableCopy];
    a[NSAttachmentAttributeName] = att;
    [self.out appendAttributedString:[[NSAttributedString alloc]
        initWithString:@"\uFFFC" attributes:a]];

    [self ensureBreak];
}

// ---------------- 收尾 ----------------

- (void)normalize {
    NSMutableAttributedString *s = self.out;
    NSUInteger guard = 0, i = 0;
    while (i + 2 < s.length && guard++ < 200000) {
        if ([[s.string substringWithRange:NSMakeRange(i, 3)] isEqualToString:@"\n\n\n"]) {
            [s deleteCharactersInRange:NSMakeRange(i, 1)];
        } else i++;
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
//  主流程
// ============================================================

@implementation MTTextUtil (HTML)

+ (NSString *)normalizeZipPath:(NSString *)path relativeTo:(NSString *)base {
    NSString *decoded = path;
    NSString *d = [path stringByRemovingPercentEncoding];
    if (d) decoded = d;
    NSString *combined = (base.length > 0) ? [base stringByAppendingPathComponent:decoded] : decoded;
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
                                      background:(UIColor *)background
                                         maxSize:(CGSize)maxSize
                                      imageCache:(NSMutableDictionary *)cache {
    if (html.length == 0) return [[NSAttributedString alloc] initWithString:@""];

    MTHTMLBuilder *b = [MTHTMLBuilder new];
    b.fontSize = fontSize;
    b.baseColor = color;
    b.background = background ?: UIColor.whiteColor;
    b.zip = zip;
    b.basePath = basePath;
    b.maxSize = maxSize;
    b.cache = cache;
    b.css = MTCSSRules(MTCollectCSS(html, zip, basePath));

    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle defaultParagraphStyle].mutableCopy;
    ps.lineSpacing = fontSize * 0.45;
    ps.paragraphSpacing = fontSize * 0.5;
    b.paragraphStyle = ps;

    NSSet *block = [NSSet setWithArray:@[@"p", @"div", @"h1", @"h2", @"h3", @"h4", @"h5", @"h6",
                                         @"li", @"ul", @"ol", @"blockquote", @"tr", @"td", @"th",
                                         @"table", @"section", @"article", @"header", @"footer",
                                         @"figure", @"figcaption", @"pre", @"dl", @"dt", @"dd",
                                         @"body", @"html", @"center", @"aside", @"nav"]];
    NSSet *skip = [NSSet setWithArray:@[@"script", @"style", @"head", @"title", @"meta", @"link",
                                        @"svg", @"path", @"defs", @"symbol", @"image", @"rect",
                                        @"circle", @"g", @"use"]];
    NSSet *voidTags = [NSSet setWithArray:@[@"br", @"hr", @"img", @"meta", @"link", @"input"]];
    NSDictionary *headingScale = @{@"h1": @1.55, @"h2": @1.35, @"h3": @1.22,
                                   @"h4": @1.12, @"h5": @1.06, @"h6": @1.0};

    NSRegularExpression *tagRe = [NSRegularExpression regularExpressionWithPattern:@"<[^>]*>"
                                                                          options:0 error:NULL];
    NSUInteger pos = 0, guard = 0;
    while (pos < html.length && guard++ < 300000) {
        NSRange search = NSMakeRange(pos, html.length - pos);
        NSTextCheckingResult *m = [tagRe firstMatchInString:html options:0 range:search];

        NSUInteger textEnd = m ? m.range.location : html.length;
        if (textEnd > pos && b.skipTag == nil) {
            [b appendText:[html substringWithRange:NSMakeRange(pos, textEnd - pos)]];
        }
        if (!m) break;
        pos = NSMaxRange(m.range);

        NSString *tag = [html substringWithRange:m.range];
        if ([tag hasPrefix:@"<!"] || [tag hasPrefix:@"<?"]) continue;

        BOOL closing = [tag hasPrefix:@"</"];
        NSString *body = [tag substringWithRange:NSMakeRange(closing ? 2 : 1,
                                                             MAX(0, (NSInteger)tag.length - (closing ? 3 : 2)))];
        NSRange nameEnd = [body rangeOfCharacterFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *name = (nameEnd.location == NSNotFound ? body : [body substringToIndex:nameEnd.location])
                          .lowercaseString;
        name = [name stringByTrimmingCharactersInSet:
                [NSCharacterSet characterSetWithCharactersInString:@"/ "]];
        if (name.length == 0) continue;
        BOOL selfClosing = [body hasSuffix:@"/"];

        // ---- 跳过区（script/style/svg）----
        if (b.skipTag) {
            if ([name isEqualToString:b.skipTag]) {
                if (closing) {
                    if (b.skipDepth <= 1) { b.skipTag = nil; b.skipDepth = 0; }
                    else b.skipDepth--;
                } else if (!selfClosing) b.skipDepth++;
            }
            continue;
        }
        if (!closing && [skip containsObject:name]) {
            if (!selfClosing) { b.skipTag = name; b.skipDepth = 1; }
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
        if ([name isEqualToString:@"br"]) {
            if (!closing) [b appendLineBreak];
            continue;
        }
        if ([name isEqualToString:@"hr"]) {
            if (!closing) { [b ensureBreak]; [b appendLineBreak]; }
            continue;
        }

        // ---- 组装这一层的样式（CSS class / 标签规则 / 内联 style）----
        NSMutableDictionary *attrs = [NSMutableDictionary dictionary];
        if (!closing) {
            // 标签级规则
            NSDictionary *tagRule = b.css[[@"@tag:" stringByAppendingString:name]];
            if (tagRule) [attrs addEntriesFromDictionary:tagRule];
            // class
            NSRange classRange = [body rangeOfString:@"class" options:NSCaseInsensitiveSearch];
            if (classRange.location != NSNotFound) {
                NSString *cls = MTAttrValueIn(body, classRange.location + classRange.length);
                for (NSString *one in [cls componentsSeparatedByCharactersInSet:
                                       [NSCharacterSet whitespaceAndNewlineCharacterSet]]) {
                    if (one.length == 0) continue;
                    NSDictionary *r = b.css[[@"." stringByAppendingString:one.lowercaseString]];
                    if (r) [attrs addEntriesFromDictionary:r];
                }
            }
            // 内联 style（最高优先级）
            NSRange styleRange = [body rangeOfString:@"style" options:NSCaseInsensitiveSearch];
            if (styleRange.location != NSNotFound) {
                NSString *decl = MTAttrValueIn(body, styleRange.location + styleRange.length);
                if (decl.length) [attrs addEntriesFromDictionary:MTDeclarations(decl)];
            }
            // 语义标签兜底
            NSNumber *hs = headingScale[name];
            if (hs) { attrs[@"bold"] = @YES; }
            if ([@[@"b", @"strong"] containsObject:name]) attrs[@"bold"] = @YES;
            if ([@[@"i", @"em", @"cite"] containsObject:name]) attrs[@"italic"] = @YES;
            if ([@[@"u"] containsObject:name]) attrs[@"underline"] = @YES;
            if (hs && !attrs[@"scale"]) attrs[@"scale"] = hs;

            // <font color="...">
            if ([name isEqualToString:@"font"]) {
                NSRange cr = [body rangeOfString:@"color" options:NSCaseInsensitiveSearch];
                if (cr.location != NSNotFound) {
                    NSString *cv = MTAttrValueIn(body, cr.location + cr.length);
                    UIColor *c = MTColorFromCSS(cv);
                    if (c) attrs[@"color"] = c;
                }
            }
        }

        // ---- 块级：前后断行 ----
        BOOL isBlock = [block containsObject:name];
        if (isBlock) {
            [b ensureBreak];
            if ([name hasPrefix:@"h"]) [b ensureBreak];
        }

        // ---- 压栈 / 出栈 ----
        if (closing) {
            [b popTag:name];
            if (isBlock) [b ensureBreak];
        } else if (!selfClosing) {
            [b pushStyle:attrs forTag:name];
        }
    }

    [b normalize];
    return b.out;
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

@end
