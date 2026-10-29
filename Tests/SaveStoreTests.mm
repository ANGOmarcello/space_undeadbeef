// Created by Angelo Cammalleri on 27.10.2026.
#import "SDBSaveStore.h"
#include "GuestCPU.h"
#include <cstdio>
#include <cstring>
#include <initializer_list>
#include <sys/stat.h>
#include <unistd.h>

namespace {
unsigned checks = 0;
bool require(bool value, const char *message) {
    ++checks; if (!value) fprintf(stderr, "FAIL %s\n", message); return value;
}
void put(NSMutableData *data, NSUInteger offset, uint32_t value) {
    auto *bytes = static_cast<uint8_t *>(data.mutableBytes) + offset;
    for (unsigned index = 0; index < 4; ++index) bytes[index] = uint8_t(value >> (8 * index));
}
NSMutableData *fixture(unsigned checkpoint = 0, unsigned cursor = 0, unsigned high = 100) {
    NSMutableData *data = [NSMutableData dataWithLength:256];
    put(data, 0, 0x30485350); put(data, 8, 256); put(data, 0x10, 0x3c888889);
    put(data, 0x14, 1); put(data, 0x20, 25); put(data, 0x24, high);
    put(data, 0x2c, cursor); put(data, 0x30, checkpoint); put(data, 0x38, 12);
    return data;
}
NSDictionary *metadata(NSString *path) {return [NSDictionary dictionaryWithContentsOfFile:path];}
ino_t inode(NSString *path) {struct stat status{}; return stat(path.fileSystemRepresentation, &status) == 0 ? status.st_ino : 0;}
bool originalValidator(NSData *binary, NSData *data) {
    GuestCPU cpu;
    const auto u32 = [&](NSUInteger offset) {uint32_t value; memcpy(&value, static_cast<const uint8_t *>(binary.bytes) + offset, 4); return value;};
    NSUInteger command = 28;
    for (unsigned index = 0; index < u32(16); ++index) {
        if (u32(command) == 1) {
            uint32_t address = u32(command + 24), file = u32(command + 32), length = u32(command + 36);
            if (uint64_t(file) + length > binary.length) return false;
            cpu.load(address, static_cast<const uint8_t *>(binary.bytes) + file, length);
        }
        command += u32(command + 4);
    }
    cpu.hook = [&](GuestCPU& guest, uint32_t pc) {
        if (pc == 0xa8a0) {
            guest.load(0x100000, data.bytes, data.length);
            guest.write32(guest.r[1], uint32_t(data.length)); guest.r[0] = 0x100000;
        } else if (pc == 0xa958) guest.r[0] = 0;
        else if (pc == 0xf3e8) {
            guest.load(guest.r[0], guest.memory.data() + guest.r[1], guest.r[2]);
        } else return false;
        guest.returnFromHook(); return true;
    };
    bool result = cpu.call(0xe789, {0x200000}) != 0;
    if (!cpu.fault.empty()) fprintf(stderr, "Original loader fault: %s\n", cpu.fault.c_str());
    return require(cpu.fault.empty(), "original SaveData::load executes without a fault") &&
        require(result == bool([SDBSaveStore isValidOriginalData:data]), "host validation matches actual original loader");
}
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 3) return 64;
        NSString *root = [NSString stringWithUTF8String:argv[1]];
        NSString *primary = [root stringByAppendingPathComponent:@"savedata.dat"];
        NSString *recovery = [root stringByAppendingPathComponent:@"savedata.recovery.plist"];
        NSData *first = fixture(), *second = fixture(1, 4, 250);
        NSData *binary = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[2]]];
        if (!require(binary.length == 179136, "authoritative original executable loaded") ||
            !originalValidator(binary, first) ||
            !originalValidator(binary, [first subdataWithRange:NSMakeRange(0, 255)])) return 1;
        NSMutableData *badMagic = [first mutableCopy]; put(badMagic, 0, 0);
        NSMutableData *badSize = [first mutableCopy]; put(badSize, 8, 255);
        NSMutableData *unknownBytes = [first mutableCopy]; static_cast<uint8_t *>(unknownBytes.mutableBytes)[200] = 99;
        if (!originalValidator(binary, badMagic) || !originalValidator(binary, badSize) || !originalValidator(binary, unknownBytes)) return 1;
        SDBSaveStore *store = [[SDBSaveStore alloc] initWithDirectory:root];
        if (!require([store loadData] == nil && store.lastError == nil, "fresh installation has no error") ||
            !require([SDBSaveStore isValidOriginalData:first], "original valid header accepted") ||
            !require(![SDBSaveStore isValidOriginalData:[first subdataWithRange:NSMakeRange(0, 255)]], "truncation rejected") ||
            !require([store writeData:first], "initial bounded atomic save") ||
            !require([[NSData dataWithContentsOfFile:primary] isEqual:first], "original primary bytes retained") ||
            !require([[metadata(recovery) objectForKey:@"records"] count] == 1, "first recovery record exists")) return 1;
        const ino_t originalInode = inode(primary), recoveryInode = inode(recovery);
        if (!require([store writeData:first] && inode(primary) == originalInode && inode(recovery) == recoveryInode,
                     "unchanged save does not replace either file") ||
            !require([store writeData:second], "changed save commits") ||
            !require([[metadata(recovery) objectForKey:@"records"] count] == 2, "previous valid checkpoint retained")) return 1;
        [[second subdataWithRange:NSMakeRange(0, 32)] writeToFile:primary atomically:YES];
        store = [[SDBSaveStore alloc] initWithDirectory:root];
        if (!require([[store loadData] isEqual:second] && store.recoveredFromBackup, "truncated primary recovered") ||
            !require([[NSData dataWithContentsOfFile:primary] isEqual:second], "recovery repairs primary atomically")) return 1;
        NSMutableData *changedUnknown = [second mutableCopy];
        static_cast<uint8_t *>(changedUnknown.mutableBytes)[200] ^= 1;
        [changedUnknown writeToFile:primary atomically:YES];
        store = [[SDBSaveStore alloc] initWithDirectory:root];
        if (!require([[store loadData] isEqual:second] && store.recoveredFromBackup,
                     "valid header with payload corruption rejected using digest")) return 1;
        NSMutableDictionary *damaged = [metadata(recovery) mutableCopy];
        NSMutableArray *records = [damaged[@"records"] mutableCopy];
        NSMutableDictionary *bad = [records[0] mutableCopy]; bad[@"saveData"] = changedUnknown; records[0] = bad;
        damaged[@"records"] = records; [damaged writeToFile:recovery atomically:YES];
        [NSFileManager.defaultManager removeItemAtPath:primary error:nil];
        store = [[SDBSaveStore alloc] initWithDirectory:root];
        if (!require([[store loadData] isEqual:first], "damaged latest recovery falls back to previous digest")) return 1;
        [@{@"schema":@99, @"records":@[]} writeToFile:recovery atomically:YES];
        store = [[SDBSaveStore alloc] initWithDirectory:root];
        if (!require([store loadData] == nil && store.lastError.length > 0, "unknown recovery schema rejected") ||
            !require([[NSData dataWithContentsOfFile:primary] isEqual:first], "failed read leaves existing bytes untouched")) return 1;
        NSString *legacy = [root stringByAppendingPathComponent:@"legacy"];
        [NSFileManager.defaultManager createDirectoryAtPath:legacy withIntermediateDirectories:YES attributes:nil error:nil];
        [first writeToFile:[legacy stringByAppendingPathComponent:@"savedata.dat"] atomically:YES];
        SDBSaveStore *legacyStore = [[SDBSaveStore alloc] initWithDirectory:legacy];
        if (!require([[legacyStore loadData] isEqual:first], "legacy record loads through original validation") ||
            !require([legacyStore writeData:first], "unchanged legacy record gains integrity protection once")) return 1;
        NSString *blocked = [root stringByAppendingPathComponent:@"blocked"];
        [first writeToFile:blocked atomically:YES];
        SDBSaveStore *blockedStore = [[SDBSaveStore alloc] initWithDirectory:blocked];
        if (!require(![blockedStore writeData:first] && blockedStore.lastError.length > 0,
                     "write failure is reported without a fatal guest fault")) return 1;
        NSString *limited = [root stringByAppendingPathComponent:@"limited"];
        [NSFileManager.defaultManager createDirectoryAtPath:limited withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *limitedPrimary = [limited stringByAppendingPathComponent:@"savedata.dat"];
        [[NSMutableData dataWithLength:257] writeToFile:limitedPrimary atomically:YES];
        SDBSaveStore *limitedStore = [[SDBSaveStore alloc] initWithDirectory:limited];
        if (!require([limitedStore loadData] == nil && limitedStore.lastError.length, "oversized progress file rejected")) return 1;
        [NSFileManager.defaultManager removeItemAtPath:limitedPrimary error:nil];
        if (!require(mkfifo(limitedPrimary.fileSystemRepresentation, 0600) == 0, "nonregular fixture created")) return 1;
        limitedStore = [[SDBSaveStore alloc] initWithDirectory:limited];
        if (!require([limitedStore loadData] == nil && limitedStore.lastError.length, "FIFO rejected without blocking on open")) return 1;
        [NSFileManager.defaultManager removeItemAtPath:limitedPrimary error:nil];
        if (!require(symlink(blocked.fileSystemRepresentation, limitedPrimary.fileSystemRepresentation) == 0,
                     "symlink fixture created")) return 1;
        limitedStore = [[SDBSaveStore alloc] initWithDirectory:limited];
        if (!require([limitedStore loadData] == nil && limitedStore.lastError.length &&
                     [[NSData dataWithContentsOfFile:blocked] isEqual:first], "symlink rejected without touching target")) return 1;

        // A private test suite never touches the real app's preferences.
        NSString *suiteName = [@"dev.cammalleri.SpaceUndeadbeef.save-tests." stringByAppendingString:NSUUID.UUID.UUIDString];
        NSUserDefaults *preferences = [[NSUserDefaults alloc] initWithSuiteName:suiteName];
        @try {
            NSString *key = @"progress.tvOS.v1";
            SDBSaveStore *tv = [[SDBSaveStore alloc] initWithPreferences:preferences legacyDirectory:nil];
            if (!require(![tv loadData] && !tv.lastError, "first TV launch needs no filesystem permission") ||
                !require([tv writeData:first] && !tv.lastError, "TV preferences accept the original checkpoint") ||
                !require([preferences dataForKey:key].length < 4096, "entire TV transaction stays below 4 KiB")) return 1;
            NSData *unchanged = [preferences dataForKey:key];
            if (!require([tv writeData:first] && [[preferences dataForKey:key] isEqual:unchanged], "unchanged TV saves do not replace the transaction") ||
                !require([tv writeData:second], "next TV checkpoint writes")) return 1;
            tv = [[SDBSaveStore alloc] initWithPreferences:preferences legacyDirectory:nil];
            if (!require([[tv loadData] isEqual:second], "new TV store restores the exact checkpoint")) return 1;
            NSMutableDictionary *transaction = [[NSPropertyListSerialization propertyListWithData:[preferences dataForKey:key] options:NSPropertyListMutableContainers format:nil error:nil] mutableCopy];
            transaction[@"records"][0][@"sha256"] = @"broken";
            [preferences setObject:[NSPropertyListSerialization dataWithPropertyList:transaction format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil] forKey:key];
            tv = [[SDBSaveStore alloc] initWithPreferences:preferences legacyDirectory:nil];
            if (!require([[tv loadData] isEqual:first] && tv.recoveredFromBackup, "TV recovers previous verified checkpoint when newest checksum fails")) return 1;
            [preferences setObject:[NSMutableData dataWithLength:4097] forKey:key];
            tv = [[SDBSaveStore alloc] initWithPreferences:preferences legacyDirectory:nil];
            if (!require(![tv loadData] && tv.lastError.length, "oversized TV record rejected")) return 1;
            [preferences removeObjectForKey:key];
            tv = [[SDBSaveStore alloc] initWithPreferences:preferences legacyDirectory:legacy];
            if (!require([[tv loadData] isEqual:first] && [preferences dataForKey:key].length &&
                         [[NSData dataWithContentsOfFile:[legacy stringByAppendingPathComponent:@"savedata.dat"]] isEqual:first],
                         "TV migration validates readable legacy progress and preserves its file")) return 1;
            [preferences setObject:@"wrong type" forKey:key];
            tv = [[SDBSaveStore alloc] initWithPreferences:preferences legacyDirectory:nil];
            if (!require(![tv loadData] && tv.lastError.length, "unexpected TV preferences type rejected")) return 1;
        } @finally { [preferences removePersistentDomainForName:suiteName]; }

        NSDictionary *portable = [SDBSaveStore portableSnapshotForData:second];
        if (!require([[SDBSaveStore dataFromPortableSnapshot:portable] isEqual:second], "portable record round trip") ||
            !require([SDBSaveStore dataFromPortableSnapshot:@{@"schema":@2,@"saveData":second,@"sha256":portable[@"sha256"]}] == nil,
                     "future portable schema rejected")) return 1;
        NSMutableDictionary *tampered = [portable mutableCopy]; tampered[@"saveData"] = changedUnknown;
        if (!require([SDBSaveStore dataFromPortableSnapshot:tampered] == nil, "portable checksum mismatch rejected")) return 1;
        NSMutableData *invalidCursor = fixture(); put(invalidCursor, 0x2c, 0xffffffff);
        if (!require([SDBSaveStore portableSnapshotForData:invalidCursor] == nil, "unsafe scenario resume cursor rejected")) return 1;
        NSMutableData *invalidCounter = fixture(2, 4);
        if (!require([SDBSaveStore portableSnapshotForData:invalidCounter] == nil, "counter must agree with original checkpoint cursor")) return 1;
        NSMutableData *local = fixture(2, 8, 400), *remote = fixture(1, 4, 900);
        static_cast<uint8_t *>(local.mutableBytes)[200] = 71;
        put(local, 0x10, 0x3c088889); put(local, 0x14, 0);
        NSMutableData *expected = [local mutableCopy]; put(expected, 0x24, 900);
        if (!require([[SDBSaveStore mergeLocalData:local remoteData:remote] isEqual:expected],
                     "older high score never regresses checkpoint or local preferences/unknown bytes")) return 1;
        put(remote, 0x34, 1);
        expected = [local mutableCopy];
        for (NSUInteger offset : {NSUInteger(0x20),NSUInteger(0x28),NSUInteger(0x2c),NSUInteger(0x30),NSUInteger(0x34),NSUInteger(0x38)})
            memcpy(static_cast<uint8_t *>(expected.mutableBytes) + offset, static_cast<const uint8_t *>(remote.bytes) + offset, 4);
        put(expected, 0x24, 900);
        if (!require([[SDBSaveStore mergeLocalData:local remoteData:remote] isEqual:expected],
                     "farther lap carries its checkpoint fields and keeps local non-progress bytes")) return 1;
        printf("Passed %u save-store checks.\n", checks);
    }
}
