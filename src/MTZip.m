//
//  MTZip.m
//

#import "MTZip.h"
#include <zlib.h>

@implementation MTZipEntry
@end

// ---------- 小端读取 ----------
static inline uint16_t MT_rd16(const uint8_t *p) {
    return (uint16_t)(p[0] | (p[1] << 8));
}
static inline uint32_t MT_rd32(const uint8_t *p) {
    return (uint32_t)(p[0] | (p[1] << 8) | (p[2] << 16) | ((uint32_t)p[3] << 24));
}

@implementation MTZipReader {
    NSData *_raw;
    NSArray<MTZipEntry *> *_entries;
}

- (instancetype)initWithPath:(NSString *)path {
    self = [super init];
    if (!self) return nil;
    _raw = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:NULL];
    if (!_raw || _raw.length < 22) return nil;
    if (![self parseCentralDirectory]) return nil;
    return self;
}

- (NSArray<MTZipEntry *> *)entries { return _entries; }

// 从尾部往前找 EOCD（End of Central Directory）签名 0x06054b50
- (BOOL)parseCentralDirectory {
    const uint8_t *bytes = _raw.bytes;
    NSUInteger len = _raw.length;

    NSUInteger scanLen = MIN(len, (NSUInteger)65557);   // 22 + 最大注释 65535
    NSInteger eocd = -1;
    for (NSInteger i = (NSInteger)len - 22; i >= (NSInteger)(len - scanLen); i--) {
        if (i < 0) break;
        if (MT_rd32(bytes + i) == 0x06054b50) { eocd = i; break; }
    }
    if (eocd < 0) return NO;

    uint16_t count = MT_rd16(bytes + eocd + 10);
    uint32_t cdOffset = MT_rd32(bytes + eocd + 16);
    if (cdOffset >= len) return NO;

    NSMutableArray *list = [NSMutableArray arrayWithCapacity:count];
    NSUInteger p = cdOffset;
    for (uint16_t i = 0; i < count; i++) {
        if (p + 46 > len) break;
        if (MT_rd32(bytes + p) != 0x02014b50) break;

        uint16_t method   = MT_rd16(bytes + p + 10);
        uint32_t csize    = MT_rd32(bytes + p + 20);
        uint32_t usize    = MT_rd32(bytes + p + 24);
        uint16_t nameLen  = MT_rd16(bytes + p + 28);
        uint16_t extraLen = MT_rd16(bytes + p + 30);
        uint16_t cmtLen   = MT_rd16(bytes + p + 32);
        uint32_t lho      = MT_rd32(bytes + p + 42);

        if (p + 46 + nameLen > len) break;
        NSString *name = [[NSString alloc] initWithBytes:bytes + p + 46
                                                  length:nameLen
                                                encoding:NSUTF8StringEncoding];
        if (!name) {
            name = [[NSString alloc] initWithBytes:bytes + p + 46
                                            length:nameLen
                                          encoding:NSISOLatin1StringEncoding];
        }
        if (name.length) {
            MTZipEntry *e = [MTZipEntry new];
            e.name = name;
            e.method = method;
            e.compressedSize = csize;
            e.uncompressedSize = usize;
            e.localHeaderOffset = lho;
            [list addObject:e];
        }
        p += 46 + nameLen + extraLen + cmtLen;
    }

    _entries = list;
    return list.count > 0;
}

- (MTZipEntry *)entryNamed:(NSString *)name {
    for (MTZipEntry *e in _entries) {
        if ([e.name isEqualToString:name]) return e;
    }
    return nil;
}

- (NSData *)dataForName:(NSString *)name {
    MTZipEntry *e = [self entryNamed:name];
    return e ? [self dataForEntry:e] : nil;
}

- (NSString *)stringForName:(NSString *)name {
    NSData *d = [self dataForName:name];
    if (!d) return nil;
    NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    if (s) return s;
    s = [[NSString alloc] initWithData:d encoding:NSISOLatin1StringEncoding];
    return s;
}

- (NSData *)dataForEntry:(MTZipEntry *)entry {
    const uint8_t *bytes = _raw.bytes;
    NSUInteger len = _raw.length;
    NSUInteger lo = entry.localHeaderOffset;

    // 本地文件头：文件名/扩展区长度可能和中央目录不同，必须重读
    if (lo + 30 > len) return nil;
    if (MT_rd32(bytes + lo) != 0x04034b50) return nil;
    uint16_t nameLen  = MT_rd16(bytes + lo + 26);
    uint16_t extraLen = MT_rd16(bytes + lo + 28);

    NSUInteger dataStart = lo + 30 + nameLen + extraLen;
    if (dataStart > len) return nil;

    NSUInteger csize = entry.compressedSize;
    if (dataStart + csize > len) {
        csize = len - dataStart;          // 声明值不可信时按剩余长度取
    }

    if (entry.method == 0) {
        // 未压缩
        return [NSData dataWithBytes:bytes + dataStart length:csize];
    }

    if (entry.method != 8) return nil;    // 只支持 deflate

    // ---- raw deflate 解压（windowBits = -15）----
    NSUInteger expect = entry.uncompressedSize;
    if (expect == 0) expect = csize * 8 + 1024;   // 未知时给个保守上限

    NSMutableData *out = [NSMutableData dataWithLength:expect];
    z_stream strm;
    memset(&strm, 0, sizeof(strm));
    if (inflateInit2(&strm, -15) != Z_OK) return nil;

    strm.next_in  = (Bytef *)(bytes + dataStart);
    strm.avail_in = (uInt)csize;
    strm.next_out = (Bytef *)out.mutableBytes;
    strm.avail_out = (uInt)expect;

    int rc = inflate(&strm, Z_FINISH);
    NSUInteger produced = expect - strm.avail_out;
    inflateEnd(&strm);

    if (rc != Z_STREAM_END && produced == 0) return nil;
    out.length = produced;
    return out;
}

@end
