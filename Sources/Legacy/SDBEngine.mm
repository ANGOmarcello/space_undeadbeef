// Created by Angelo Cammalleri on 25.10.2026.
#import "SDBEngine.h"
#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>
#import <CommonCrypto/CommonDigest.h>
#import <TargetConditionals.h>
#include "GuestCPU.h"
#include <algorithm>
#include <cmath>
#include <cstring>
#include <map>
#include <memory>
#include <sstream>
#include <vector>

namespace {
constexpr int Width = 480, Height = 320;
constexpr uint32_t SilentOn=0x01d00000,SilentOff=0x01d00004,SilentOnDraw=0x01d00008,SilentOffDraw=0x01d0000c;
uint32_t bits(float f) { uint32_t u; memcpy(&u,&f,4); return u; }
float real(uint32_t u) { float f; memcpy(&f,&u,4); return f; }
struct Texture { int width=0,height=0; std::vector<uint8_t> pixels; };
struct Vertex { float x,y,u,v,r,g,b,a; };
struct Matrix {
    std::array<float,16> m={1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1};
    Matrix operator*(const Matrix &m) const {
        Matrix result;result.m.fill(0);
        for(int col=0;col<4;++col)for(int row=0;row<4;++row)for(int k=0;k<4;++k)
            result.m[col*4+row]+=this->m[k*4+row]*m.m[col*4+k];
        return result;
    }
    static Matrix translation(float x,float y,float z) {Matrix r;r.m[12]=x;r.m[13]=y;r.m[14]=z;return r;}
    static Matrix scale(float x,float y,float z) {Matrix r;r.m[0]=x;r.m[5]=y;r.m[10]=z;return r;}
    static Matrix rotation(float degrees,float x,float y,float z) {
        Matrix r;float length=std::sqrt(x*x+y*y+z*z);if(length==0)return r;
        x/=length;y/=length;z/=length;float angle=degrees*float(M_PI/180),c=std::cos(angle),s=std::sin(angle),t=1-c;
        r.m[0]=t*x*x+c;r.m[4]=t*x*y-s*z;r.m[8]=t*x*z+s*y;
        r.m[1]=t*x*y+s*z;r.m[5]=t*y*y+c;r.m[9]=t*y*z-s*x;
        r.m[2]=t*x*z-s*y;r.m[6]=t*y*z+s*x;r.m[10]=t*z*z+c;
        return r;
    }
};
struct Array { uint32_t address=0,type=0x1406,size=2,stride=0; };
struct Runtime {
    GuestCPU cpu;
    uint32_t game=0,sound=0,heap=0x20000,seed=1,nextSource=1;
    std::map<uint32_t,uint32_t> allocations;
    std::multimap<uint32_t,uint32_t> freeBlocks;
    std::map<uint32_t,std::string> imports;
    std::map<uint32_t,Texture> textures;
    std::vector<uint8_t> pixels = std::vector<uint8_t>(Width*Height*4);
    Matrix matrix;
    std::vector<Matrix> stack;
    Array vertices,uvs,colors;
    bool textured=false,colorArray=false,blend=false;
    uint32_t texture=0,sourceBlend=0x302,destBlend=0x303,textureEnv=0x1e01;
    float color[4]={1,1,1,1};
    uint64_t frames=0,draws=0,audioEvents=0;
    float lastX=0,lastY=0;
    bool touching=false;

