//
//  MTBook.m
//

#import "MTBook.h"
#import "MTZip.h"

@implementation MTChapter
@end

// ============================================================
//  文本工具：编码嗅探 + HTML 清洗
// ============================================================

@interface MTTextUtil ()
+ (void)replaceIn:(NSMutableString *)s pattern:(NSString *)pattern with:(NSString *)rep;
+ (void)replaceIn:(NSMutableString *)s
          pattern:(NSString *)pattern
             with:(NSString *)rep
          options:(NSRegularExpressionOptions)opts;
+ (NSString *)decodeEntities:(NSString *)text;
@end

@implementation MTTextUtil

+ (NSString *)decodeTextData:(NSData *)data {
    if (data.length == 0) return @"";

    const uint8_t *b = data.bytes;
    NSUInteger n = data.length;

    // ---- 1. BOM ----
    if (n >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF) {
        return [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(3, n - 3)]
                                     encoding:NSUTF8StringEncoding] ?: @"";
    }
    if (n >= 2 && b[0] == 0xFF && b[1] == 0xFE) {
        return [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(2, n - 2)]
                                     encoding:NSUTF16LittleEndianStringEncoding] ?: @"";
    }
    if (n >= 2 && b[0] == 0xFE && b[1] == 0xFF) {
        return [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(2, n - 2)]
                                     encoding:NSUTF16BigEndianStringEncoding] ?: @"";
    }

    // ---- 2. 严格 UTF-8 ----
    NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (s) return s;

    // ---- 3. 中文最常见：GB18030（兼容 GBK / GB2312）----
    NSStringEncoding gb = CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingGB_18030_2000);
    s = [[NSString alloc] initWithData:data encoding:gb];
    if (s) return s;

    // ---- 4. Big5 ----
    NSStringEncoding big5 = CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingBig5);
    s = [[NSString alloc] initWithData:data encoding:big5];
    if (s) return s;

    // ---- 5. 兜底：不让内容丢失 ----
    s = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    return s ?: @"";
}

+ (NSString *)plainTextFromHTML:(NSString *)html {
    if (html.length == 0) return @"";
    NSMutableString *s = [html mutableCopy];

    // 先把常见的块级/换行标签换成换行符
    NSArray *pairs = @[
        @[@"<br\\s*/?>", @"\n"],
        @[@"</p\\s*>", @"\n"],
        @[@"</div\\s*>", @"\n"],
        @[@"</h[1-6]\\s*>", @"\n\n"],
        @[@"</li\\s*>", @"\n"],
        @[@"</tr\\s*>", @"\n"],
        @[@"</blockquote\\s*>", @"\n"],
        @[@"<hr\\s*/?>", @"\n———\n"],
    ];
    for (NSArray *p in pairs) {
        [self replaceIn:s pattern:p[0] with:p[1]];
    }

    // 删除整段 script / style / head
    for (NSString *tag in @[@"script", @"style", @"head", @"title"]) {
        NSString *pat = [NSString stringWithFormat:@"<%@[^>]*>.*?</%@\\s*>", tag, tag];
        [self replaceIn:s pattern:pat with:@"" options:NSRegularExpressionDotMatchesLineSeparators | NSRegularExpressionCaseInsensitive];
    }

    // 去掉剩余所有标签
    [self replaceIn:s pattern:@"<[^>]*>" with:@""];

    // 解码实体
    NSString *decoded = [self decodeEntities:s];
    return [self tidyPlainText:decoded];
}

