//
//  MTCover.m —— 书籍封面提取
//
//  封面来源，按可靠性从高到低：
//    1. EPUB manifest 里 properties="cover-image" 的图片
//    2. EPUB <meta name="cover" content="ID"/> 指向的图片
//    3. EPUB guide 里 type="cover" 指向的封面页 XHTML，再从中取图
//    4. 文件名含 cover / titlepage 的图片
//    5. EPUB 里"像素面积最大"的图片（封面通常是最大那张）
//    6. 同目录下的同名图片（book.txt + book.jpg）
//    7. 实在没有，才按书名生成一张占位封面
//

#import "MTCover.h"
#import "MTZip.h"

@implementation MTCover

// ============================================================
//  缓存
// ============================================================

+ (NSString *)cacheDir {
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *dir = [docs stringByAppendingPathComponent:@".covers"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:dir]) {
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES attributes:nil error:NULL];
    }
    return dir;
}

+ (NSString *)cachePathFor:(NSString *)path {
    NSString *name = path.lastPathComponent;
    NSMutableString *safe = [NSMutableString string];
    for (NSUInteger i = 0; i < name.length; i++) {
        unichar c = [name characterAtIndex:i];
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
            (c >= '0' && c <= '9') || c == '.' || c == '-' || c == '_') {
            [safe appendFormat:@"%C", c];
        } else {
            [safe appendFormat:@"_%x", c];
        }
    }
    if (safe.length > 120) safe = [[safe substringToIndex:120] mutableCopy];

    NSString *stem = [safe stringByAppendingString:@".png"];
    // 用文件大小+修改时间做版本，书换了封面能自动更新
    NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
    if (a) {
        stem = [NSString stringWithFormat:@"%llu_%ld_%@",
                [a[NSFileSize] unsignedLongLongValue],
                (long)[a[NSFileModificationDate] timeIntervalSince1970], stem];
    }
    return [[self cacheDir] stringByAppendingPathComponent:stem];
}

+ (UIImage *)cachedCoverForPath:(NSString *)path {
    return [UIImage imageWithContentsOfFile:[self cachePathFor:path]];
}

+ (void)storeCover:(UIImage *)img forPath:(NSString *)path {
    NSData *d = UIImagePNGRepresentation(img);
    if (d) [d writeToFile:[self cachePathFor:path] atomically:YES];
}

+ (void)clearCache {
    [[NSFileManager defaultManager] removeItemAtPath:[self cacheDir] error:NULL];
}

// ============================================================
//  对外
// ============================================================

+ (UIImage *)coverForPath:(NSString *)path {
    if (path.length == 0) return nil;
    UIImage *cached = [self cachedCoverForPath:path];
    if (cached) return cached;

    UIImage *img = nil;
    NSString *ext = path.pathExtension.lowercaseString;

    if ([ext isEqualToString:@"epub"]) {
        img = [self epubCoverAtPath:path];
    }
    if (!img) img = [self sidecarCoverForPath:path];     // 同名图片
    BOOL real = (img != nil);
    if (!img) img = [self generatedCoverForPath:path];   // 占位

    // 占位封面不写盘，这样以后补上真封面能生效
    if (img && real) [self storeCover:img forPath:path];
    return img;
}

+ (void)prewarmCovers:(NSArray<NSString *> *)paths {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        for (NSString *p in paths) {
            if ([self cachedCoverForPath:p]) continue;
            @autoreleasepool { [self coverForPath:p]; }
        }
    });
}

// ============================================================
//  EPUB 封面提取
// ============================================================

