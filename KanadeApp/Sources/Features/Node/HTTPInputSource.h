#import <Foundation/Foundation.h>
#import <SFBAudioEngine/SFBInputSource.h>

NS_ASSUME_NONNULL_BEGIN

@interface HTTPInputSource : SFBInputSource

@property(nonatomic, readonly, copy) NSURL *url;
@property(nonatomic, readonly, copy, nullable) NSString *mimeTypeHint;

- (instancetype)initWithURL:(NSURL *)url mimeTypeHint:(nullable NSString *)mimeTypeHint NS_DESIGNATED_INITIALIZER;
- (NSString *)resolvedMimeTypeHint;

@end

NS_ASSUME_NONNULL_END