+ (NSString *)tidyPlainText:(NSString *)text {
    if (text.length == 0) return @"";
    NSMutableString *s = [text mutableCopy];

    [self replaceIn:s pattern:@"\\r\\n?" with:@"\n"];
    [self replaceIn:s pattern:@"[ \\t\\x{00A0}\\x{3000}]+" with:@" "];
    [self replaceIn:s pattern:@" *\n *" with:@"\n"];
    [self replaceIn:s pattern:@"\n{3,}" with:@"\n\n"];
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

// ---------- 内部工具 ----------

+ (void)replaceIn:(NSMutableString *)s pattern:(NSString *)pattern with:(NSString *)rep {
    [self replaceIn:s pattern:pattern with:rep options:NSRegularExpressionCaseInsensitive];
}

+ (void)replaceIn:(NSMutableString *)s
          pattern:(NSString *)pattern
             with:(NSString *)rep
          options:(NSRegularExpressionOptions)opts {
    NSError *err = nil;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                       options:opts
                                                                         error:&err];
    if (!re) return;
    [re replaceMatchesInString:s
                       options:0
                         range:NSMakeRange(0, s.length)
                  withTemplate:rep];
}

+ (NSString *)decodeEntities:(NSString *)text {
    if ([text rangeOfString:@"&"].location == NSNotFound) return text;
    NSMutableString *s = [text mutableCopy];

    NSDictionary *named = @{
        @"&nbsp;": @" ", @"&amp;": @"&", @"&lt;": @"<", @"&gt;": @">",
        @"&quot;": @"\"", @"&apos;": @"'", @"&mdash;": @"—", @"&ndash;": @"–",
        @"&hellip;": @"…", @"&ldquo;": @"“", @"&rdquo;": @"”",
        @"&lsquo;": @"‘", @"&rsquo;": @"’", @"&middot;": @"·",
    };
    for (NSString *k in named) {
        [s replaceOccurrencesOfString:k withString:named[k]
                              options:NSCaseInsensitiveSearch
                                range:NSMakeRange(0, s.length)];
    }

    // 数字实体 &#123; / &#x1F600;
    NSRegularExpression *re = [NSRegularExpression
        regularExpressionWithPattern:@"&#(x?)([0-9a-fA-F]+);"
                             options:0 error:NULL];
    NSArray *matches = [re matchesInString:s options:0 range:NSMakeRange(0, s.length)];
    for (NSInteger i = (NSInteger)matches.count - 1; i >= 0; i--) {
        NSTextCheckingResult *m = matches[i];
        BOOL hex = [s substringWithRange:[m rangeAtIndex:1]].length > 0;
        NSString *num = [s substringWithRange:[m rangeAtIndex:2]];
        unsigned int code = hex ? (unsigned int)strtoul(num.UTF8String, NULL, 16)
                                : (unsigned int)strtoul(num.UTF8String, NULL, 10);
        if (code == 0 || code > 0x10FFFF) continue;
        uint8_t bytes[4] = {
            (uint8_t)(code & 0xFF), (uint8_t)((code >> 8) & 0xFF),
            (uint8_t)((code >> 16) & 0xFF), (uint8_t)((code >> 24) & 0xFF)
        };
        NSString *rep = [[NSString alloc] initWithBytes:bytes
                                                 length:4
                                               encoding:NSUTF32LittleEndianStringEncoding];
        if (rep) [s replaceCharactersInRange:m.range withString:rep];
    }
    return s;
}

@end

// ============================================================
//  MTBook
// ============================================================

@interface MTBook ()
+ (BOOL)loadEPUB:(MTBook *)book error:(NSError **)error;
+ (BOOL)loadTXT:(MTBook *)book error:(NSError **)error;
+ (NSArray<MTChapter *> *)splitTXT:(NSString *)text;
+ (NSArray<NSValue *> *)chapterHeadingsIn:(NSString *)text;
+ (NSString *)chapterTitleFromHTML:(NSString *)html fallback:(NSString *)fb;
+ (NSString *)attr:(NSString *)name in:(NSString *)tag;
+ (NSString *)firstGroupIn:(NSString *)text pattern:(NSString *)pattern;
+ (NSString *)normalizePath:(NSString *)path relativeTo:(NSString *)base;
@end

@implementation MTBook

