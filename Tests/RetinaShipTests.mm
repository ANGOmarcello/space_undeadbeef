// Created by Angelo Cammalleri on 29.10.2026.
// Actual texture-loader/guest-metric checks, with temporary saves only.
#include "../Sources/Legacy/SDBEngine.mm"
#import <objc/runtime.h>
#include <cstdio>

static unsigned checks=0;
static bool require(bool condition,const char *message) {
    ++checks;
    if(!condition)std::fprintf(stderr,"FAIL %s\n",message);
    return condition;
}
static const Runtime *runtime(SDBEngine *engine) {
    Ivar ivar=class_getInstanceVariable(SDBEngine.class,"_runtime");
    if(!ivar)return nullptr;
    const auto offset=ivar_getOffset(ivar);
    if(offset<0||size_t(offset)+sizeof(std::unique_ptr<Runtime>)>class_getInstanceSize(SDBEngine.class))return nullptr;
    auto object=static_cast<const uint8_t *>((__bridge const void *)engine);
    return reinterpret_cast<const std::unique_ptr<Runtime> *>(object+offset)->get();
}
static uint32_t readWord(const GuestCPU &cpu,uint32_t address) {
    if(size_t(address)+4>cpu.memory.size())std::abort();
    uint32_t value;std::memcpy(&value,cpu.memory.data()+address,4);return value;
}
static std::vector<uint8_t> decode(NSString *path,unsigned side) {
    NSURL *url=[NSURL fileURLWithPath:path];
    CGImageSourceRef source=CGImageSourceCreateWithURL((__bridge CFURLRef)url,nullptr);
    CGImageRef image=source?CGImageSourceCreateImageAtIndex(source,0,nullptr):nullptr;
    if(source)CFRelease(source);
    if(!image)return {};
    if(CGImageGetWidth(image)!=side||CGImageGetHeight(image)!=side){CGImageRelease(image);return {};}
    std::vector<uint8_t> pixels(size_t(side)*side*4);
    CGColorSpaceRef space=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context=CGBitmapContextCreate(pixels.data(),side,side,8,side*4,space,kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if(!context){CGImageRelease(image);return {};}
    CGContextDrawImage(context,CGRectMake(0,0,side,side),image);
    CGContextRelease(context);CGImageRelease(image);return pixels;
}
struct Coverage {double area=0,x=0,y=0;};
static Coverage coverage(const std::vector<uint8_t>&p,unsigned side,unsigned scale) {
    Coverage result;
    for(unsigned y=0;y<side;++y)for(unsigned x=0;x<side;++x) {
        const double alpha=p[(size_t(y)*side+x)*4+3]/255.;
        result.area+=alpha;result.x+=(x+.5)*alpha;result.y+=(y+.5)*alpha;
    }
    if(result.area){result.x/=result.area*scale;result.y/=result.area*scale;}
    result.area/=scale*scale;return result;
}
int main(int argc,const char **argv) {@autoreleasepool {
    if(argc!=3)return 64;
    NSString *resources=@(argv[1]),*temporary=@(argv[2]);
    if(![temporary hasPrefix:@"/private/tmp/"])return 64;
    setenv("SDB_SAVE_DIRECTORY",[temporary stringByAppendingPathComponent:@"save"].UTF8String,1);
    setenv("SDB_MUTE_AUDIO","1",1);setenv("SDB_CPU_RENDERER","1",1);
    SDBEngine *engine=[[SDBEngine alloc] initWithResourcePath:resources];
    if(!require(engine&&!engine.failure,"engine loads all prepared views"))return 1;
    const Runtime *r=runtime(engine);
    if(!require(r!=nullptr,"actual runtime storage is readable"))return 1;
    const uint32_t records=readWord(r->cpu,0x15744);
    double maximumAreaChange=0,maximumCenterDrift=0;
    for(unsigned index=0;index<25;++index) {
        NSString *name=[NSString stringWithFormat:@"playerShip_%02u.png",index+1];
        const auto found=r->textures.find(index+13);
        if(!require(found!=r->textures.end(),"each original ship texture ID remains available"))return 1;
        const auto &texture=found->second;
        if(!require(texture.width==512&&texture.height==512&&texture.pixels.size()==512*512*4,
                    "native host loads the 4x texture instead of the original bitmap"))return 1;
        const uint32_t p=records+(index+12)*32;
        // Read without changing the guest. These control all original sprite
        // sizing and UVs, including its entrance and bank animation.
        const auto &cpu=r->cpu;
        if(!require(readWord(cpu,p+4)==bits(128)&&readWord(cpu,p+8)==bits(128)&&
                    readWord(cpu,p+12)==128&&readWord(cpu,p+16)==128&&
                    readWord(cpu,p+24)==bits(1)&&readWord(cpu,p+28)==bits(1),
                    "guest retains exact original size, padded size and normalized UVs"))return 1;
        auto original=decode([resources stringByAppendingPathComponent:name],128);
        if(!require(!original.empty(),"original alpha source decodes"))return 1;
        const Coverage before=coverage(original,128,1);
        for(unsigned scale:{2u,4u}) {
            NSString *path=[[resources stringByDeletingLastPathComponent] stringByAppendingPathComponent:
                [NSString stringWithFormat:@"Modern/PlayerShip/%ux/%@",scale,name]];
            const auto pixels=decode(path,128*scale);
            if(!require(!pixels.empty(),"both full-size and Watch exports decode at their expected density"))return 1;
            const Coverage after=coverage(pixels,128*scale,scale);
            const double area=std::abs(after.area/before.area-1),drift=std::hypot(after.x-before.x,after.y-before.y);
            maximumAreaChange=std::max(maximumAreaChange,area);maximumCenterDrift=std::max(maximumCenterDrift,drift);
            if(!require(area<.02&&drift<.3,"all 50 silhouettes retain coverage and registration within subpixel limits"))return 1;
        }
    }
    NSString *fallback=[temporary stringByAppendingPathComponent:@"fallback"];
    NSFileManager *files=NSFileManager.defaultManager;
    [files createDirectoryAtPath:fallback withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *originalLink=[fallback stringByAppendingPathComponent:@"Original"];
    if(!require([files createSymbolicLinkAtPath:originalLink withDestinationPath:resources error:nil],"isolated original-only fixture created"))return 1;
    setenv("SDB_SAVE_DIRECTORY",[temporary stringByAppendingPathComponent:@"fallback-save"].UTF8String,1);
    SDBEngine *legacy=[[SDBEngine alloc] initWithResourcePath:originalLink];
    if(!require(!legacy.failure&&runtime(legacy)->textures.at(13).width==128,"original-only fixture retains the original bitmap fallback"))return 1;
    NSString *broken=[fallback stringByAppendingPathComponent:@"Modern/PlayerShip/4x"];
    [files createDirectoryAtPath:broken withIntermediateDirectories:YES attributes:nil error:nil];
    setenv("SDB_SAVE_DIRECTORY",[temporary stringByAppendingPathComponent:@"broken-save"].UTF8String,1);
    SDBEngine *invalid=[[SDBEngine alloc] initWithResourcePath:originalLink];
    if(!require([invalid.failure containsString:@"Retina player-ship texture"],"partial installed art fails explicitly instead of mixing densities"))return 1;
    std::printf("PASS %u retina ship checks; max area change %.4f%%, max centroid drift %.4f original pixels\n",checks,maximumAreaChange*100,maximumCenterDrift);
    return 0;
}}
