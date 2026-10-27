// Created by Angelo Cammalleri on 27.10.2026.
#import "SDBSaveStore.h"
#include <atomic>
#include <cstdio>
#include <cstring>
#include <thread>
#include <chrono>

@interface SDBSaveCoordinator (TestConstruction)
- (instancetype)initWithStore:(SDBSaveStore *)store;
@end

@interface ControlledSaveStore : SDBSaveStore
@property(nonatomic, readonly) dispatch_semaphore_t entered;
@property(nonatomic, readonly) dispatch_semaphore_t releaseWrite;
@property(nonatomic) BOOL blockFirst;
@property(nonatomic) BOOL failNext;
@property(nonatomic, readonly) NSArray<NSData *> *attempts;
@property(nonatomic, readonly) BOOL gateTimedOut;
@end

@implementation ControlledSaveStore {
    NSLock *_lock;
    NSMutableArray<NSData *> *_attempts;
    NSData *_stored;
    NSString *_testError;
    std::atomic<bool> _gateTimedOut;
}
- (instancetype)initWithDirectory:(NSString *)directory {
    if ((self=[super initWithDirectory:directory])) {
        _lock=[NSLock new]; _attempts=[NSMutableArray array];
        _entered=dispatch_semaphore_create(0); _releaseWrite=dispatch_semaphore_create(0);
        _gateTimedOut.store(false);
    }
    return self;
}
- (NSArray<NSData *> *)attempts { [_lock lock]; NSArray *copy=[_attempts copy]; [_lock unlock]; return copy; }
- (NSString *)lastError { [_lock lock]; NSString *error=_testError; [_lock unlock]; return error; }
- (BOOL)gateTimedOut { return _gateTimedOut.load(); }
- (NSData *)loadData { [_lock lock]; NSData *data=_stored; [_lock unlock]; return data; }
- (BOOL)writeData:(NSData *)data {
    [_lock lock];
    [_attempts addObject:[data copy]];
    const BOOL block=_blockFirst && _attempts.count==1;
    const BOOL fail=_failNext;
    _failNext=NO;
    [_lock unlock];
    if (block) {
        dispatch_semaphore_signal(_entered);
        if (dispatch_semaphore_wait(_releaseWrite, dispatch_time(DISPATCH_TIME_NOW, 5*NSEC_PER_SEC))) {
            _gateTimedOut.store(true);
            [_lock lock]; _testError=@"Test disk gate timed out"; [_lock unlock];
            return NO;
        }
    }
    [_lock lock];
    if (fail) _testError=@"Injected disk failure";
    else { _stored=[data copy]; _testError=nil; }
    [_lock unlock];
    return !fail;
}
@end