+ (instancetype)bookAtPath:(NSString *)path error:(NSError **)error {
    NSString *ext = path.pathExtension.lowercaseString;
    MTBook *book = [MTBook new];
    book.path = path;
    book.title = [path.lastPathComponent stringByDeletingPathExtension];

    if ([ext isEqualToString:@"epub"]) {
        book.format = MTBookFormatEPUB;
        if (![self loadEPUB:book error:error]) return nil;
    } else {
        book.format = [ext isEqualToString:@"md"] ? MTBookFormatMarkdown : MTBookFormatTXT;
        if (![self loadTXT:book error:error]) return nil;
    }
    return book;
}

// ---------------- EPUB ----------------

+ (BOOL)loadEPUB:(MTBook *)book error:(NSError **)error {
    MTZipReader *zip = [[MTZipReader alloc] initWithPath:book.path];
    if (!zip) {
        if (error) *error = [NSError errorWithDomain:@"MTBook" code:1
                    userInfo:@{NSLocalizedDescriptionKey: @"不是有效的 EPUB（ZIP 解析失败）"}];
        return NO;
    }

    // 1. container.xml 找 .opf
    NSString *container = [zip stringForName:@"META-INF/container.xml"];
    NSString *opfPath = nil;
    if (container) {
        NSRegularExpression *re = [NSRegularExpression
            regularExpressionWithPattern:@"full-path\\s*=\\s*\"([^\"]+)\"" options:0 error:NULL];
        NSTextCheckingResult *m = [re firstMatchInString:container options:0
                                                   range:NSMakeRange(0, container.length)];
        if (m) opfPath = [container substringWithRange:[m rangeAtIndex:1]];
    }
    if (!opfPath) {
        // 兜底：直接找根目录下的 .opf
        for (MTZipEntry *e in zip.entries) {
            if ([e.name.lowercaseString hasSuffix:@".opf"]) { opfPath = e.name; break; }
        }
    }
    if (!opfPath) {
        if (error) *error = [NSError errorWithDomain:@"MTBook" code:2
                    userInfo:@{NSLocalizedDescriptionKey: @"EPUB 缺少 .opf 文件"}];
        return NO;
    }

    NSString *opf = [zip stringForName:opfPath];
    if (!opf) {
        if (error) *error = [NSError errorWithDomain:@"MTBook" code:3
                    userInfo:@{NSLocalizedDescriptionKey: @"无法读取 .opf"}];
        return NO;
    }
    NSString *opfDir = [opfPath stringByDeletingLastPathComponent];

    // 2. 元数据
    NSString *t = [self firstGroupIn:opf pattern:@"<dc:title[^>]*>(.*?)</dc:title>"];
    if (t.length) book.title = [MTTextUtil plainTextFromHTML:t];
    NSString *a = [self firstGroupIn:opf pattern:@"<dc:creator[^>]*>(.*?)</dc:creator>"];
    if (a.length) book.author = [MTTextUtil plainTextFromHTML:a];

    // 3. manifest: id → href
    NSMutableDictionary *manifest = [NSMutableDictionary dictionary];
    NSRegularExpression *itemRe = [NSRegularExpression
        regularExpressionWithPattern:@"<item\\b[^>]*>" options:0 error:NULL];
    for (NSTextCheckingResult *m in [itemRe matchesInString:opf options:0
                                                      range:NSMakeRange(0, opf.length)]) {
        NSString *tag = [opf substringWithRange:m.range];
        NSString *mid  = [self attr:@"id"   in:tag];
        NSString *href = [self attr:@"href" in:tag];
        if (mid && href) manifest[mid] = href;
    }

    // 4. spine: 阅读顺序
    NSMutableArray *order = [NSMutableArray array];
    NSRegularExpression *refRe = [NSRegularExpression
        regularExpressionWithPattern:@"<itemref\\b[^>]*>" options:0 error:NULL];
    for (NSTextCheckingResult *m in [refRe matchesInString:opf options:0
                                                     range:NSMakeRange(0, opf.length)]) {
        NSString *tag = [opf substringWithRange:m.range];
        NSString *idref = [self attr:@"idref" in:tag];
        if (idref && manifest[idref]) [order addObject:manifest[idref]];
    }
    if (order.count == 0) [order addObjectsFromArray:manifest.allValues];

    // 5. 逐章提取
    NSMutableArray *chapters = [NSMutableArray array];
    for (NSString *href in order) {
        NSString *clean = href;
        NSRange hash = [clean rangeOfString:@"#"];
        if (hash.location != NSNotFound) clean = [clean substringToIndex:hash.location];
        clean = [clean stringByRemovingPercentEncoding] ?: clean;

        NSString *full = [self normalizePath:clean relativeTo:opfDir];
        NSData *d = [zip dataForName:full];
        if (!d) continue;

        NSString *html = [MTTextUtil decodeTextData:d];
        NSString *text = [MTTextUtil plainTextFromHTML:html];
        if (text.length < 2) continue;

        MTChapter *c = [MTChapter new];
        c.text = text;
        c.title = [self chapterTitleFromHTML:html fallback:
                   [NSString stringWithFormat:@"第 %lu 节", (unsigned long)chapters.count + 1]];
        [chapters addObject:c];
    }

    if (chapters.count == 0) {
        if (error) *error = [NSError errorWithDomain:@"MTBook" code:4
                    userInfo:@{NSLocalizedDescriptionKey: @"EPUB 里没有可读内容"}];
        return NO;
    }
    book.chapters = chapters;
    return YES;
}