+ (UIImage *)epubCoverAtPath:(NSString *)path {
    MTZipReader *zip = [[MTZipReader alloc] initWithPath:path];
    if (!zip) return nil;

    // ---- 定位 .opf ----
    NSString *opfPath = nil;
    NSString *container = [zip stringForName:@"META-INF/container.xml"];
    if (container) opfPath = [self group:1 of:@"full-path\\s*=\\s*\"([^\"]+)\"" in:container];
    if (!opfPath) {
        for (MTZipEntry *e in zip.entries) {
            if ([e.name.lowercaseString hasSuffix:@".opf"]) { opfPath = e.name; break; }
        }
    }
    if (!opfPath) return nil;
    NSString *opf = [zip stringForName:opfPath];
    if (!opf) return nil;
    NSString *base = [opfPath stringByDeletingLastPathComponent];

    // ---- 解析 manifest ----
    NSMutableDictionary *hrefOf = [NSMutableDictionary dictionary];
    NSMutableArray *imageHrefs = [NSMutableArray array];
    NSString *coverIdFromProp = nil;      // properties="cover-image"
    NSString *coverIdFromMeta = nil;      // <meta name="cover" content="ID">

    NSRegularExpression *itemRe = [NSRegularExpression regularExpressionWithPattern:@"<item\\b[^>]*/?>"
                                                                           options:0 error:NULL];
    for (NSTextCheckingResult *m in [itemRe matchesInString:opf options:0
                                                      range:NSMakeRange(0, opf.length)]) {
        NSString *tag = [opf substringWithRange:m.range];
        NSString *iid = [self attr:@"id" in:tag];
        NSString *href = [self attr:@"href" in:tag];
        NSString *type = [self attr:@"media-type" in:tag].lowercaseString;
        NSString *props = [self attr:@"properties" in:tag].lowercaseString;
        if (!iid) continue;
        if (href) hrefOf[iid] = href;
        if (href && [type hasPrefix:@"image/"]) [imageHrefs addObject:href];
        if ([props containsString:@"cover-image"]) coverIdFromProp = iid;
    }

    NSRegularExpression *metaRe = [NSRegularExpression
        regularExpressionWithPattern:@"<meta[^>]*name\\s*=\\s*[\"']cover[\"'][^>]*/?>"
                             options:NSRegularExpressionCaseInsensitive error:NULL];
    for (NSTextCheckingResult *m in [metaRe matchesInString:opf options:0
                                                      range:NSMakeRange(0, opf.length)]) {
        NSString *tag = [opf substringWithRange:m.range];
        NSString *cid = [self attr:@"content" in:tag];
        if (cid.length) { coverIdFromMeta = cid; break; }
    }

    // ---- 1 & 2：按 id 直接取 ----
    NSString *href = nil;
    if (coverIdFromProp && hrefOf[coverIdFromProp]) href = hrefOf[coverIdFromProp];
    if (!href && coverIdFromMeta && hrefOf[coverIdFromMeta]) href = hrefOf[coverIdFromMeta];

    // ---- 3：guide 的 cover 引用 → 封面页 XHTML → 里面的图 ----
    if (!href) {
        NSString *guideTag = [self group:0 of:@"<reference[^>]*type\\s*=\\s*[\"']cover[\"'][^>]*/?>"
                                          in:opf];
        if (guideTag) {
            NSString *pageHref = [self attr:@"href" in:guideTag];
            if (pageHref.length) {
                NSString *pagePath = [self normalize:pageHref relativeTo:base];
                NSString *page = [zip stringForName:pagePath];
                if (page) {
                    NSString *imgSrc = [self imageSourceIn:page];
                    if (imgSrc.length) {
                        // 相对封面页自己的目录
                        href = imgSrc;
                        base = [pagePath stringByDeletingLastPathComponent];
                    }
                }
            }
        }
    }

    // ---- 3b：spine 第一页（很多书封面就是第一页）----
    if (!href) {
        NSString *imgSrc = nil;
        NSArray *spineItems = [self spineItemsIn:opf manifest:hrefOf];
        for (NSString *itemId in spineItems) {
            NSString *itemHref = hrefOf[itemId];
            if (!itemHref) continue;
            NSString *pagePath = [self normalize:itemHref relativeTo:base];
            NSString *page = [zip stringForName:pagePath];
            if (!page) continue;
            imgSrc = [self imageSourceIn:page];
            if (imgSrc.length) {
                base = [pagePath stringByDeletingLastPathComponent];
                break;
            }
        }
        if (imgSrc.length) href = imgSrc;
    }

    // ---- 4：文件名带 cover / titlepage ----
    if (!href) {
        for (NSString *h in imageHrefs) {
            NSString *low = h.lowercaseString;
            if ([low containsString:@"cover"] || [low containsString:@"titlepage"] ||
                [low containsString:@"title-page"]) { href = h; break; }
        }
    }

    // ---- 从 href 取图 ----
    if (href) {
        UIImage *img = [self imageInZip:zip href:href base:base minWidth:0];
        if (img) return img;
    }

    // ---- 5：兜底 —— 挑像素面积最大的图（封面通常是最大的）----
    UIImage *best = nil;
    CGFloat bestArea = 0;
    NSUInteger tried = 0;
    for (NSString *h in imageHrefs) {
        if (tried++ > 30) break;                       // 别太慢
        UIImage *img = [self imageInZip:zip href:h base:base minWidth:0];
        if (!img) continue;
        CGFloat area = img.size.width * img.size.height;
        if (area > bestArea) { bestArea = area; best = img; }
    }
    if (best) return best;
    return nil;
}

