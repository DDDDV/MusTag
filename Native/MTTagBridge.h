#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface MTTagBridge : NSObject
+ (nullable NSDictionary<NSString *, id> *)readURL:(NSURL *)url error:(NSError **)error NS_SWIFT_NAME(read(url:));
+ (BOOL)writeTags:(NSDictionary<NSString *, NSString *> *)tags toURL:(NSURL *)url error:(NSError **)error NS_SWIFT_NAME(write(tags:to:));
+ (BOOL)writeArtwork:(NSData *)data mimeType:(NSString *)mimeType toURL:(NSURL *)url error:(NSError **)error NS_SWIFT_NAME(writeArtwork(_:mimeType:to:));
+ (nullable NSArray<NSNumber *> *)mpegRangeForURL:(NSURL *)url error:(NSError **)error NS_SWIFT_NAME(mpegRange(url:));
@end
NS_ASSUME_NONNULL_END
