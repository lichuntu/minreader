//
//  MTZip.h —— 极简 ZIP 读取器（只读，支持 stored + deflate）
//  为什么自己写：iOS 没有公开的 zip 解压 API，而 EPUB 就是 zip。
//  解压用系统自带的 zlib（libz），不依赖任何第三方库。
//

#import <Foundation/Foundation.h>

@interface MTZipEntry : NSObject
@property (nonatomic, copy)   NSString *name;
@property (nonatomic, assign) uint16_t  method;            // 0=stored 8=deflate
@property (nonatomic, assign) uint32_t  compressedSize;
@property (nonatomic, assign) uint32_t  uncompressedSize;
@property (nonatomic, assign) uint32_t  localHeaderOffset;
@end

@interface MTZipReader : NSObject

- (instancetype)initWithPath:(NSString *)path;

@property (nonatomic, readonly) NSArray<MTZipEntry *> *entries;

/// 按名称精确查找（大小写敏感，ZIP 规范如此）
- (MTZipEntry *)entryNamed:(NSString *)name;

/// 解压出内容；失败返回 nil
- (NSData *)dataForEntry:(MTZipEntry *)entry;
- (NSData *)dataForName:(NSString *)name;

/// 按 UTF-8 解码成字符串（EPUB 内部文件都是 UTF-8）
- (NSString *)stringForName:(NSString *)name;

@end