+ (NSString *)chapterTitleFromHTML:(NSString *)html fallback:(NSString *)fb {
    for (NSString *tag in @[@"h1", @"h2", @"h3", @"title"]) {
        NSString *v = [self firstGroupIn:html
                                 pattern:[NSString stringWithFormat:@"<%@[^>]*>(.*?)</%@>", tag, tag]];
        if (v.length) {
            NSString *clean = [MTTextUtil plainTextFromHTML:v];
            if (clean.length > 0 && clean.length <= 60) return clean;
        }
    }
    return fb;
}

/// 取标签里某个属性的值（不依赖属性顺序）
+ (NSString *)attr:(NSString *)name in:(NSString *)tag {
    NSString *pat = [NSString stringWithFormat:@"\\b%@\\s*=\\s*[\"']([^\"']*)[\"']", name];
    return [self firstGroupIn:tag pattern:pat];
}

+ (NSString *)firstGroupIn:(NSString *)text pattern:(NSString *)pattern {
    NSRegularExpression *re = [NSRegularExpression
        regularExpressionWithPattern:pattern
                             options:NSRegularExpressionDotMatchesLineSeparators | NSRegularExpressionCaseInsensitive
                               error:NULL];
    if (!re) return nil;
    NSTextCheckingResult *m = [re firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    if (!m || m.numberOfRanges < 2) return nil;
    return [text substringWithRange:[m rangeAtIndex:1]];
}

/// 处理 EPUB 内部的 ../ 相对路径
+ (NSString *)normalizePath:(NSString *)path relativeTo:(NSString *)base {
    NSString *combined = base.length ? [base stringByAppendingPathComponent:path] : path;
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *c in [combined componentsSeparatedByString:@"/"]) {
        if (c.length == 0 || [c isEqualToString:@"."]) continue;
        if ([c isEqualToString:@".."]) {
            if (parts.count) [parts removeLastObject];
            continue;
        }
        [parts addObject:c];
    }
    return [parts componentsJoinedByString:@"/"];
}

// ---------------- TXT ----------------