/// 从 xhtml 里找图片地址（同时支持 <img src> 和 <svg><image xlink:href>）
+ (NSString *)imageSourceIn:(NSString *)page {
    if (page.length == 0) return nil;
    NSString *s = [self group:1 of:@"<img[^>]*\\bsrc\\s*=\\s*[\"']([^\"']+)[\"']" in:page];
    if (s.length) return s;
    s = [self group:1 of:@"<image[^>]*(?:xlink:)?href\\s*=\\s*[\"']([^\"']+)[\"']" in:page];
    if (s.length) return s;
    // CSS background-image
    s = [self group:1 of:@"url\\(\\s*[\"']?([^\"')]+)[\"']?\\s*\\)" in:page];
    return s.length ? s : nil;
}

+ (NSArray<NSString *> *)spineItemsIn:(NSString *)opf manifest:(NSDictionary *)hrefOf {
    NSMutableArray *out = [NSMutableArray array];
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"<itemref\\b[^>]*/?>"
                                                                       options:0 error:NULL];
    for (NSTextCheckingResult *m in [re matchesInString:opf options:0
                                                  range:NSMakeRange(0, opf.length)]) {
        NSString *tag = [opf substringWithRange:m.range];
        NSString *idref = [self attr:@"idref" in:tag];
        if (idref.length && hrefOf[idref]) [out addObject:idref];
    }
    return out;
}

+ (UIImage *)imageInZip:(MTZipReader *)zip href:(NSString *)href base:(NSString *)base minWidth:(CGFloat)minW {
    if (href.length == 0) return nil;
    NSString *clean = href;
    NSRange hash = [clean rangeOfString:@"#"];
    if (hash.location != NSNotFound) clean = [clean substringToIndex:hash.location];
    if (clean.length == 0) return nil;

    NSString *full = [self normalize:clean relativeTo:base];
    NSData *d = [zip dataForName:full];
    if (!d) {
        // 有些书 href 已经是全路径，或大小写不一致 → 遍历找一次
        for (MTZipEntry *e in zip.entries) {
            if ([e.name caseInsensitiveCompare:full] == NSOrderedSame) {
                d = [zip dataForEntry:e];
                break;
            }
        }
    }
    if (!d || d.length < 32) return nil;
    UIImage *img = [UIImage imageWithData:d];
    if (img && minW > 0 && img.size.width < minW) return nil;
    return img;
}

// ============================================================
//  同目录同名图片（TXT 常见的配图方式）
// ============================================================

+ (UIImage *)sidecarCoverForPath:(NSString *)path {
    NSString *dir = [path stringByDeletingLastPathComponent];
    NSString *stem = [path.lastPathComponent stringByDeletingPathExtension];
    for (NSString *ext in @[@"jpg", @"jpeg", @"png", @"webp", @"JPG", @"PNG"]) {
        NSString *p = [[dir stringByAppendingPathComponent:stem]
                       stringByAppendingPathExtension:ext];
        UIImage *img = [UIImage imageWithContentsOfFile:p];
        if (img) return img;
    }
    // cover.* 也认
    for (NSString *ext in @[@"jpg", @"jpeg", @"png"]) {
        NSString *p = [[dir stringByAppendingPathComponent:@"cover"]
                       stringByAppendingPathExtension:ext];
        UIImage *img = [UIImage imageWithContentsOfFile:p];
        if (img) return img;
    }
    return nil;
}

// ============================================================
//  正则小工具
// ============================================================

+ (NSString *)attr:(NSString *)name in:(NSString *)tag {
    return [self group:1 of:[NSString stringWithFormat:@"\\b%@\\s*=\\s*[\"']([^\"']*)[\"']", name]
                    in:tag];
}

