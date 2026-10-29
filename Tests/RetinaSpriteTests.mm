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
static std::vector<uint8_t> decode(NSString *path,unsigned width,unsigned height) {
    NSURL *url=[NSURL fileURLWithPath:path];
    CGImageSourceRef source=CGImageSourceCreateWithURL((__bridge CFURLRef)url,nullptr);
    CGImageRef image=source?CGImageSourceCreateImageAtIndex(source,0,nullptr):nullptr;
    if(source)CFRelease(source);
    if(!image)return {};
    if(CGImageGetWidth(image)!=width||CGImageGetHeight(image)!=height){CGImageRelease(image);return {};}
    std::vector<uint8_t> pixels(size_t(width)*height*4);
    CGColorSpaceRef space=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context=CGBitmapContextCreate(pixels.data(),width,height,8,width*4,space,kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if(!context){CGImageRelease(image);return {};}
    CGContextDrawImage(context,CGRectMake(0,0,width,height),image);
    CGContextRelease(context);CGImageRelease(image);return pixels;
}
struct Coverage {double area=0,x=0,y=0;};
static Coverage coverage(const std::vector<uint8_t>&p,unsigned width,unsigned height,unsigned scale,
                         unsigned x0=0,unsigned y0=0,unsigned cropWidth=0,unsigned cropHeight=0) {
    Coverage result;
    if(!cropWidth)cropWidth=width;if(!cropHeight)cropHeight=height;
    for(unsigned y=y0;y<y0+cropHeight;++y)for(unsigned x=x0;x<x0+cropWidth;++x) {
        const double alpha=p[(size_t(y)*width+x)*4+3]/255.;
        result.area+=alpha;result.x+=(x-x0+.5)*alpha;result.y+=(y-y0+.5)*alpha;
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
    if(!require(engine&&!engine.failure,"actual engine loads all prepared gameplay sprites"))return 1;
    const Runtime *r=runtime(engine);if(!require(r!=nullptr,"runtime storage available"))return 1;
    const uint32_t records=readWord(r->cpu,0x15744);
    NSString *modern=[[resources stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"Modern/Sprites"];
    NSDictionary *manifest=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:
        [modern stringByAppendingPathComponent:@"manifest.json"]] options:0 error:nil];
    NSArray *entries=manifest[@"textures"];
    if(!require(entries.count==16,"all original gameplay texture slots are covered"))return 1;
    double maximumArea=0,maximumDrift=0;
    for(NSDictionary *entry in entries) {
        NSString *name=entry[@"name"];
        const unsigned index=[entry[@"entry"] unsignedIntValue],width=[entry[@"width"] unsignedIntValue],height=[entry[@"height"] unsignedIntValue];
        unsigned pw=1,ph=1;while(pw<width)pw*=2;while(ph<height)ph*=2;
        const auto found=r->textures.find(index+1);
        if(!require(found!=r->textures.end(),"original texture ID available"))return 1;
        const auto &texture=found->second;
        if(!require(unsigned(texture.width)==pw*4&&unsigned(texture.height)==ph*4&&unsigned(texture.contentWidth)==width*4&&unsigned(texture.contentHeight)==height*4,
                    "actual loader uses the 4x content and proportional POT padding"))return 1;
        const uint32_t p=records+index*32;
        if(!require(readWord(r->cpu,p+4)==bits(width)&&readWord(r->cpu,p+8)==bits(height)&&
                    readWord(r->cpu,p+12)==pw&&readWord(r->cpu,p+16)==ph&&
                    readWord(r->cpu,p+24)==bits(float(width)/pw)&&readWord(r->cpu,p+28)==bits(float(height)/ph),
                    "guest size, padding and normalized UVs remain bit-exact"))return 1;
        auto original=decode([resources stringByAppendingPathComponent:name],width,height);
        if(!require(!original.empty(),"original source decodes"))return 1;
        NSArray *frames=entry[@"frames"];
        if(frames&&(index==51||index==52)) {
            const uint32_t data=0x13e34+(index-51)*32;
            const unsigned count=readWord(r->cpu,data+4),pointer=readWord(r->cpu,data+8);
            if(!require(frames.count==count,"atlas contains every original animation frame"))return 1;
            for(unsigned f=0;f<count;++f) {
                const uint32_t address=pointer+f*40;
                auto number=[&](unsigned offset){uint32_t word=readWord(r->cpu,address+offset);float value;std::memcpy(&value,&word,4);return value;};
                const unsigned x=unsigned(std::lround(number(20)*width)),y=unsigned(std::lround(number(24)*height));
                const unsigned w=unsigned(std::lround(number(28)*width))-x,h=unsigned(std::lround(number(32)*height))-y;
                NSArray *rect=frames[f];
                if(!require(readWord(r->cpu,address)==index&&[rect[0] unsignedIntValue]==x&&[rect[1] unsignedIntValue]==y&&
                            [rect[2] unsignedIntValue]==w&&[rect[3] unsignedIntValue]==h,
                            "frame crop matches the original executable UVs and texture ID"))return 1;
            }
        }
        for(unsigned scale:{2u,4u}) {
            auto pixels=decode([modern stringByAppendingPathComponent:[NSString stringWithFormat:@"%ux/%@",scale,name]],width*scale,height*scale);
            if(!require(!pixels.empty(),"Watch and full-density sprite dimensions decode"))return 1;
            NSArray *rects=frames?:@[@[@0,@0,@(width),@(height)]];
            for(NSArray *rect in rects) {
                const unsigned x=[rect[0] unsignedIntValue],y=[rect[1] unsignedIntValue],w=[rect[2] unsignedIntValue],h=[rect[3] unsignedIntValue];
                auto before=coverage(original,width,height,1,x,y,w,h);
                auto after=coverage(pixels,width*scale,height*scale,scale,x*scale,y*scale,w*scale,h*scale);
                const double area=std::abs(after.area-before.area),drift=std::hypot(after.x-before.x,after.y-before.y);
                maximumArea=std::max(maximumArea,area);maximumDrift=std::max(maximumDrift,drift);
                // A 16x16 debris tile has only tens of covered pixels; allow
                // less than two original pixels of antialiasing area there.
                if(!require(area<std::max(2.,before.area*.02)&&drift<.3,
                            "each individual sprite/frame retains alpha coverage and subpixel registration")) {
                    std::fprintf(stderr,"%s %ux frame %u,%u area %.4f / %.4f drift %.4f\n",name.UTF8String,scale,x,y,area,before.area,drift);return 1;
                }
            }
        }
    }
    NSString *fallback=[temporary stringByAppendingPathComponent:@"fallback"];
    NSFileManager *files=NSFileManager.defaultManager;
    [files createDirectoryAtPath:fallback withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *originalLink=[fallback stringByAppendingPathComponent:@"Original"];
    if(!require([files createSymbolicLinkAtPath:originalLink withDestinationPath:resources error:nil],"original-only fixture isolated"))return 1;
    setenv("SDB_SAVE_DIRECTORY",[temporary stringByAppendingPathComponent:@"fallback-save"].UTF8String,1);
    SDBEngine *legacy=[[SDBEngine alloc] initWithResourcePath:originalLink];
    if(!require(!legacy.failure&&runtime(legacy)->textures.at(53).width==512,"absent modern set retains original bitmap fallback"))return 1;
    NSString *broken=[fallback stringByAppendingPathComponent:@"Modern/Sprites/4x"];
    [files createDirectoryAtPath:broken withIntermediateDirectories:YES attributes:nil error:nil];
    setenv("SDB_SAVE_DIRECTORY",[temporary stringByAppendingPathComponent:@"broken-save"].UTF8String,1);
    SDBEngine *invalid=[[SDBEngine alloc] initWithResourcePath:originalLink];
    if(!require([invalid.failure containsString:@"Retina gameplay-sprite texture"],"partial set fails explicitly"))return 1;
    std::printf("PASS %u retina sprite checks; maximum area delta %.4f original pixels, centroid drift %.4f original pixels\n",checks,maximumArea,maximumDrift);
    return 0;
}}