namespace {
unsigned checks=0;
bool require(bool condition,const char *message) {
    ++checks;
    if (!condition) std::fprintf(stderr,"FAIL %s\n",message);
    return condition;
}
bool waitFor(dispatch_semaphore_t semaphore,const char *message) {
    return require(dispatch_semaphore_wait(semaphore,dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC))==0,message);
}
NSMutableData *snapshot(uint32_t marker) {
    NSMutableData *data=[NSMutableData dataWithLength:256];
    const uint32_t magic=0x30485350,size=256;
    std::memcpy(static_cast<uint8_t *>(data.mutableBytes),&magic,sizeof(magic));
    std::memcpy(static_cast<uint8_t *>(data.mutableBytes)+8,&size,sizeof(size));
    std::memcpy(static_cast<uint8_t *>(data.mutableBytes)+0x80,&marker,sizeof(marker));
    return data;
}
uint32_t marker(NSData *data) {
    uint32_t value=0;
    if (data.length>=0x84) std::memcpy(&value,static_cast<const uint8_t *>(data.bytes)+0x80,sizeof(value));
    return value;
}
bool firstAndLatest(NSString *directory) {
    ControlledSaveStore *store=[[ControlledSaveStore alloc] initWithDirectory:directory]; store.blockFirst=YES;
    SDBSaveCoordinator *coordinator=[[SDBSaveCoordinator alloc] initWithStore:store];
    [coordinator enqueueData:snapshot(1)];
    if (!waitFor(store.entered,"first periodic write entered controlled disk stall")) return false;
    dispatch_semaphore_t queued=dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        for (uint32_t value=2;value<=100;++value) [coordinator enqueueData:snapshot(value)];
        (void)coordinator.lastError;
        dispatch_semaphore_signal(queued);
    });
    const bool nonblocking=waitFor(queued,"enqueue and error getter finish while the disk write remains stalled");
    const bool bounded=require(store.attempts.count==1,"only the first record touches a stalled store");
    dispatch_semaphore_signal(store.releaseWrite);
    NSData *loaded=[coordinator loadData];
    NSArray<NSData *> *attempts=store.attempts;
    return nonblocking && bounded && require(!store.gateTimedOut,"no gate deadline was needed") &&
        require(attempts.count==2 && marker(attempts[0])==1 && marker(attempts[1])==100,
                "one hundred periodic records coalesce to first plus latest") &&
        require(marker(loaded)==100,"queue drain loads the latest immutable periodic record");
}
bool explicitSupersedes(NSString *directory) {
    ControlledSaveStore *store=[[ControlledSaveStore alloc] initWithDirectory:directory]; store.blockFirst=YES;
    SDBSaveCoordinator *coordinator=[[SDBSaveCoordinator alloc] initWithStore:store];
    [coordinator enqueueData:snapshot(1)];
    if (!waitFor(store.entered,"explicit-write fixture entered controlled disk stall")) return false;
    for (uint32_t value=2;value<=100;++value) [coordinator enqueueData:snapshot(value)];
    dispatch_semaphore_t completed=dispatch_semaphore_create(0);
    __block BOOL written=NO;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        written=[coordinator writeData:snapshot(200)];
        dispatch_semaphore_signal(completed);
    });
    // Observe the existing private lock only to place the explicit operation
    // before release of the stalled disk. Assertions below concern actual write
    // history/final data; no sleep guesses the queue's scheduling phase.
    NSLock *lock=[coordinator valueForKey:@"pendingLock"];
    bool claimed=false;
    const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(3);
    while (std::chrono::steady_clock::now()<deadline) {
        [lock lock]; claimed=[coordinator valueForKey:@"pending"]==nil; [lock unlock];
        if (claimed) break;
        std::this_thread::yield();
    }
    const bool waits=require(dispatch_semaphore_wait(completed,DISPATCH_TIME_NOW)!=0,
                             "explicit lifecycle write waits for the older in-flight transaction");
    dispatch_semaphore_signal(store.releaseWrite);
    const bool finished=waitFor(completed,"explicit latest write completes after disk release");
    NSData *loaded=[coordinator loadData];
    NSArray<NSData *> *attempts=store.attempts;
    return require(claimed,"explicit write claims the pending checkpoint before disk release") && waits && finished &&
        require(written && attempts.count==2 && marker(attempts[0])==1 && marker(attempts[1])==200,
                "explicit lifecycle data supersedes pending periodic checkpoints") &&
        require(marker(loaded)==200 && marker(store.loadData)==200,"no stale periodic write overwrites explicit progress") &&
        require(!store.gateTimedOut,"explicit-write fixture released its disk gate");
}
bool errorsAndCopy(NSString *directory) {
    ControlledSaveStore *store=[[ControlledSaveStore alloc] initWithDirectory:directory];
    SDBSaveCoordinator *coordinator=[[SDBSaveCoordinator alloc] initWithStore:store];
    store.failNext=YES; [coordinator enqueueData:snapshot(1)]; (void)[coordinator loadData];
    if (!require([coordinator.lastError isEqualToString:@"Injected disk failure"],"asynchronous disk failures reach the nonblocking getter")) return false;
    if (!require([coordinator writeData:snapshot(2)] && coordinator.lastError==nil,
                 "successful explicit recovery clears the prior disk error")) return false;
    [coordinator enqueueData:[NSData data]];
    if (!require(coordinator.lastError!=nil && store.attempts.count==2,"invalid periodic records never reach the disk owner")) return false;
    [coordinator enqueueData:snapshot(5)];
    if (!require(marker([coordinator loadData])==5 && coordinator.lastError==nil,
                 "successful asynchronous recovery clears the last reported error")) return false;
    ControlledSaveStore *copyStore=[[ControlledSaveStore alloc] initWithDirectory:directory]; copyStore.blockFirst=YES;
    SDBSaveCoordinator *copyCoordinator=[[SDBSaveCoordinator alloc] initWithStore:copyStore];
    [copyCoordinator enqueueData:snapshot(3)];
    if (!waitFor(copyStore.entered,"copy fixture entered controlled disk stall")) return false;
    NSMutableData *callerData=snapshot(4);
    [copyCoordinator enqueueData:callerData];
    const uint32_t changed=999;
    std::memcpy(static_cast<uint8_t *>(callerData.mutableBytes)+0x80,&changed,sizeof(changed));
    dispatch_semaphore_signal(copyStore.releaseWrite);
    return require(marker([copyCoordinator loadData])==4,"queued mutable caller data is copied before later mutation") &&
        require(copyCoordinator.lastError==nil,"copied queued snapshot completes without a disk error");
}
bool actualRecovery(NSString *directory) {
    NSString *path=[directory stringByAppendingPathComponent:@"real-store"];
    SDBSaveCoordinator *first=[[SDBSaveCoordinator alloc] initWithDirectory:path];
    if (!require([first loadData]==nil,"empty isolated installation has no saved record") ||
        !require([first writeData:snapshot(41)],"explicit checkpoint writes original data and recovery transaction")) return false;
    [first enqueueData:snapshot(42)];
    if (!require(marker([first loadData])==42,"periodic checkpoint reaches actual bounded disk store")) return false;
    SDBSaveCoordinator *relaunched=[[SDBSaveCoordinator alloc] initWithDirectory:path];
    NSData *loaded=[relaunched loadData];
    if (!require(loaded.length==256 && marker(loaded)==42,"recreated coordinator loads the latest original 256-byte record")) return false;
    NSString *primary=[path stringByAppendingPathComponent:@"savedata.dat"];
    if (!require([[@"broken" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:primary atomically:YES],
                 "corruption fixture replaces only its task-owned primary")) return false;
    SDBSaveCoordinator *recovered=[[SDBSaveCoordinator alloc] initWithDirectory:path];
    NSData *backup=[recovered loadData];
    return require(backup.length==256 && marker(backup)==42 && recovered.lastError==nil,
                   "fresh coordinator restores the checksummed recovery transaction") &&
        require([[NSData dataWithContentsOfFile:primary] isEqual:backup],"recovery repairs the isolated primary atomically");
}
}

int main(int argc,const char *argv[]) {
    @autoreleasepool {
        if (argc!=2) {std::fprintf(stderr,"Usage: SaveCoordinatorTests TASK_TEMP_DIRECTORY\n");return 64;}
        NSString *directory=[NSString stringWithUTF8String:argv[1]];
        if (!require([directory hasPrefix:@"/private/tmp/space-save-coordinator."],"all test storage is task-owned temporary data")) return 64;
        if (!firstAndLatest(directory) || !explicitSupersedes(directory) ||
            !errorsAndCopy(directory) || !actualRecovery(directory)) return 1;
        std::printf("PASS %u save coordinator checks: bounded backlog, nonblocking enqueue/getter, explicit ordering, errors, immutable snapshots, disk relaunch/recovery\n",checks);
        return 0;
    }
}
