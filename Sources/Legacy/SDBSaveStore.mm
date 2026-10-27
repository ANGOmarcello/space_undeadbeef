// Created by Angelo Cammalleri on 27.10.2026.
#import "SDBSaveStore.h"
#import <CommonCrypto/CommonDigest.h>
#include <algorithm>
#include <cerrno>
#include <climits>
#include <cstring>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

namespace {
constexpr NSUInteger SaveBytes = 256, RecoveryLimit = 4096;
uint32_t word(NSData *data, NSUInteger offset) {
    const auto *p = static_cast<const uint8_t *>(data.bytes) + offset;
    return uint32_t(p[0]) | uint32_t(p[1]) << 8 | uint32_t(p[2]) << 16 | uint32_t(p[3]) << 24;
}
void putWord(NSMutableData *data, NSUInteger offset, uint32_t value) {
    auto *p = static_cast<uint8_t *>(data.mutableBytes) + offset;
    for (unsigned byte = 0; byte < 4; ++byte) p[byte] = uint8_t(value >> (8 * byte));
}
NSString *digest(NSData *data) {
    unsigned char bytes[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, CC_LONG(data.length), bytes);
    NSMutableString *value = [NSMutableString stringWithCapacity:64];
    for (unsigned char byte : bytes) [value appendFormat:@"%02x", byte];
    return value;
}
NSError *ioError(NSString *operation) {
    return [NSError errorWithDomain:NSPOSIXErrorDomain code:errno
        userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"%@: %s", operation, strerror(errno)]}];
}
NSData *readBounded(NSString *path, NSUInteger maximum, NSError **error) {
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    if (fd < 0) {if (errno != ENOENT) *error = ioError(@"Cannot read saved progress"); return nil;}
    struct stat info{};
    if (fstat(fd, &info) != 0 || !S_ISREG(info.st_mode) || info.st_size < 0 ||
        uint64_t(info.st_size) > maximum) {
        close(fd); errno = EINVAL; *error = ioError(@"Invalid saved progress file"); return nil;
    }
    NSMutableData *data = [NSMutableData dataWithLength:maximum + 1];
    NSUInteger length = 0;
    while (length < maximum + 1) {
        ssize_t count = read(fd, static_cast<uint8_t *>(data.mutableBytes) + length, maximum + 1 - length);
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) {*error = ioError(@"Cannot read saved progress"); close(fd); return nil;}
        if (!count) break;
        length += NSUInteger(count);
    }
    close(fd);
    if (length > maximum) {errno = EFBIG; *error = ioError(@"Saved progress exceeds its size limit"); return nil;}
    data.length = length;
    return data;
}
BOOL atomicWrite(NSData *data, NSString *path, NSError **error) {
    NSString *directory = path.stringByDeletingLastPathComponent;
    if (![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:error]) return NO;
    NSString *temporary = [directory stringByAppendingPathComponent:[@".savedata-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    int fd = open(temporary.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (fd < 0) {*error = ioError(@"Cannot prepare saved progress"); return NO;}
    NSUInteger written = 0;
    BOOL success = YES;
    while (written < data.length) {
        ssize_t count = write(fd, static_cast<const uint8_t *>(data.bytes) + written, data.length - written);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) {*error = ioError(@"Cannot write saved progress"); success = NO; break;}
        written += NSUInteger(count);
    }
    if (success && fsync(fd) != 0) {*error = ioError(@"Cannot flush saved progress"); success = NO;}
    if (close(fd) != 0 && success) {*error = ioError(@"Cannot close saved progress"); success = NO;}
    if (success && rename(temporary.fileSystemRepresentation, path.fileSystemRepresentation) != 0) {
        *error = ioError(@"Cannot replace saved progress"); success = NO;
    }
    if (!success) unlink(temporary.fileSystemRepresentation);
    return success;
}
BOOL portableFields(NSData *data) {
    if (![SDBSaveStore isValidOriginalData:data]) return NO;
    // Saved scenario cursor is zero, or the unit immediately after an original
    // checkpoint/lap opcode in stage0_scenario (0x13f7c, 87 twenty-byte units).
    constexpr uint32_t cursors[] = {0,4,8,12,17,23,27,31,36,47,52,58,62,66,70,77,85};
    const uint32_t cursor = word(data, 0x2c);
    const auto position = std::find(std::begin(cursors), std::end(cursors), cursor);
    if (position == std::end(cursors)) return NO;
    // Every checkpoint increments the counter; the lap opcode resets it.
    const uint32_t counter = cursor == 85 ? 0 : uint32_t(position - std::begin(cursors));
    if (word(data, 0x30) != counter || (cursor == 85 && word(data, 0x34) == 0)) return NO;
    return word(data, 0x20) <= INT_MAX && word(data, 0x24) <= INT_MAX &&
        word(data, 0x20) <= word(data, 0x24) && word(data, 0x28) <= INT_MAX &&
        word(data, 0x34) <= INT_MAX && word(data, 0x38) <= 12;
}
NSDictionary *record(NSData *data) {return @{ @"saveData":data, @"sha256":digest(data) };}
NSData *verifiedRecord(id value) {
    if (![value isKindOfClass:NSDictionary.class]) return nil;
    id data = value[@"saveData"], hash = value[@"sha256"];
    if (![data isKindOfClass:NSData.class] || ![SDBSaveStore isValidOriginalData:data] ||
        ![hash isKindOfClass:NSString.class] || [hash length] != 64 || ![hash isEqual:digest(data)]) return nil;
    return data;
}
}