/// group 0 = 整个匹配
+ (NSString *)group:(NSInteger)idx of:(NSString *)pattern in:(NSString *)text {
    if (text.length == 0) return nil;
    NSRegularExpression *re = [NSRegularExpression
        regularExpressionWithPattern:pattern
                             options:NSRegularExpressionDotMatchesLineSeparators | NSRegularExpressionCaseInsensitive
                               error:NULL];
    if (!re) return nil;
    NSTextCheckingResult *m = [re firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    if (!m || idx >= (NSInteger)m.numberOfRanges) return nil;
    NSRange r = [m rangeAtIndex:idx];
    if (r.location == NSNotFound) return nil;
    return [text substringWithRange:r];
}

+ (NSString *)normalize:(NSString *)path relativeTo:(NSString *)base {
    NSString *decoded = path;
    if ([path containsString:@"%"]) {
        NSString *d = [path stringByRemovingPercentEncoding];
        if (d) decoded = d;
    }
    NSString *combined = base.length ? [base stringByAppendingPathComponent:decoded] : decoded;
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

// ============================================================
//  占位封面
// ============================================================

+ (UIImage *)generatedCoverForPath:(NSString *)path {
    NSString *name = [path.lastPathComponent stringByDeletingPathExtension];
    if (name.length == 0) name = @"未命名";

    CGSize size = CGSizeMake(600, 800);
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.opaque = YES;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:size format:fmt];

    NSUInteger h = 0;
    for (NSUInteger i = 0; i < name.length; i++) h = h * 31 + [name characterAtIndex:i];
    NSArray *palette = @[
        @[@0.20, @0.32, @0.62], @[@0.55, @0.22, @0.30], @[@0.16, @0.45, @0.40],
        @[@0.42, @0.26, @0.55], @[@0.62, @0.40, @0.16], @[@0.18, @0.38, @0.55],
        @[@0.48, @0.20, @0.45], @[@0.22, @0.44, @0.28],
    ];
    NSArray *rgb = palette[h % palette.count];
    UIColor *c1 = [UIColor colorWithRed:[rgb[0] doubleValue] green:[rgb[1] doubleValue]
                                  blue:[rgb[2] doubleValue] alpha:1];
    UIColor *c2 = [UIColor colorWithRed:[rgb[0] doubleValue] * 0.55
                                  green:[rgb[1] doubleValue] * 0.55
                                   blue:[rgb[2] doubleValue] * 0.55 alpha:1];

    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef g = ctx.CGContext;
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        NSArray *colors = @[(__bridge id)c1.CGColor, (__bridge id)c2.CGColor];
        CGGradientRef grad = CGGradientCreateWithColors(space, (__bridge CFArrayRef)colors, NULL);
        CGContextDrawLinearGradient(g, grad, CGPointZero,
                                    CGPointMake(size.width, size.height), 0);
        CGGradientRelease(grad);
        CGColorSpaceRelease(space);

        CGContextSetFillColorWithColor(g, [[UIColor colorWithWhite:0 alpha:0.20] CGColor]);
        CGContextFillRect(g, CGRectMake(0, 0, size.width * 0.055, size.height));
        CGContextSetFillColorWithColor(g, [[UIColor colorWithWhite:1 alpha:0.16] CGColor]);
        CGContextFillRect(g, CGRectMake(size.width * 0.055, 0, 3, size.height));

        NSMutableParagraphStyle *ps = [NSMutableParagraphStyle defaultParagraphStyle].mutableCopy;
        ps.alignment = NSTextAlignmentCenter;
        UIFont *font = [UIFont boldSystemFontOfSize:56];
        if (name.length > 10) font = [UIFont boldSystemFontOfSize:46];
        if (name.length > 16) font = [UIFont boldSystemFontOfSize:38];
        if (name.length > 24) font = [UIFont boldSystemFontOfSize:32];
        [name drawWithRect:CGRectMake(size.width * 0.12, size.height * 0.24,
                                      size.width * 0.76, size.height * 0.52)
                   options:NSStringDrawingUsesLineFragmentOrigin
                attributes:@{NSFontAttributeName: font,
                             NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.96],
                             NSParagraphStyleAttributeName: ps}
                   context:nil];

        [path.pathExtension.uppercaseString
            drawWithRect:CGRectMake(0, size.height * 0.80, size.width, 40)
                 options:NSStringDrawingUsesLineFragmentOrigin
              attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:24 weight:UIFontWeightMedium],
                           NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.62],
                           NSParagraphStyleAttributeName: ps}
                 context:nil];
    }];
}

@end
