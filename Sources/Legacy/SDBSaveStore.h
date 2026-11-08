// Created by Angelo Cammalleri on 27.10.2026.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Bounded persistence for the untouched original 256-byte SaveData record.
/// Recovery holds two individually checksummed records. tvOS can use a bounded
/// preferences record because Application Support is not writable there.
@interface SDBSaveStore : NSObject
- (instancetype)initWithDirectory:(NSString *)directory;
- (instancetype)initWithPreferences:(NSUserDefaults *)preferences legacyDirectory:(nullable NSString *)directory;
@property(nonatomic, readonly, nullable) NSString *lastError;
@property(nonatomic, readonly) BOOL recoveredFromBackup;
- (nullable NSData *)loadData;
- (BOOL)writeData:(NSData *)data;
/// Exactly the checks in original SaveData::load (0xe788): length, PSH0, size.
+ (BOOL)isValidOriginalData:(NSData *)data;
+ (nullable NSDictionary<NSString *, id> *)portableSnapshotForData:(NSData *)data NS_SWIFT_NAME(portableSnapshot(_:));
+ (nullable NSData *)dataFromPortableSnapshot:(NSDictionary<NSString *, id> *)snapshot;
/// Files exchange only the known progression fields, with all local bytes cleared.
+ (nullable NSDictionary<NSString *, id> *)sharedProgressSnapshot:(NSDictionary<NSString *, id> *)snapshot
    NS_SWIFT_NAME(sharedProgress(_:));
+ (nullable NSDictionary<NSString *, id> *)mergeProgressSnapshot:(NSDictionary<NSString *, id> *)local
    remote:(NSDictionary<NSString *, id> *)remote NS_SWIFT_NAME(mergeSnapshots(_:remote:));
/// Furthest verified checkpoint wins; high score never decreases. Local audio,
/// game speed and unknown bytes survive. Returns nil for unsafe portable data.
+ (nullable NSData *)mergeLocalData:(NSData *)local remoteData:(NSData *)remote;
@end

/// Serial disk ownership with a bounded periodic checkpoint backlog. Explicit
/// original/lifecycle writes complete before returning; periodic writes retain
/// at most one in-flight record and the latest pending record.
@interface SDBSaveCoordinator : NSObject
- (instancetype)initWithDirectory:(NSString *)directory;
- (instancetype)initWithPreferences:(NSUserDefaults *)preferences legacyDirectory:(nullable NSString *)directory;
@property(nonatomic, readonly, nullable) NSString *lastError;
- (nullable NSData *)loadData;
- (BOOL)writeData:(NSData *)data;
- (void)enqueueData:(NSData *)data;
@end
NS_ASSUME_NONNULL_END