    uint32_t allocate(uint32_t size) {
        if(size>0x1600000) { cpu.fail("Guest allocation exceeds memory limit");return 0; }
        size=std::max(8u,(size+7)&~7u);
        auto it=freeBlocks.lower_bound(size);
        uint32_t result;
        if(it!=freeBlocks.end()) { result=it->second; size=it->first;freeBlocks.erase(it); }
        else { result=heap;if(heap+size>=0x1800000) {cpu.fail("Guest heap exhausted");return 0;}heap+=size; }
        allocations[result]=size;
        std::fill(cpu.memory.begin()+result,cpu.memory.begin()+result+size,0);
        return result;
    }
    void release(uint32_t p) {
        if(!p)return;
        auto it=allocations.find(p);
        if(it==allocations.end()) {cpu.fail("Guest attempted to free an unknown allocation");return;}
        freeBlocks.emplace(it->second,p);allocations.erase(it);
    }
    std::string string(uint32_t p) {
        std::string value;
        for(unsigned i=0;i<4096;++i) {uint8_t c=cpu.read8(p+i);if(!c)return value;value+=char(c);}
        cpu.fail("Unterminated guest string");return value;
    }
    bool span(uint32_t p,uint32_t n) {
        if(p>cpu.memory.size() || n>cpu.memory.size()-p) {cpu.fail("Invalid guest API buffer");return false;}return true;
    }
    uint32_t arg(unsigned i) {return i<4?cpu.r[i]:cpu.read32(cpu.r[13]+4*(i-4));}
    float farg(unsigned i) {return real(arg(i));}
    float component(Array a,unsigned index,unsigned component) {
        if(!a.address)return 0;
        unsigned size=a.type==0x1406?4:(a.type==0x1402?2:1);
        uint32_t p=a.address+index*(a.stride?a.stride:a.size*size)+component*size;
        if(a.type==0x1406)return real(cpu.read32(p));
        if(a.type==0x1402)return int16_t(cpu.read16(p));
        if(a.type==0x1400)return int8_t(cpu.read8(p));
        if(a.type==0x1401)return cpu.read8(p)/255.f;
        cpu.fail("Unsupported GL vertex array type");return 0;
    }
    Vertex vertex(unsigned i) {
        float x=component(vertices,i,0),y=component(vertices,i,1);
        // Original portrait projection, followed by the landscape presentation.
        float z=vertices.size>=3?component(vertices,i,2):0;
        float mx=matrix.m[0]*x+matrix.m[4]*y+matrix.m[8]*z+matrix.m[12];
        float my=matrix.m[1]*x+matrix.m[5]*y+matrix.m[9]*z+matrix.m[13];
        Vertex p={240+my,160+mx,component(uvs,i,0),component(uvs,i,1),color[0],color[1],color[2],color[3]};
        if(colorArray) {p.r=component(colors,i,0);p.g=component(colors,i,1);p.b=component(colors,i,2);p.a=component(colors,i,3);}
        return p;
    }
    static float edge(const Vertex &a,const Vertex &b,float x,float y) {return (x-a.x)*(b.y-a.y)-(y-a.y)*(b.x-a.x);}
    void triangle(Vertex a,Vertex b,Vertex c) {
        const float area=edge(a,b,c.x,c.y);
        if(!std::isfinite(area)||std::abs(area)<0.00001f)return;
        if(area<0) {std::swap(b,c);}
        const float inv=1/std::abs(area);
        int x0=std::max(0,int(std::floor(std::min({a.x,b.x,c.x})))),x1=std::min(Width-1,int(std::ceil(std::max({a.x,b.x,c.x}))));
        int y0=std::max(0,int(std::floor(std::min({a.y,b.y,c.y})))),y1=std::min(Height-1,int(std::ceil(std::max({a.y,b.y,c.y}))));
        auto ti=textures.find(texture);const Texture *t=textured&&ti!=textures.end()?&ti->second:nullptr;
        auto topLeft=[](const Vertex&p,const Vertex&q) {float dy=q.y-p.y,dx=q.x-p.x;return dy<0||(dy==0&&dx>0);};
        for(int y=y0;y<=y1;++y)for(int x=x0;x<=x1;++x) {
            float ea=edge(b,c,x+.5f,y+.5f),eb=edge(c,a,x+.5f,y+.5f),ec=edge(a,b,x+.5f,y+.5f);
            if(ea<0||eb<0||ec<0||(ea==0&&!topLeft(b,c))||(eb==0&&!topLeft(c,a))||(ec==0&&!topLeft(a,b)))continue;
            float wa=ea*inv,wb=eb*inv,wc=ec*inv;
            float rgba[4]={wa*a.r+wb*b.r+wc*c.r,wa*a.g+wb*b.g+wc*c.g,wa*a.b+wb*b.b+wc*c.b,wa*a.a+wb*b.a+wc*c.a};
            if(t) {
                if(textureEnv==0x1e01)for(float &channel:rgba)channel=1;
                float u=wa*a.u+wb*b.u+wc*c.u,v=wa*a.v+wb*b.v+wc*c.v;
                // GL_LINEAR, clamped to the padded original texture.
                float tx=std::clamp(u*t->width-.5f,0.f,float(t->width-1)),ty=std::clamp(v*t->height-.5f,0.f,float(t->height-1));
                int ix=int(tx),iy=int(ty),jx=std::min(ix+1,t->width-1),jy=std::min(iy+1,t->height-1);
                float fx=tx-ix,fy=ty-iy;
                for(int ch=0;ch<4;++ch) {
                    auto sample=[&](int sx,int sy) {return t->pixels[4*(sy*t->width+sx)+ch]/255.f;};
                    rgba[ch]*=(1-fy)*((1-fx)*sample(ix,iy)+fx*sample(jx,iy))+fy*((1-fx)*sample(ix,jy)+fx*sample(jx,jy));
                }
            }
            unsigned p=4*(y*Width+x);
            auto factor=[&](uint32_t f) {switch(f){case 0:return 0.f;case 1:return 1.f;case 0x302:return rgba[3];case 0x303:return 1-rgba[3];default:cpu.fail("Unsupported GL blend factor");return 0.f;}};
            float sf=blend?factor(sourceBlend):1,df=blend?factor(destBlend):0;
            for(int ch=0;ch<3;++ch)pixels[p+ch]=uint8_t(std::clamp(rgba[ch]*sf*255+pixels[p+ch]*df,0.f,255.f));
            pixels[p+3]=255;
        }
    }
    void draw(uint32_t mode,unsigned first,unsigned count) {
        if(count>4096) {cpu.fail("GL draw count exceeds limit");return;}
        ++draws;
        if(mode==5)for(unsigned i=2;i<count;++i)triangle(vertex(first+i-2),vertex(first+i-1),vertex(first+i));
        else if(mode==4)for(unsigned i=2;i<count;i+=3)triangle(vertex(first+i-2),vertex(first+i-1),vertex(first+i));
        else if(mode==6)for(unsigned i=2;i<count;++i)triangle(vertex(first),vertex(first+i-1),vertex(first+i));
        else cpu.fail("Unsupported GL primitive mode");
    }
};
}