+ (BOOL)loadTXT:(MTBook *)book error:(NSError **)error {
    NSData *data = [NSData dataWithContentsOfFile:book.path options:NSDataReadingMappedIfSafe error:NULL];
    if (!data) {
        if (error) *error = [NSError errorWithDomain:@"MTBook" code:10
                    userInfo:@{NSLocalizedDescriptionKey: @"文件读取失败"}];
        return NO;
    }
    NSString *text = [MTTextUtil decodeTextData:data];
    if (text.length == 0) {
        if (error) *error = [NSError errorWithDomain:@"MTBook" code:11
                    userInfo:@{NSLocalizedDescriptionKey: @"文件是空的或编码无法识别"}];
        return NO;
    }

    text = [text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"];
    text = [text stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
    book.plainText = text;
    book.chapters = [self splitTXT:text];
    return YES;
}

/// 先尝试按「第 X 章」切；切不出就按字数均分
+ (NSArray<MTChapter *> *)splitTXT:(NSString *)text {
    NSArray *headings = [self chapterHeadingsIn:text];
    NSMutableArray *out = [NSMutableArray array];

    if (headings.count >= 2) {
        for (NSUInteger i = 0; i < headings.count; i++) {
            NSRange titleRange = [headings[i] rangeValue];
            NSUInteger bodyStart = NSMaxRange(titleRange);
            NSUInteger bodyEnd = (i + 1 < headings.count)
                ? [headings[i + 1] rangeValue].location : text.length;
            if (bodyEnd <= bodyStart) continue;

            NSString *title = [text substringWithRange:titleRange];
            title = [title stringByTrimmingCharactersInSet:
                     [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (title.length > 50) title = [title substringToIndex:50];

            MTChapter *c = [MTChapter new];
            c.title = title;
            c.range = NSMakeRange(bodyStart, bodyEnd - bodyStart);
            c.hasRange = YES;
            [out addObject:c];
        }
    }

    if (out.count == 0) {
        const NSUInteger chunk = 6000;
        NSUInteger pos = 0;
        NSUInteger idx = 1;
        while (pos < text.length) {
            NSUInteger len = MIN(chunk, text.length - pos);
            // 尽量在换行处断开，读起来自然
            if (pos + len < text.length) {
                NSRange win = NSMakeRange(pos + len - MIN(len, (NSUInteger)400),
                                          MIN(len, (NSUInteger)400));
                NSRange nl = [text rangeOfString:@"\n" options:NSBackwardsSearch range:win];
                if (nl.location != NSNotFound && nl.location > pos + 500) {
                    len = NSMaxRange(nl) - pos;
                }
            }
            MTChapter *c = [MTChapter new];
            c.title = [NSString stringWithFormat:@"第 %lu 部分", (unsigned long)idx++];
            c.range = NSMakeRange(pos, len);
            c.hasRange = YES;
            [out addObject:c];
            pos += len;
        }
    }
    return out;
}

/// 找出所有章节标题所在的行
+ (NSArray<NSValue *> *)chapterHeadingsIn:(NSString *)text {
    NSString *pat = @"(?m)^[ \\t\\x{3000}]*(第[0-9零一二三四五六七八九十百千万两]{1,12}[章节回卷篇][^\\n]{0,40}|"
                     "Chapter\\s+\\d{1,4}[^\\n]{0,40}|卷[0-9零一二三四五六七八九十百千万两]{1,12}[^\\n]{0,40})"
                     "[ \\t\\x{3000}]*$";
    NSRegularExpression *re = [NSRegularExpression
        regularExpressionWithPattern:pat options:0 error:NULL];
    if (!re) return @[];

    NSMutableArray *out = [NSMutableArray array];
    for (NSTextCheckingResult *m in [re matchesInString:text options:0
                                                  range:NSMakeRange(0, text.length)]) {
        [out addObject:[NSValue valueWithRange:m.range]];
    }
    return out;
}

// ---------------- 读取 ----------------

- (NSString *)textOfChapter:(NSUInteger)index {
    if (index >= self.chapters.count) return @"";
    MTChapter *c = self.chapters[index];
    if (c.text) return c.text;
    if (c.hasRange && self.plainText && NSMaxRange(c.range) <= self.plainText.length) {
        return [self.plainText substringWithRange:c.range];
    }
    return @"";
}

- (NSUInteger)totalCharacters {
    if (self.plainText) return self.plainText.length;
    NSUInteger n = 0;
    for (MTChapter *c in self.chapters) n += c.text.length;
    return n;
}

@end
