// Created by Angelo Cammalleri on 25.10.2026.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN
/// Executes the supplied, hash-checked 2008 gameplay code in bounded guest memory.
@interface SDBEngine : NSObject
- (instancetype)initWithResourcePath:(NSString *)path;
@property(nonatomic, readonly, nullable) CGImageRef frame;
@property(nonatomic, readonly, nullable) NSString *failure;
@property(nonatomic, readonly) NSString *diagnostics;
@property(nonatomic) BOOL soundEnabled;
@property(nonatomic) BOOL respectsSilentMode;
- (void)update:(double)delta;
- (void)touchPhase:(NSInteger)phase x:(double)x y:(double)y;
- (void)setSuspended:(BOOL)suspended;
@end
NS_ASSUME_NONNULL_END