@implementation SDBEngine {
    std::unique_ptr<Runtime> _runtime;
    NSString *_resourcePath;
    NSString *_savePath;
    NSString *_failure;
    CGImageRef _frame;
    NSMutableDictionary<NSNumber*,NSURL*> *_buffers;
    NSMutableDictionary<NSNumber*,AVAudioPlayer*> *_players;
    NSMutableDictionary<NSNumber*,NSNumber*> *_sourceBuffers;
    NSMutableDictionary<NSNumber*,NSNumber*> *_sourceLoops;
    NSMutableDictionary<NSNumber*,NSNumber*> *_sourceGains;
    NSMutableSet<NSNumber*> *_pausedSources;
    BOOL _muted;
    BOOL _suspended;
    BOOL _soundEnabled;
    BOOL _respectsSilentMode;
    NSString *_testPreferencesPath;
    NSMutableDictionary *_testPreferences;
    NSString *_audioSessionError;
    NSInteger _wantedMusicEntry;
    BOOL _wantedMusicLoop;
}

- (CGImageRef)frame {return _frame;}
- (NSString *)failure {return _failure;}
- (NSString *)diagnostics {
    if(!_runtime)return @"Runtime unavailable";
    Runtime &r=*_runtime;
    NSString *category=@"system-output";
    #if !TARGET_OS_OSX
    category=AVAudioSession.sharedInstance.category;
    #endif
    return [NSString stringWithFormat:@"frames=%llu draws=%llu instructions=%llu heap=%u allocations=%lu audio=%llu game=%08x menu=%08x sound=%d respectSilent=%d category=%@ audioError=%@",
        r.frames,r.draws,r.cpu.instructionCount,r.heap,(unsigned long)r.allocations.size(),r.audioEvents,r.game,r.cpu.read32(r.game+4),_soundEnabled,_respectsSilentMode,category,_audioSessionError?:@"none"];
}
- (id)preference:(NSString *)key {
    return _testPreferencesPath?_testPreferences[key]:[NSUserDefaults.standardUserDefaults objectForKey:key];
}
- (void)storePreference:(BOOL)value key:(NSString *)key {
    if(_testPreferencesPath) {
        _testPreferences[key]=@(value);
        [NSFileManager.defaultManager createDirectoryAtPath:_savePath withIntermediateDirectories:YES attributes:nil error:nil];
        [_testPreferences writeToFile:_testPreferencesPath atomically:YES];
    } else [NSUserDefaults.standardUserDefaults setBool:value forKey:key];
}
- (void)configureAudioSession {
    #if !TARGET_OS_OSX
    AVAudioSession *session=AVAudioSession.sharedInstance;
    NSError *error=nil;
    AVAudioSessionCategory category=_respectsSilentMode?AVAudioSessionCategoryAmbient:AVAudioSessionCategoryPlayback;
    AVAudioSessionCategoryOptions options=_respectsSilentMode?0:AVAudioSessionCategoryOptionMixWithOthers;
    [session setCategory:category mode:AVAudioSessionModeDefault options:options error:&error];
    _audioSessionError=error.localizedDescription;
    #endif
}
- (BOOL)soundEnabled {return _soundEnabled;}
- (void)setSoundEnabled:(BOOL)enabled {
    BOOL changed=_soundEnabled!=enabled;_soundEnabled=enabled;
    [self storePreference:enabled key:@"audio.soundEnabled"];
    if(_runtime->sound)_runtime->cpu.write8(_runtime->sound+1,enabled);
    if(!enabled) {
        NSNumber *music=@(_runtime->cpu.read32(_runtime->sound+0xec));
        for(NSNumber *source in [_players.allKeys copy]) {
            if([source isEqual:music]) {[_players[source] pause];}
            else {[_players[source] stop];[_players removeObjectForKey:source];}
        }
    } else if(changed&&!_suspended&&_wantedMusicEntry>=0) {
        _runtime->cpu.call(0xea15,{_runtime->sound,uint32_t(_wantedMusicEntry),uint32_t(_wantedMusicLoop)});
        [self checkFault];
    }
}
- (BOOL)respectsSilentMode {return _respectsSilentMode;}
- (void)setRespectsSilentMode:(BOOL)respect {
    _respectsSilentMode=respect;[self storePreference:respect key:@"audio.respectsSilentMode"];
    [self configureAudioSession];
}
- (void)checkFault {
    if(!_runtime->cpu.fault.empty())_failure=@(_runtime->cpu.fault.c_str());
}
- (instancetype)initWithResourcePath:(NSString *)path {
    if((self=[super init])) {
        _runtime=std::make_unique<Runtime>();_resourcePath=[path copy];
        _buffers=[NSMutableDictionary dictionary];_players=[NSMutableDictionary dictionary];
        _sourceBuffers=[NSMutableDictionary dictionary];_sourceLoops=[NSMutableDictionary dictionary];_sourceGains=[NSMutableDictionary dictionary];
        _pausedSources=[NSMutableSet set];
        _muted=NSProcessInfo.processInfo.environment[@"SDB_MUTE_AUDIO"]!=nil;
        NSString *override=NSProcessInfo.processInfo.environment[@"SDB_SAVE_DIRECTORY"];
        NSURL *base=[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
        _savePath=override?:[[base URLByAppendingPathComponent:NSBundle.mainBundle.bundleIdentifier?:@"dev.cammalleri.space-undeadbeef"] path];
        if(override) {
            // Tests persist only inside their own temporary directory, never real user preferences.
            _testPreferencesPath=[override stringByAppendingPathComponent:@"audio-preferences.plist"];
            _testPreferences=[[NSDictionary dictionaryWithContentsOfFile:_testPreferencesPath] mutableCopy]?:[NSMutableDictionary dictionary];
        }
        _soundEnabled=[self preference:@"audio.soundEnabled"]?[[self preference:@"audio.soundEnabled"] boolValue]:YES;
        _respectsSilentMode=[self preference:@"audio.respectsSilentMode"]?[[self preference:@"audio.respectsSilentMode"] boolValue]:YES;
        _wantedMusicEntry=-1;_wantedMusicLoop=YES;
        __unsafe_unretained SDBEngine *owner=self;
        _runtime->cpu.hook=[owner](GuestCPU &cpu,uint32_t pc) {
            if((pc>=0xee9c&&pc<0xf478)||pc==0xa80c||pc==0xa8a0||pc==0xa958||pc==0x8e04||pc==0xea14||pc==0xe86e||
               (pc>=SilentOn&&pc<=SilentOffDraw))return [owner bridge:pc];
            return false;
        };
        [self loadOriginal];[self checkFault];
        [self configureAudioSession];
        if(!_failure)[self update:0];
    }
    return self;
}
- (void)dealloc {if(_frame)CGImageRelease(_frame);}

- (void)loadOriginal {
    Runtime &r=*_runtime;GuestCPU &c=r.cpu;
    NSData *data=[NSData dataWithContentsOfFile:[_resourcePath stringByAppendingPathComponent:@"psh"]];
    if(!data) {c.fail("Original executable missing; run script/prepare_original.py");return;}
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256(data.bytes,(CC_LONG)data.length,digest);
    NSMutableString *hash=[NSMutableString string];for(unsigned char ch:digest)[hash appendFormat:@"%02x",ch];
    NSData *manifestData=[NSData dataWithContentsOfFile:[_resourcePath stringByAppendingPathComponent:@"manifest.json"]];
    NSDictionary *manifest=manifestData?[NSJSONSerialization JSONObjectWithData:manifestData options:0 error:nil]:nil;
    // This bridge is specific to one binary, never applied to another revision.
    if(![hash isEqualToString:@"f90a2cdeae9c955520c9358b0f511f92d8327ba69650816b34a7d6f177025d1e"]) {c.fail("Unsupported original executable SHA-256");return;}
    if(!manifest) {c.fail("Original resource manifest missing");return;}
    if(data.length<28) {c.fail("Invalid Mach-O");return;}
    auto u32=[&](NSUInteger off)->uint32_t {uint32_t v=0;if(off+4<=data.length)memcpy(&v,(const uint8_t*)data.bytes+off,4);return v;};
    uint32_t symbols=0,symbolCount=0,strings=0,indirect=0,stubAddress=0,stubSize=0,stubIndex=0,stubWidth=0;
    NSUInteger off=28;
    for(uint32_t i=0;i<u32(16);++i) {
        uint32_t cmd=u32(off),size=u32(off+4);
        if(size<8||off+size>data.length) {c.fail("Malformed Mach-O load commands");return;}
        if(cmd==1) {
            uint32_t address=u32(off+24),fileoff=u32(off+32),length=u32(off+36);
            if(length && uint64_t(fileoff)+length<=data.length)c.load(address,(const uint8_t*)data.bytes+fileoff,length);
            for(uint32_t s=0;s<u32(off+48);++s) {
                NSUInteger section=off+56+68*s;
                if(section+68>off+size) {c.fail("Invalid Mach-O section");return;}
                std::string name((const char*)data.bytes+section,strnlen((const char*)data.bytes+section,16));
                if(name=="__symbol_stub4") {stubAddress=u32(section+32);stubSize=u32(section+36);stubIndex=u32(section+60);stubWidth=u32(section+64);}
            }
        } else if(cmd==2) {symbols=u32(off+8);symbolCount=u32(off+12);strings=u32(off+16);}
        else if(cmd==0xb)indirect=u32(off+56);
        off+=size;
    }
    if(!stubWidth) {c.fail("Original import table missing");return;}
    for(uint32_t i=0;i<stubSize/stubWidth;++i) {
        uint32_t index=u32(indirect+4*(stubIndex+i));if(index>=symbolCount)continue;
        uint32_t str=strings+u32(symbols+12*index);
        if(str>=data.length) {c.fail("Invalid original symbol");return;}
        r.imports[stubAddress+i*stubWidth]=std::string((const char*)data.bytes+str,strnlen((const char*)data.bytes+str,data.length-str));
    }
    c.call(0x421d);if(!c.fault.empty())return;uint32_t records=c.read32(0x15744);
    for(NSDictionary *entry in manifest[@"textures"]) {
        uint32_t index=[entry[@"entry"] unsignedIntValue];if(index>=62)continue;
        NSURL *url=[NSURL fileURLWithPath:[_resourcePath stringByAppendingPathComponent:entry[@"name"]]];
        CGImageSourceRef source=CGImageSourceCreateWithURL((__bridge CFURLRef)url,nullptr);
        CGImageRef image=source?CGImageSourceCreateImageAtIndex(source,0,nullptr):nullptr;
        if(source)CFRelease(source);
        if(!image) {c.fail("Original texture could not be decoded");return;}
        unsigned w=(unsigned)CGImageGetWidth(image),h=(unsigned)CGImageGetHeight(image),pw=1,ph=1;
        while(pw<w)pw*=2;while(ph<h)ph*=2;
        Texture t;t.width=pw;t.height=ph;t.pixels.resize(pw*ph*4);
        CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();
        CGContextRef context=CGBitmapContextCreate(t.pixels.data(),pw,ph,8,pw*4,space,kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big);
        CGColorSpaceRelease(space);
        CGContextDrawImage(context,CGRectMake(0,ph-h,w,h),image);CGContextRelease(context);CGImageRelease(image);
        // Texture2D uses straight-alpha GL blending. Convert decoded premultiplication once.
        for(size_t p=0;p<t.pixels.size();p+=4)if(t.pixels[p+3])for(int k=0;k<3;++k)t.pixels[p+k]=uint8_t(std::min(255u,unsigned(t.pixels[p+k])*255/t.pixels[p+3]));
        r.textures[index+1]=std::move(t);
        uint32_t p=records+32*index;c.write32(p,index+1);c.write32(p+4,bits(w));c.write32(p+8,bits(h));
        c.write32(p+12,pw);c.write32(p+16,ph);c.write32(p+20,0);c.write32(p+24,bits(float(w)/pw));c.write32(p+28,bits(float(h)/ph));
    }
    if(!c.fault.empty())return;
    r.sound=r.allocate(0x108);if(!c.fault.empty())return;
    c.call(0xe7e9,{r.sound});if(!c.fault.empty())return;
    c.call(0xeb01,{r.sound});if(!c.fault.empty())return;
    for(NSDictionary *entry in manifest[@"sounds"]) {
        uint32_t index=[entry[@"entry"] unsignedIntValue];if(index>=12)continue;
        uint32_t p=r.sound+12+16*index;
        c.write32(p,r.allocate(8));c.write32(p+4,8);c.write32(p+8,index+1);c.write32(p+12,bits([entry[@"volume"] floatValue]));
        _buffers[@(index+1)]=[NSURL fileURLWithPath:[_resourcePath stringByAppendingPathComponent:entry[@"name"]]];
    }
    if(!c.fault.empty())return;
    r.game=r.allocate(24);if(!c.fault.empty())return;c.call(0x8dfb,{r.game});
    if(!c.fault.empty())return;
    // The modern preference wins over the legacy game's initial sound-OFF byte.
    c.write8(r.sound+1,_soundEnabled);
    #if TARGET_OS_IOS || TARGET_OS_WATCH
    // Extend the original Options table using its own font, layout, buttons, and animations.
    const uint32_t old=c.read32(0x14680);
    if(old!=0x148e0) {c.fail("Unsupported original Options table");return;}
    uint32_t table=r.allocate(12*60);
    memcpy(c.memory.data()+table,c.memory.data()+old,7*60);
    memcpy(c.memory.data()+table+10*60,c.memory.data()+old+7*60,2*60);
    const char *label="Respect Silent Mode";uint32_t text=r.allocate(uint32_t(strlen(label)+1));
    c.load(text,label,strlen(label)+1);
    for(unsigned i=0;i<3;++i) {
        uint32_t dest=table+(7+i)*60,source=old+(4+i)*60;
        memcpy(c.memory.data()+dest,c.memory.data()+source,60);
        // Derive the next section's position from the existing GameSpeed/Sound spacing.
        float section=real(c.read32(old+4*60))-real(c.read32(old));
        c.write32(dest,bits(real(c.read32(source))+section));
        if(i==0)c.write32(dest+36,text);
        else {c.write32(dest+40,(i==1?SilentOn:SilentOff)|1);c.write32(dest+44,(i==1?SilentOnDraw:SilentOffDraw)|1);}
    }
    c.write32(0x14680,table);
    #endif
}

- (BOOL)bridge:(uint32_t)pc {
    Runtime &r=*_runtime;GuestCPU &c=r.cpu;
    auto done=[&](uint32_t result=0)->BOOL {c.r[0]=result;c.returnFromHook();return YES;};
    if(pc==0x8e04) {[self setSoundEnabled:c.r[1]!=0];return done();}
    if(pc==0xea14) {_wantedMusicEntry=c.r[1];_wantedMusicLoop=c.r[2]!=0;return NO;}
    if(pc==0xe86e) {_wantedMusicEntry=-1;return NO;}
    if(pc==SilentOn||pc==SilentOff) {[self setRespectsSilentMode:pc==SilentOn];return done();}
    if(pc==SilentOnDraw||pc==SilentOffDraw) {
        bool selected=(pc==SilentOnDraw)==bool(_respectsSilentMode);
        uint32_t button=c.r[1],data=c.r[2];
        c.call(0x9b2f,{selected?0xff80c0ffu:0xff808080u,button,data});return done();
    }
    // Only obsolete file I/O is replaced; SaveData packing and validation execute in the guest.
    if(pc==0xa80c||pc==0xa8a0||pc==0xa958) {
        if(pc==0xa958) {r.release(c.r[0]);return done();}
        std::string name=r.string(c.r[0]);
        if(name!="savedata.dat") {c.fail("Unexpected guest save filename");return done();}
        NSString *file=[_savePath stringByAppendingPathComponent:@"savedata.dat"];
        if(pc==0xa8a0) {
            NSData *bytes=[NSData dataWithContentsOfFile:file];
            if(!bytes||bytes.length>4096) {c.write32(c.r[1],0);return done();}
            uint32_t p=r.allocate((uint32_t)bytes.length);c.load(p,bytes.bytes,bytes.length);c.write32(c.r[1],(uint32_t)bytes.length);return done(p);
        }
        if(!r.span(c.r[1],c.r[2])||c.r[2]>4096)return done();
        [NSFileManager.defaultManager createDirectoryAtPath:_savePath withIntermediateDirectories:YES attributes:nil error:nil];
        NSData *bytes=[NSData dataWithBytes:c.memory.data()+c.r[1] length:c.r[2]];
        return done([bytes writeToFile:file options:NSDataWritingAtomic error:nil]);
    }
    auto it=r.imports.find(pc);if(it==r.imports.end())return NO;
    const std::string &s=it->second;
    auto is=[&](const char *name) {return s==name;};
    if(is("__Znwm")||is("__Znam")||is("_malloc"))return done(r.allocate(c.r[0]));
    if(is("_calloc")) {uint64_t n=uint64_t(c.r[0])*c.r[1];return done(n>0x1600000?0:r.allocate((uint32_t)n));}
    if(is("__ZdlPv")||is("__ZdaPv")||is("_free")) {r.release(c.r[0]);return done();}
    if(is("_memcpy")||is("_memset")) {
        uint32_t dst=c.r[0],src=c.r[1],n=c.r[2];
        if(r.span(dst,n)) {if(is("_memset"))memset(c.memory.data()+dst,src&255,n);else if(r.span(src,n))memmove(c.memory.data()+dst,c.memory.data()+src,n);}
        return done(dst);
    }
    if(is("_strlen"))return done((uint32_t)r.string(c.r[0]).size());
    if(is("__ZNSt15_List_node_base4hookEPS_")) {
        uint32_t a=c.r[0],p=c.r[1],prev=c.read32(p+4);
        c.write32(a,p);c.write32(a+4,prev);c.write32(prev,a);c.write32(p+4,a);return done();
    }
    if(is("__ZNSt15_List_node_base6unhookEv")) {
        uint32_t a=c.r[0],next=c.read32(a),prev=c.read32(a+4);c.write32(next+4,prev);c.write32(prev,next);return done();
    }
    if(is("___cxa_guard_acquire"))return done(!c.read8(c.r[0]));
    if(is("___cxa_guard_release")) {c.write8(c.r[0],1);return done();}
    if(is("__Unwind_SjLj_Register")||is("__Unwind_SjLj_Unregister"))return done();
    if(is("_rand")) {r.seed=uint32_t(uint64_t(r.seed)*16807%2147483647);return done(r.seed);}
    float a=real(c.r[0]),b=real(c.r[1]);
    if(is("___addsf3vfp"))return done(bits(a+b));
    if(is("___subsf3vfp"))return done(bits(a-b));
    if(is("___mulsf3vfp"))return done(bits(a*b));
    if(is("___divsf3vfp"))return done(bits(a/b));
    if(is("___eqsf2vfp"))return done(a==b);
    if(is("___nesf2vfp"))return done(a!=b);
    if(is("___unordsf2vfp"))return done(std::isnan(a)||std::isnan(b));
    if(is("___gesf2vfp")||is("___gtsf2vfp")||is("___lesf2vfp")||is("___ltsf2vfp")) {
        // Apple's *vfp helpers return predicates, unlike generic libgcc's three-way comparisons.
        return done(is("___gesf2vfp")?a>=b:is("___gtsf2vfp")?a>b:is("___lesf2vfp")?a<=b:a<b);
    }
    if(is("___floatsisfvfp"))return done(bits(float(int32_t(c.r[0]))));
    if(is("___fixsfsivfp"))return done(std::isfinite(a)&&a>=-2147483648.f&&a<2147483648.f?uint32_t(int32_t(a)):0);
    if(is("___fixunssfsivfp"))return done(std::isfinite(a)&&a>=0&&double(a)<4294967296.?uint32_t(a):0);
    if(is("___extendsfdf2vfp")) {double d=a;uint64_t u;memcpy(&u,&d,8);c.r[1]=u>>32;return done(uint32_t(u));}
    if(is("___truncdfsf2vfp")||is("___fixdfsivfp")) {uint64_t u=uint64_t(c.r[0])|(uint64_t(c.r[1])<<32);double d;memcpy(&d,&u,8);return done(is("___truncdfsf2vfp")?bits(float(d)):(std::isfinite(d)&&d>=-2147483648.&&d<2147483648.?uint32_t(int32_t(d)):0));}
    if(is("_sinf"))return done(bits(std::sin(a)));if(is("_cosf"))return done(bits(std::cos(a)));
    if(is("_atanf"))return done(bits(std::atan(a)));if(is("_sqrtf"))return done(bits(std::sqrt(a)));
    if(is("_snprintf")) {
        std::string fmt=r.string(c.r[2]),out;unsigned ai=3;
        for(size_t i=0;i<fmt.size();++i) {
            if(fmt[i]!='%') {out+=fmt[i];continue;}
            size_t start=i++;if(i<fmt.size()&&fmt[i]=='%') {out+='%';continue;}
            while(i<fmt.size()&&strchr("0123456789.+- ",fmt[i]))++i;
            if(i>=fmt.size())break;
            std::string spec=fmt.substr(start,i-start+1);char buf[128];
            if(fmt[i]=='d'||fmt[i]=='i')snprintf(buf,sizeof(buf),spec.c_str(),int32_t(r.arg(ai++)));
            else if(fmt[i]=='u'||fmt[i]=='x'||fmt[i]=='X')snprintf(buf,sizeof(buf),spec.c_str(),r.arg(ai++));
            else {c.fail("Unsupported guest printf format");break;}
            out+=buf;
        }
        uint32_t n=c.r[1],p=c.r[0];if(n&&r.span(p,n)) {size_t len=std::min(size_t(n-1),out.size());memcpy(c.memory.data()+p,out.data(),len);c.write8(p+(uint32_t)len,0);}return done((uint32_t)out.size());
    }
    if(s.rfind("_gl",0)==0) {
        if(is("_glPushMatrix"))r.stack.push_back(r.matrix);
        else if(is("_glPopMatrix")) {if(r.stack.empty())c.fail("GL matrix stack underflow");else {r.matrix=r.stack.back();r.stack.pop_back();}}
        else if(is("_glLoadIdentity"))r.matrix=Matrix();
        else if(is("_glTranslatef"))r.matrix=r.matrix*Matrix::translation(a,b,r.farg(2));
        else if(is("_glScalef"))r.matrix=r.matrix*Matrix::scale(a,b,r.farg(2));
        else if(is("_glRotatef"))r.matrix=r.matrix*Matrix::rotation(a,b,r.farg(2),r.farg(3));
        else if(is("_glBindTexture"))r.texture=c.r[1];
        else if(is("_glEnable")||is("_glDisable")) {if(c.r[0]==0xde1)r.textured=is("_glEnable");if(c.r[0]==0xbe2)r.blend=is("_glEnable");}
        else if(is("_glEnableClientState")||is("_glDisableClientState")) {if(c.r[0]==0x8076)r.colorArray=is("_glEnableClientState");}
        else if(is("_glBlendFunc")) {r.sourceBlend=c.r[0];r.destBlend=c.r[1];}
        else if(is("_glColor4f"))for(int i=0;i<4;++i)r.color[i]=r.farg(i);
        else if(is("_glColor4ub"))for(int i=0;i<4;++i)r.color[i]=(r.arg(i)&255)/255.f;
        else if(is("_glVertexPointer"))r.vertices={c.r[3],c.r[1],c.r[0],c.r[2]};
        else if(is("_glTexCoordPointer"))r.uvs={c.r[3],c.r[1],c.r[0],c.r[2]};
        else if(is("_glColorPointer"))r.colors={c.r[3],c.r[1],c.r[0],c.r[2]};
        else if(is("_glDrawArrays"))r.draw(c.r[0],c.r[1],c.r[2]);
        else if(is("_glTexEnvi")&&c.r[1]==0x2200)r.textureEnv=c.r[2];
        else if(!(is("_glTexEnvi")||is("_glTexParameteri")||is("_glMatrixMode")))c.fail("Unbridged graphics call: "+s);
        return done();
    }
    if(s.rfind("_al",0)==0) {
        NSNumber *source=@(c.r[0]);
        if(is("_alGetError"))return done();
        if(is("_alcOpenDevice")||is("_alcCreateContext")||is("_alcMakeContextCurrent"))return done(1);
        if(is("_alcGetProcAddress"))return done();
        if(is("_alGenSources")) {for(unsigned i=0;i<c.r[0];++i)c.write32(c.r[1]+4*i,r.nextSource++);}
        else if(is("_alSourcei")) {if(c.r[1]==0x1009)_sourceBuffers[source]=@(c.r[2]);else if(c.r[1]==0x1007)_sourceLoops[source]=@(c.r[2]);}
        else if(is("_alSourcef")&&c.r[1]==0x100a) {_sourceGains[source]=@(real(c.r[2]));_players[source].volume=_muted?0:real(c.r[2]);}
        else if(is("_alSourcePlay")) {
            ++r.audioEvents;NSURL *url=_buffers[_sourceBuffers[source]];
            if(url) {NSError *error=nil;AVAudioPlayer *player=[[AVAudioPlayer alloc] initWithContentsOfURL:url error:&error];
                if(player) {player.numberOfLoops=[_sourceLoops[source] boolValue]?-1:0;player.volume=_muted?0:(_sourceGains[source]?[_sourceGains[source] floatValue]:1);_players[source]=player;if(!_suspended&&_soundEnabled)[player play];}
                else c.fail(std::string("Audio could not decode original WAV: ")+error.localizedDescription.UTF8String);
            }
        } else if(is("_alSourceStop")) {[_players[source] stop];[_players removeObjectForKey:source];}
        else if(!(is("_alListener3f")||is("_alcCloseDevice")||is("_alcDestroyContext")||is("_alDeleteSources")))c.fail("Unbridged audio call: "+s);
        return done();
    }
    c.fail("Unbridged original API: "+s);return done();
}

- (void)update:(double)delta {
    if(_failure||_suspended)return;
    Runtime &r=*_runtime;
    if(delta>0)r.cpu.call(0x8af3,{r.game,bits(1.f/60.f)});
    [self checkFault];if(_failure)return;
    std::fill(r.pixels.begin(),r.pixels.end(),0);r.matrix=Matrix();r.stack.clear();r.colorArray=false;
    r.cpu.call(0x8b23,{r.game});[self checkFault];if(_failure)return;
    for(size_t p=3;p<r.pixels.size();p+=4)r.pixels[p]=255;
    CFDataRef bytes=CFDataCreate(nullptr,r.pixels.data(),r.pixels.size());
    CGDataProviderRef provider=CGDataProviderCreateWithCFData(bytes);CFRelease(bytes);
    CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();
    CGImageRef next=CGImageCreate(Width,Height,8,32,Width*4,space,kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big,provider,nullptr,false,kCGRenderingIntentDefault);
    CGColorSpaceRelease(space);CGDataProviderRelease(provider);
    if(_frame)CGImageRelease(_frame);_frame=next;++r.frames;
}
- (void)touchPhase:(NSInteger)phase x:(double)x y:(double)y {
    if(_failure||_suspended)return;Runtime &r=*_runtime;
    float gx=float(y)-160,gy=float(x)-240;
    if(phase==0) {r.touching=true;r.cpu.call(0x8b3d,{r.game,bits(gx),bits(gy)});}
    else if(phase==1&&r.touching)r.cpu.call(0x8b77,{r.game,bits(gx),bits(gy),bits(r.lastX),bits(r.lastY)});
    else if(phase==2&&r.touching) {r.cpu.call(0x8bdb,{r.game,bits(gx),bits(gy)});r.touching=false;}
    else if(phase==3&&r.touching) {r.cpu.call(0x8c15,{r.game});r.touching=false;}
    r.lastX=gx;r.lastY=gy;[self checkFault];
}
- (void)setSuspended:(BOOL)suspended {
    if(suspended==_suspended)return;
    if(suspended) {
        [self touchPhase:3 x:0 y:0];
        [_pausedSources removeAllObjects];
        for(NSNumber *source in _players)if(_players[source].isPlaying) {[_pausedSources addObject:source];[_players[source] pause];}
        if(!_failure) {_runtime->cpu.call(0x8e13,{_runtime->game});[self checkFault];}
    } else {
        _suspended=NO;
        if(_soundEnabled) {
            for(NSNumber *source in _pausedSources)[_players[source] play];
            NSNumber *music=@(_runtime->cpu.read32(_runtime->sound+0xec));
            if(_wantedMusicEntry>=0&&!_players[music])_runtime->cpu.call(0xea15,{_runtime->sound,uint32_t(_wantedMusicEntry),uint32_t(_wantedMusicLoop)});
        }
        [_pausedSources removeAllObjects];
    }
    _suspended=suspended;[self checkFault];
}
@end