@implementation SDBSaveStore {
    NSString *_primary, *_recovery;
    NSData *_lastGood;
    BOOL _loaded, _hasRecovery, _primaryCurrent;
}
- (instancetype)initWithDirectory:(NSString *)directory {
    if ((self = [super init])) {
        _primary = [directory stringByAppendingPathComponent:@"savedata.dat"];
        _recovery = [directory stringByAppendingPathComponent:@"savedata.recovery.plist"];
    }
    return self;
}
+ (BOOL)isValidOriginalData:(NSData *)data {
    return [data isKindOfClass:NSData.class] && data.length == SaveBytes &&
        word(data, 0) == 0x30485350 && word(data, 8) == SaveBytes;
}
- (NSData *)loadData {
    _loaded = YES; _lastError = nil; _recoveredFromBackup = NO; _primaryCurrent = NO;
    NSError *readError = nil, *metadataError = nil;
    NSData *primary = readBounded(_primary, SaveBytes, &readError);
    NSData *metadata = readBounded(_recovery, RecoveryLimit, &metadataError);
    id plist = metadata ? [NSPropertyListSerialization propertyListWithData:metadata options:NSPropertyListImmutable format:nil error:&metadataError] : nil;
    NSArray *records = [plist isKindOfClass:NSDictionary.class] && [plist[@"schema"] isEqual:@1] &&
        [plist[@"records"] isKindOfClass:NSArray.class] ? plist[@"records"] : nil;
    NSMutableArray<NSData *> *valid = [NSMutableArray array];
    if (records.count && records.count <= 2) for (id value in records) {
        NSData *data = verifiedRecord(value);
        if (data) [valid addObject:data];
    }
    _hasRecovery = valid.count != 0;
    BOOL original = [SDBSaveStore isValidOriginalData:primary];
    // Existing legacy records have no digest. Once recovery metadata exists,
    // a valid header alone no longer establishes integrity of the primary.
    if (original && ((!metadata && !metadataError) || [valid containsObject:primary])) {
        _lastGood = primary; _primaryCurrent = YES; return primary;
    }
    if (valid.count) {
        _lastGood = valid.firstObject;
        _recoveredFromBackup = YES;
        NSError *repairError = nil;
        _primaryCurrent = atomicWrite(_lastGood, _primary, &repairError);
        if (!_primaryCurrent) _lastError = repairError.localizedDescription;
        return _lastGood;
    }
    _lastGood = nil;
    if (primary || metadata || readError || metadataError)
        _lastError = (readError ?: metadataError).localizedDescription ?: @"Saved progress and its recovery records could not be validated.";
    return nil;
}
- (BOOL)writeData:(NSData *)data {
    if (![SDBSaveStore isValidOriginalData:data]) {_lastError = @"Refusing an invalid original saved-progress record."; return NO;}
    if (!_loaded) [self loadData];
    if (_hasRecovery && _primaryCurrent && [_lastGood isEqual:data]) {_lastError = nil; return YES;}
    NSMutableArray *records = [NSMutableArray arrayWithObject:record(data)];
    if (_lastGood && ![_lastGood isEqual:data]) [records addObject:record(_lastGood)];
    NSError *error = nil;
    NSData *metadata = [NSPropertyListSerialization dataWithPropertyList:@{ @"schema":@1, @"records":records }
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
    // Publish the bounded recovery transaction before replacing the primary.
    // Either old or new primary can match after an interrupted replacement.
    if (!metadata || metadata.length > RecoveryLimit || !atomicWrite(metadata, _recovery, &error) ||
        !atomicWrite(data, _primary, &error)) {
        _lastError = error.localizedDescription ?: @"Saved progress could not be written."; return NO;
    }
    _lastGood = [data copy]; _hasRecovery = _primaryCurrent = YES; _lastError = nil;
    return YES;
}
+ (NSDictionary<NSString *,id> *)portableSnapshotForData:(NSData *)data {
    if (!portableFields(data)) return nil;
    return @{ @"schema":@1, @"saveData":[data copy], @"sha256":digest(data),
        @"lap":@(word(data, 0x34)), @"checkpoint":@(word(data, 0x30)),
        @"highScore":@(word(data, 0x24)), @"currentScore":@(word(data, 0x20)) };
}
+ (NSData *)dataFromPortableSnapshot:(NSDictionary<NSString *,id> *)snapshot {
    if (![snapshot isKindOfClass:NSDictionary.class] || ![snapshot[@"schema"] isEqual:@1]) return nil;
    NSData *data = verifiedRecord(snapshot);
    return portableFields(data) ? [data copy] : nil;
}
+ (NSData *)mergeLocalData:(NSData *)local remoteData:(NSData *)remote {
    if (!portableFields(local) || !portableFields(remote)) return nil;
    NSMutableData *merged = [local mutableCopy];
    const uint32_t localLap = word(local, 0x34), remoteLap = word(remote, 0x34);
    const uint32_t localStage = word(local, 0x30), remoteStage = word(remote, 0x30);
    const BOOL farther = remoteLap > localLap || (remoteLap == localLap &&
        (remoteStage > localStage || (remoteStage == localStage && word(remote, 0x2c) > word(local, 0x2c))));
    if (farther) {
        putWord(merged, 0x20, word(remote, 0x20));
        putWord(merged, 0x28, word(remote, 0x28));
        for (NSUInteger offset = 0x2c; offset <= 0x38; offset += 4) putWord(merged, offset, word(remote, offset));
    }
    putWord(merged, 0x24, std::max(word(local, 0x24), word(remote, 0x24)));
    return merged;
}
@end

@interface SDBSaveCoordinator ()
- (instancetype)initWithStore:(SDBSaveStore *)store;
@end

@implementation SDBSaveCoordinator {
    SDBSaveStore *_store;
    dispatch_queue_t _queue;
    NSLock *_pendingLock;
    NSData *_pending;
    NSString *_cachedError;
    BOOL _draining;
}
- (instancetype)initWithDirectory:(NSString *)directory {
    return [self initWithStore:[[SDBSaveStore alloc] initWithDirectory:directory]];
}
- (instancetype)initWithStore:(SDBSaveStore *)store {
    if ((self = [super init])) {
        _store = store;
        _queue = dispatch_queue_create("dev.cammalleri.SpaceUndeadbeef.saved-progress", DISPATCH_QUEUE_SERIAL);
        _pendingLock = [NSLock new];
    }
    return self;
}
- (NSString *)lastError {
    [_pendingLock lock];
    NSString *error = _cachedError;
    [_pendingLock unlock];
    return error;
}
- (void)publishError {
    NSString *error = _store.lastError;
    [_pendingLock lock]; _cachedError = error; [_pendingLock unlock];
}
- (NSData *)loadData {
    __block NSData *data;
    dispatch_sync(_queue, ^{ data = [self->_store loadData]; [self publishError]; });
    return data;
}
- (BOOL)writeData:(NSData *)data {
    // Callers serialize guest snapshots on the main thread. Discard older
    // queued checkpoints before this authoritative original/lifecycle write.
    [_pendingLock lock]; _pending = nil; [_pendingLock unlock];
    __block BOOL written;
    dispatch_sync(_queue, ^{ written = [self->_store writeData:data]; [self publishError]; });
    return written;
}
- (void)enqueueData:(NSData *)data {
    if (![SDBSaveStore isValidOriginalData:data]) {
        [_pendingLock lock];
        _cachedError = @"Refusing an invalid original saved-progress record.";
        [_pendingLock unlock];
        return;
    }
    NSData *snapshot = [data copy];
    [_pendingLock lock];
    _pending = snapshot;
    const BOOL start = !_draining;
    _draining = YES;
    [_pendingLock unlock];
    if (!start) return;
    dispatch_async(_queue, ^{
        while (true) {
            @autoreleasepool {
                [self->_pendingLock lock];
                NSData *next = self->_pending;
                self->_pending = nil;
                if (!next) self->_draining = NO;
                [self->_pendingLock unlock];
                if (!next) return;
                [self->_store writeData:next];
                [self publishError];
            }
        }
    });
}
@end
