// Created by Angelo Cammalleri on 25.10.2026.
#import "SDBEngine.h"
#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>
#import <CommonCrypto/CommonDigest.h>
#import <TargetConditionals.h>
#include "GuestCPU.h"
#include "DisplayGeometry.h"
#include "GameDisplayPatch.h"
#include "TextDistanceField.h"
#import "SDBMetalRenderer.h"
#import "SDBAudioMixer.h"
#import "SDBSaveStore.h"
#include <algorithm>
#include <cmath>
#include <cstring>
#include <cstdlib>
#include <map>
#include <memory>
#include <sstream>
#include <string_view>
#include <vector>

namespace {
constexpr uint32_t ExtendedTitle = 1000;
constexpr uint32_t OriginalFont = 1, OriginalSmallFont = 2;
using sdb::display::DisplayGeometry;
constexpr uint32_t SilentOn=0x01d00000,SilentOff=0x01d00004,SilentOnDraw=0x01d00008,SilentOffDraw=0x01d0000c;
constexpr uint32_t HapticsOn=0x01d00010,HapticsOff=0x01d00014,HapticsOnDraw=0x01d00018,HapticsOffDraw=0x01d0001c;
constexpr NSUInteger HapticRelease=1,HapticTarget=2,HapticDamage=4,HapticMenu=8,HapticExplosion=16,HapticPrimary=32;
uint32_t bits(float f) { uint32_t u; memcpy(&u,&f,4); return u; }
float real(uint32_t u) { float f; memcpy(&f,&u,4); return f; }
struct Texture { int width=0,height=0,contentWidth=0,contentHeight=0; uint32_t distanceField=0,glyphAtlas=0; std::vector<uint8_t> pixels; };
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
    sdb::display::GameDisplayPatch displayPatch;
    DisplayGeometry geometry=DisplayGeometry::make({480,320},1);
    bool metal=false, titleDrawn=false;
    std::vector<SDBMetalVertex> metalVertices;
    std::vector<SDBMetalDraw> metalDraws;
    bool collectSoftwareDraws=false, softwareMenuCaching=true, menuPacketValid=false, softwarePacketFallback=false;
    uint64_t textureGeneration=0, menuTextureGeneration=0;
    uint32_t menuRasterWidth=0, menuRasterHeight=0, menuType=0;
    double menuPixelScale=0;
    std::vector<SDBMetalVertex> menuVertices;
    std::vector<SDBMetalDraw> menuDraws;
    static constexpr size_t MaximumMenuPacketBytes=1024*1024;
    // draw() validates the 4,096-vertex limit before growing this scratch space.
    // Keep its capacity between draws instead of allocating for every sprite.
    std::vector<Vertex> drawVertices;
    uint32_t game=0,sound=0,heap=0x20000,seed=1,nextSource=1;
    std::map<uint32_t,uint32_t> allocations;
    std::multimap<uint32_t,uint32_t> freeBlocks;
    std::map<uint32_t,std::string> imports;
    std::map<uint32_t,Texture> textures;
    std::vector<uint8_t> pixels = std::vector<uint8_t>(480*320*4);
    Matrix matrix;
    std::vector<Matrix> stack;
    Array vertices,uvs,colors;
    bool textured=false,colorArray=false,blend=false;
    uint32_t texture=0,sourceBlend=0x302,destBlend=0x303,textureEnv=0x1e01;
    float color[4]={1,1,1,1};
    uint64_t frames=0,draws=0,audioEvents=0;
    float lastX=0,lastY=0;
    bool touching=false,watchLayout=TARGET_OS_WATCH,steeringActive=false;
    double steeringY=.5;

    void invalidateMenuPacket() {menuPacketValid=false;menuVertices.clear();menuDraws.clear();}
    bool sameMenuPacket(uint32_t type) const {
        return menuPacketValid&&menuType==type&&menuTextureGeneration==textureGeneration&&
            menuRasterWidth==geometry.rasterWidth&&menuRasterHeight==geometry.rasterHeight&&
            menuPixelScale==geometry.pixelsPerLogicalUnit&&menuVertices.size()==metalVertices.size()&&
            menuDraws.size()==metalDraws.size()&&
            (menuVertices.empty()||memcmp(menuVertices.data(),metalVertices.data(),menuVertices.size()*sizeof(SDBMetalVertex))==0)&&
            (menuDraws.empty()||memcmp(menuDraws.data(),metalDraws.data(),menuDraws.size()*sizeof(SDBMetalDraw))==0);
    }
    void rememberMenuPacket(uint32_t type) {
        // Bound retained metadata independently of the image's pixel budget.
        if(metalVertices.size()>MaximumMenuPacketBytes/sizeof(SDBMetalVertex)||
           metalDraws.size()>MaximumMenuPacketBytes/sizeof(SDBMetalDraw)||
           metalVertices.size()*sizeof(SDBMetalVertex)+metalDraws.size()*sizeof(SDBMetalDraw)>MaximumMenuPacketBytes) {
            invalidateMenuPacket();return;
        }
        menuVertices=metalVertices;menuDraws=metalDraws;
        menuType=type;menuTextureGeneration=textureGeneration;
        menuRasterWidth=geometry.rasterWidth;menuRasterHeight=geometry.rasterHeight;
        menuPixelScale=geometry.pixelsPerLogicalUnit;menuPacketValid=true;
    }

    uint32_t gameObject() { return game?cpu.read32(game+0xc):0; }
    uint32_t ship() {uint32_t g=gameObject();return g?cpu.read32(g+0x4c):0;}
    uint32_t marker() {uint32_t g=gameObject();return g?cpu.read32(g+0x50):0;}
    double shipTravelLimit(uint32_t player) {
        double radius=real(cpu.read32(player+0xd4));
        return std::isfinite(radius)&&radius>=0?std::max(0.,geometry.logicalSize.height/2-radius):0;
    }
    bool upsideDown() {
        uint32_t camera=game?cpu.read32(game):0;
        return camera&&real(cpu.read32(camera+0x2c))<real(cpu.read32(0x8f7c));
    }

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
        Vertex p={float(geometry.logicalSize.width/2)+my,float(geometry.logicalSize.height/2)+mx,component(uvs,i,0),component(uvs,i,1),color[0],color[1],color[2],color[3]};
        if(colorArray) {p.r=component(colors,i,0);p.g=component(colors,i,1);p.b=component(colors,i,2);p.a=component(colors,i,3);}
        return p;
    }
    static float edge(const Vertex &a,const Vertex &b,float x,float y) {return (x-a.x)*(b.y-a.y)-(y-a.y)*(b.x-a.x);}
    void triangle(Vertex a,Vertex b,Vertex c) {
        if(metal||collectSoftwareDraws) {
            metalVertices.push_back({a.x,a.y,a.u,a.v,a.r,a.g,a.b,a.a});
            metalVertices.push_back({b.x,b.y,b.u,b.v,b.r,b.g,b.b,b.a});
            metalVertices.push_back({c.x,c.y,c.u,c.v,c.r,c.g,c.b,c.a});
            return;
        }
        const float scale=float(geometry.pixelsPerLogicalUnit);
        for(Vertex *p:{&a,&b,&c}) {p->x*=scale;p->y*=scale;}
        const int Width=int(geometry.rasterWidth), Height=int(geometry.rasterHeight);
        const float area=edge(a,b,c.x,c.y);
        if(!std::isfinite(area)||std::abs(area)<0.00001f)return;
        if(area<0) {std::swap(b,c);}
        const float inv=1/std::abs(area);
        int x0=std::max(0,int(std::floor(std::min({a.x,b.x,c.x})))),x1=std::min(Width-1,int(std::ceil(std::max({a.x,b.x,c.x}))));
        int y0=std::max(0,int(std::floor(std::min({a.y,b.y,c.y})))),y1=std::min(Height-1,int(std::ceil(std::max({a.y,b.y,c.y}))));
        auto ti=textures.find(texture);const Texture *t=textured&&ti!=textures.end()?&ti->second:nullptr;
        const bool replace=t&&textureEnv==0x1e01;
        #if defined(__clang__)
        typedef uint8_t Byte4 __attribute__((ext_vector_type(4)));
        typedef float Float4 __attribute__((ext_vector_type(4)));
        #endif
        const bool glyphAtlas=t&&t->glyphAtlas&&!t->distanceField&&t->width>=16&&t->height>=8;
        float glyphMinU=0,glyphMinV=0,glyphMaxU=1,glyphMaxV=1;
        if(glyphAtlas) {
            // The original Font::print emits one 16x8 ASCII cell per glyph.
            // Infer it from the triangle, not a fragment exactly on a UV edge.
            const float centerU=(std::min({a.u,b.u,c.u})+std::max({a.u,b.u,c.u}))*.5f;
            const float centerV=(std::min({a.v,b.v,c.v})+std::max({a.v,b.v,c.v}))*.5f;
            const float column=std::clamp(std::floor(centerU*16),0.f,15.f);
            const float row=std::clamp(std::floor(centerV*8),0.f,7.f);
            glyphMinU=column/16+.5f/t->width;glyphMaxU=(column+1)/16-.5f/t->width;
            glyphMinV=row/8+.5f/t->height;glyphMaxV=(row+1)/8-.5f/t->height;
        }
        // Reconstruct bitmap glyph coverage at the final pixel density. The
        // atlas contour stays at 0.5; neighboring pixels match Metal's fwidth.
        float dux=0,duy=0,dvx=0,dvy=0;
        if(t&&t->distanceField) {
            // edge() has the opposite sign from the conventional determinant.
            // The reordered triangle has positive edge area, hence -inv here.
            const float inverseDeterminant=-inv;
            dux=((b.u-a.u)*(c.y-a.y)-(c.u-a.u)*(b.y-a.y))*inverseDeterminant;
            duy=((c.u-a.u)*(b.x-a.x)-(b.u-a.u)*(c.x-a.x))*inverseDeterminant;
            dvx=((b.v-a.v)*(c.y-a.y)-(c.v-a.v)*(b.y-a.y))*inverseDeterminant;
            dvy=((c.v-a.v)*(b.x-a.x)-(b.v-a.v)*(c.x-a.x))*inverseDeterminant;
        }
        auto topLeft=[](const Vertex&p,const Vertex&q) {float dy=q.y-p.y,dx=q.x-p.x;return dy<0||(dy==0&&dx>0);};
        for(int y=y0;y<=y1;++y)for(int x=x0;x<=x1;++x) {
            float ea=edge(b,c,x+.5f,y+.5f),eb=edge(c,a,x+.5f,y+.5f),ec=edge(a,b,x+.5f,y+.5f);
            if(ea<0||eb<0||ec<0||(ea==0&&!topLeft(b,c))||(eb==0&&!topLeft(c,a))||(ec==0&&!topLeft(a,b)))continue;
            float wa=ea*inv,wb=eb*inv,wc=ec*inv;
            #if defined(__clang__)
            // Keep channels in registers. Resetting a local float array in the
            // REPLACE path otherwise generates a pattern-fill call per pixel.
            Float4 rgba=replace?Float4{1,1,1,1}:Float4{
                wa*a.r+wb*b.r+wc*c.r,wa*a.g+wb*b.g+wc*c.g,
                wa*a.b+wb*b.b+wc*c.b,wa*a.a+wb*b.a+wc*c.a};
            #else
            float rgba[4]={wa*a.r+wb*b.r+wc*c.r,wa*a.g+wb*b.g+wc*c.g,wa*a.b+wb*b.b+wc*c.b,wa*a.a+wb*b.a+wc*c.a};
            if(replace)for(float &channel:rgba)channel=1;
            #endif
            if(t) {
                float u=wa*a.u+wb*b.u+wc*c.u,v=wa*a.v+wb*b.v+wc*c.v;
                if(glyphAtlas) {u=std::clamp(u,glyphMinU,glyphMaxU);v=std::clamp(v,glyphMinV,glyphMaxV);}
                // GL_LINEAR, clamped to the padded original texture.
                const float sampleX=u*t->width-.5f,sampleY=v*t->height-.5f;
                float tx=std::clamp(sampleX,0.f,float(t->width-1)),ty=std::clamp(sampleY,0.f,float(t->height-1));
                int ix=int(tx),iy=int(ty),jx=std::min(ix+1,t->width-1),jy=std::min(iy+1,t->height-1);
                float fx=tx-ix,fy=ty-iy;
                auto sample=[&](int sx,int sy,int ch) {return t->pixels[4*(sy*t->width+sx)+ch]/255.f;};
                // Interpolate the four channels together; the weights and
                // sample order remain the original GL_LINEAR calculation.
                #if defined(__clang__)
                auto rgbaAt=[&](int sx,int sy) {
                    Byte4 bytes;memcpy(&bytes,t->pixels.data()+4*(sy*t->width+sx),4);
                    return __builtin_convertvector(bytes,Float4)/255.f;
                };
                Float4 texel=(1-fy)*((1-fx)*rgbaAt(ix,iy)+fx*rgbaAt(jx,iy))+
                    fy*((1-fx)*rgbaAt(ix,jy)+fx*rgbaAt(jx,jy));
                #else
                float texel[4];
                for(int ch=0;ch<4;++ch)
                    texel[ch]=(1-fy)*((1-fx)*sample(ix,iy,ch)+fx*sample(jx,iy,ch))+
                        fy*((1-fx)*sample(ix,jy,ch)+fx*sample(jx,jy,ch));
                #endif
                if(t->distanceField) {
                        float value=texel[3];
                        auto alphaAtUV=[&](float su,float sv) {
                            float sx=std::clamp(su*t->width-.5f,0.f,float(t->width-1));
                            float sy=std::clamp(sv*t->height-.5f,0.f,float(t->height-1));
                            int x0=int(sx),y0=int(sy),x1=std::min(x0+1,t->width-1),y1=std::min(y0+1,t->height-1);
                            float fx=sx-x0,fy=sy-y0;
                            return (1-fy)*((1-fx)*sample(x0,y0,3)+fx*sample(x1,y0,3))+
                                fy*((1-fx)*sample(x0,y1,3)+fx*sample(x1,y1,3));
                        };
                        // Fragment derivatives use horizontal and vertical
                        // pairs in a 2x2 pixel quad, including helper pixels
                        // outside this triangle. A local analytic derivative
                        // differs at curved glyph edges and texel boundaries.
                        const float dx=(x&1)?-1.f:1.f,dy=(y&1)?-1.f:1.f;
                        const float coverageWidth=std::max(.0001f,
                            std::abs(alphaAtUV(u+dx*dux,v+dx*dvx)-value)+
                            std::abs(alphaAtUV(u+dy*duy,v+dy*dvy)-value));
                        value=std::clamp((value-.5f)/coverageWidth+.5f,0.f,1.f);
                        value=value*value*(3-2*value);
                        if(t->distanceField==2) {
                            const float alpha=value+texel[0]*(1-value);
                            const float gray=alpha>0?(238.f/255)*value/alpha:0;
                            texel[0]=texel[1]=texel[2]=gray;
                            texel[3]=alpha;
                        } else texel[3]=value;
                }
                #if defined(__clang__)
                rgba*=texel;
                #else
                for(int ch=0;ch<4;++ch)rgba[ch]*=texel[ch];
                #endif
            }
            unsigned p=4*(y*Width+x);
            auto factor=[&](uint32_t f) {switch(f){case 0:return 0.f;case 1:return 1.f;case 0x302:return rgba[3];case 0x303:return 1-rgba[3];default:cpu.fail("Unsupported GL blend factor");return 0.f;}};
            float sf=blend?factor(sourceBlend):1,df=blend?factor(destBlend):0;
            for(int ch=0;ch<3;++ch)pixels[p+ch]=uint8_t(std::clamp(rgba[ch]*sf*255+pixels[p+ch]*df,0.f,255.f));
            pixels[p+3]=255;
        }
    }
    void emit(const Vertex *points,unsigned count,uint32_t mode) {
        uint32_t first=uint32_t(metalVertices.size());
        if(mode==5)for(unsigned i=2;i<count;++i)triangle(points[i-2],points[i-1],points[i]);
        else if(mode==4)for(unsigned i=2;i<count;i+=3)triangle(points[i-2],points[i-1],points[i]);
        else if(mode==6)for(unsigned i=2;i<count;++i)triangle(points[0],points[i-1],points[i]);
        else cpu.fail("Unsupported GL primitive mode");
        if((metal||collectSoftwareDraws)&&metalVertices.size()>first) {
            auto t=textures.find(texture);
            metalDraws.push_back({first,uint32_t(metalVertices.size()-first),texture,uint32_t(textured),textureEnv,
                uint32_t(blend),sourceBlend,destBlend,0,t!=textures.end()?t->second.distanceField:0,
                t!=textures.end()?t->second.glyphAtlas:0});
        }
    }
    void rasterizeSoftwarePacket() {
        const uint32_t savedTexture=texture,savedEnv=textureEnv,savedSource=sourceBlend,savedDestination=destBlend;
        const bool savedTextured=textured,savedBlend=blend;
        collectSoftwareDraws=false;
        for(const auto &draw:metalDraws) {
            if(draw.firstVertex>metalVertices.size()||draw.vertexCount>metalVertices.size()-draw.firstVertex||draw.vertexCount%3) {
                cpu.fail("Invalid collected software triangle range");break;
            }
            texture=draw.textureID;textured=draw.textured;textureEnv=draw.textureEnv;
            blend=draw.blend;sourceBlend=draw.sourceBlend;destBlend=draw.destBlend;
            const auto vertex=[](const SDBMetalVertex&p) {return Vertex{p.x,p.y,p.u,p.v,p.r,p.g,p.b,p.a};};
            for(uint32_t index=0;index<draw.vertexCount;index+=3) {
                const auto *p=metalVertices.data()+draw.firstVertex+index;
                triangle(vertex(p[0]),vertex(p[1]),vertex(p[2]));
            }
        }
        texture=savedTexture;textured=savedTextured;textureEnv=savedEnv;
        blend=savedBlend;sourceBlend=savedSource;destBlend=savedDestination;
    }
    void draw(uint32_t mode,unsigned first,unsigned count) {
        if(count>4096) {cpu.fail("GL draw count exceeds limit");return;}
        ++draws;
        if((TARGET_OS_IOS||watchLayout)&&textured&&texture==12)return; // Native pause control owns this affordance.
        const auto validFactor=[](uint32_t factor) {return factor==0||factor==1||factor==0x302||factor==0x303;};
        if(collectSoftwareDraws&&blend&&(!validFactor(sourceBlend)||!validFactor(destBlend))) {
            // Preserve the original fault boundary: invalid factors only fault
            // when a covered pixel uses them, before guest execution continues.
            std::fill(pixels.begin(),pixels.end(),0);
            rasterizeSoftwarePacket();metalVertices.clear();metalDraws.clear();
            softwarePacketFallback=true;invalidateMenuPacket();
        }
        auto &points=drawVertices;points.clear();points.reserve(count);
        for(unsigned i=0;i<count;++i)points.push_back(vertex(first+i));
        if(textured&&texture==3&&!titleDrawn&&textures.count(ExtendedTitle)) {
            titleDrawn=true;
            // The extended sky sits behind the untouched central title quad.
            // It uses the same tint and fade as the original artwork.
            const uint32_t original=texture;texture=ExtendedTitle;
            const Texture &t=textures.at(texture);
            const float w=float(geometry.logicalSize.width),h=float(geometry.logicalSize.height);
            const float artScale=std::max({1.f,w/960.f,h/640.f});
            const float aw=960*artScale,ah=640*artScale;
            float u0=(.5f-w/(2*aw))*t.contentWidth/t.width,u1=(.5f+w/(2*aw))*t.contentWidth/t.width;
            float v0=(.5f-h/(2*ah))*t.contentHeight/t.height,v1=(.5f+h/(2*ah))*t.contentHeight/t.height;
            Vertex tint=points.empty()?Vertex{0,0,0,0,1,1,1,1}:points.front();
            std::array<Vertex,4> sky={tint,tint,tint,tint};
            sky[0].x=0;sky[0].y=0;sky[0].u=u0;sky[0].v=v0;
            sky[1].x=w;sky[1].y=0;sky[1].u=u1;sky[1].v=v0;
            sky[2].x=0;sky[2].y=h;sky[2].u=u0;sky[2].v=v1;
            sky[3].x=w;sky[3].y=h;sky[3].u=u1;sky[3].v=v1;
            emit(sky.data(),unsigned(sky.size()),5);texture=original;
        }
        // Cover the taller arena with one uniformly scaled background band;
        // vertical repetition would introduce a visible sky/cloud restart.
        // BGLayer's push at 0x59aa saves the camera before its local translate
        // and scale. Scaling about that camera-transformed world corner is
        // exactly a uniform guest XY scale before the original camera, including
        // its rotation and zoom, rather than a stretch along screen axes.
        if(textured&&texture>=38&&texture<=45&&geometry.logicalSize.height>320) {
            if(stack.empty()) {cpu.fail("Background draw lacks its original camera matrix");return;}
            const Matrix &camera=stack.back();
            const float halfWidth=float(geometry.logicalSize.width/2),halfHeight=float(geometry.logicalSize.height/2);
            const float anchorX=halfWidth-camera.m[1]*halfHeight-camera.m[5]*halfWidth+camera.m[13];
            const float anchorY=halfHeight-camera.m[0]*halfHeight-camera.m[4]*halfWidth+camera.m[12];
            const float cover=float(geometry.logicalSize.height/320);
            for(auto &p:points) {
                p.x=anchorX+cover*(p.x-anchorX);
                p.y=anchorY+cover*(p.y-anchorY);
            }
        }
        emit(points.data(),unsigned(points.size()),mode);
    }
};
}

@interface SDBMenuAction ()
@property(nonatomic) uint32_t guestButton;
- (instancetype)initWithIdentifier:(NSString *)identifier label:(NSString *)label frame:(CGRect)frame selected:(BOOL)selected button:(uint32_t)button;
@end
@implementation SDBMenuAction
- (instancetype)initWithIdentifier:(NSString *)identifier label:(NSString *)label frame:(CGRect)frame selected:(BOOL)selected button:(uint32_t)button {
    if ((self = [super init])) {_identifier = [identifier copy]; _label = [label copy]; _logicalFrame = frame; _selected = selected; _guestButton = button;}
    return self;
}
@end

@implementation SDBEngine {
    std::unique_ptr<Runtime> _runtime;
    SDBMetalRenderer *_metalRenderer;
    NSString *_menuVersion;
    NSString *_resourcePath;
    NSString *_savePath;
    NSString *_failure;
    CGImageRef _frame;
    SDBAudioMixer *_audioMixer;
    NSMutableDictionary<NSNumber*,SDBAudioVoice*> *_players;
    NSMutableDictionary<NSNumber*,NSNumber*> *_sourceBuffers;
    NSMutableDictionary<NSNumber*,NSNumber*> *_sourceLoops;
    NSMutableDictionary<NSNumber*,NSNumber*> *_sourceGains;
    NSMutableSet<NSNumber*> *_pausedSources;
    BOOL _muted;
    BOOL _suspended;
    BOOL _audioSuspended;
    BOOL _soundEnabled;
    BOOL _respectsSilentMode;
    BOOL _offersHaptics;
    BOOL _hapticsEnabled;
    NSUInteger _pendingHapticEvents;
    NSString *_testPreferencesPath;
    NSMutableDictionary *_testPreferences;
    NSString *_audioSessionError;
    NSString *_audioPolicyError;
    NSInteger _wantedMusicEntry;
    BOOL _wantedMusicLoop;
    SDBSaveCoordinator *_saveStore;
    NSString *_progressError;
    BOOL _captureSaveOnly;
    NSData *_capturedSaveData;
    uint64_t _menuGeneration;
}

- (CGImageRef)frame {
    if(_runtime->metal&&!_frame)_frame=[_metalRenderer copyCurrentFrame];
    return _frame;
}
- (CGSize)logicalSize {auto s=_runtime->geometry.logicalSize;return CGSizeMake(s.width,s.height);}
- (CGSize)rasterSize {auto &g=_runtime->geometry;return CGSizeMake(g.rasterWidth,g.rasterHeight);}
- (CGSize)rasterViewSize {auto s=_runtime->geometry.rasterViewSize();return CGSizeMake(s.width,s.height);}
- (BOOL)usesMetalRenderer {return _runtime->metal;}
- (NSString *)menuVersion {return _menuVersion;}
- (NSInteger)gameMenuType {auto &r=*_runtime;return r.game?r.cpu.read32(r.cpu.read32(r.game+4)+0x20):-1;}
- (NSArray<SDBMenuAction *> *)menuActions {
    if (_failure || _suspended || !_runtime->game || self.gameMenuType < 1 || self.gameMenuType > 6) return @[];
    Runtime &r = *_runtime; GuestCPU &c = r.cpu;
    const uint32_t menu = c.read32(r.game + 4), sentinel = menu + 0x24;
    uint32_t node = c.read32(sentinel);
    NSMutableArray<SDBMenuAction *> *actions = [NSMutableArray array];
    for (unsigned count = 0; node != sentinel && count < 64; ++count) {
        auto allocation = r.allocations.find(node);
        if (allocation == r.allocations.end() || allocation->second < 12) return @[];
        const uint32_t button = c.read32(node + 8);
        auto item = r.allocations.find(button);
        if (item == r.allocations.end() || item->second < 80) return @[];
        const uint32_t data = c.read32(button);
        if (data > c.memory.size() - 60) return @[];
        const uint32_t callback = c.read32(data + 40) & ~1u;
        if (callback && (c.read32(button + 0x48) != 1 || c.read8(button + 0x44))) return @[];
        NSString *label = nil, *kind = nil; BOOL selected = NO;
        switch (callback) {
            case 0x9ab2: label = @"Game Start"; kind = @"start"; break;
            case 0x9acc: case 0x9a78: label = @"Continue"; kind = @"continue"; break;
            case 0x9a36: label = @"Resume"; kind = @"resume"; break;
            case 0x9a54: case 0x9a98: label = @"Quit"; kind = @"quit"; break;
            case 0x9ae6: label = @"Options"; kind = @"options"; break;
            case 0x9afa: label = @"Credits"; kind = @"credits"; break;
            case 0x9a04: label = @"Back"; kind = @"back"; break;
            case 0x9a18: label = @"Save and Exit"; kind = @"save-exit"; break;
            case 0x9394: label = @"Sound On"; kind = @"sound-on"; selected = _soundEnabled; break;
            case 0x93a4: label = @"Sound Off"; kind = @"sound-off"; selected = !_soundEnabled; break;
            case 0x93c6: label = @"Game Speed Normal"; kind = @"speed-normal"; selected = c.read32(r.game + 20) == c.read32(0x93d4); break;
            case 0x93d8: label = @"Game Speed Slow"; kind = @"speed-slow"; selected = c.read32(r.game + 20) == c.read32(0x93e8); break;
            case 0x9380: label = @"Game Speed Very Slow"; kind = @"speed-very-slow"; selected = c.read32(r.game + 20) == c.read32(0x9390); break;
            case SilentOn: label = @"Respect Silent Mode On"; kind = @"silent-on"; selected = _respectsSilentMode; break;
            case SilentOff: label = @"Respect Silent Mode Off"; kind = @"silent-off"; selected = !_respectsSilentMode; break;
            case HapticsOn: label = @"Haptics On"; kind = @"haptics-on"; selected = _hapticsEnabled; break;
            case HapticsOff: label = @"Haptics Off"; kind = @"haptics-off"; selected = !_hapticsEnabled; break;
            default: break;
        }
        if (label) {
            const double x = real(c.read32(button + 0x10)), y = real(c.read32(button + 0x1c));
            const double w = real(c.read32(button + 0x28)), h = real(c.read32(button + 0x34));
            if (!std::isfinite(x) || !std::isfinite(y) || !std::isfinite(w) || !std::isfinite(h) || w <= 0 || h <= 0) return @[];
            CGRect frame = CGRectMake(r.geometry.logicalSize.width / 2 + y - h / 2,
                r.geometry.logicalSize.height / 2 + x - w / 2, h, w);
            const CGRect bounds = CGRectMake(0, 0, r.geometry.logicalSize.width, r.geometry.logicalSize.height);
            if (CGRectIntersectsRect(frame, bounds)) {
                NSString *identity = [NSString stringWithFormat:@"%@-%llu-%08x-%08x", kind,
                    (unsigned long long)_menuGeneration, button, data];
                [actions addObject:[[SDBMenuAction alloc] initWithIdentifier:identity label:label frame:frame selected:selected button:button]];
            }
        }
        node = c.read32(node);
    }
    return node == sentinel && c.fault.empty() ? actions : @[];
}
- (BOOL)activateMenuAction:(NSString *)identifier {
    if (_failure || _suspended || _runtime->touching || !identifier.length) return NO;
    SDBMenuAction *action = nil;
    for (SDBMenuAction *candidate in self.menuActions) if ([candidate.identifier isEqual:identifier]) {action = candidate; break;}
    if (!action) return NO;
    Runtime &r = *_runtime; GuestCPU &c = r.cpu;
    const uint32_t menu = c.read32(r.game + 4), sentinel = menu + 0x24;
    const uint32_t button = action.guestButton;
    const uint32_t x = c.read32(button + 0x10), y = c.read32(button + 0x1c);
    // Match the original first-hit traversal, including animated overlapping
    // bounds. An accessibility action may never select a different row.
    uint32_t node = c.read32(sentinel), hit = 0;
    for (unsigned count = 0; node != sentinel && count < 64; ++count) {
        const uint32_t candidate = c.read32(node + 8);
        if (c.call(0xa0a1, {candidate}) && c.call(0xa115, {candidate, x, y})) {hit = candidate; break;}
        node = c.read32(node);
    }
    [self checkFault]; if (_failure || hit != button) return NO;
    [self cancelShipSteering];
    c.call(0x94fd, {menu, x, y});
    c.call(0x93ed, {menu, x, y});
    [self checkFault];
    return !_failure && (c.read8(button + 0x44) || c.read32(button + 0x48) == 2);
}
- (NSString *)lastSaveError {return _progressError ?: _saveStore.lastError;}
- (BOOL)saveProgress {
    if (_failure || !_runtime->game) return NO;
    _progressError = nil;
    const BOOL saved = _runtime->cpu.call(0x8e13, {_runtime->game}) != 0;
    [self checkFault];
    return saved && !_failure;
}
- (NSData *)captureProgressData {
    if (_failure || !_runtime->game) return nil;
    _capturedSaveData = nil; _captureSaveOnly = YES;
    _runtime->cpu.call(0x8e13, {_runtime->game});
    _captureSaveOnly = NO;
    [self checkFault];
    return _failure ? nil : _capturedSaveData;
}
- (void)checkpointProgress {
    NSData *data = [self captureProgressData];
    if (data) [_saveStore enqueueData:data];
}
- (NSDictionary<NSString *,id> *)progressPortableSnapshot {
    NSData *data = [self captureProgressData];
    return data ? [SDBSaveStore portableSnapshotForData:data] : nil;
}
+ (NSDictionary<NSString *,id> *)mergedPortableSnapshot:(NSDictionary<NSString *,id> *)local remote:(NSDictionary<NSString *,id> *)remote {
    NSData *localData = [SDBSaveStore dataFromPortableSnapshot:local], *remoteData = [SDBSaveStore dataFromPortableSnapshot:remote];
    NSData *merged = localData && remoteData ? [SDBSaveStore mergeLocalData:localData remoteData:remoteData] : nil;
    return merged ? [SDBSaveStore portableSnapshotForData:merged] : nil;
}
- (BOOL)importValidatedProgress:(NSDictionary<NSString *,id> *)snapshot {
    if (_failure || _suspended || _runtime->touching || self.gameMenuType != 1) return NO;
    NSData *remote = [SDBSaveStore dataFromPortableSnapshot:snapshot], *local = [self captureProgressData];
    NSData *merged = remote && local ? [SDBSaveStore mergeLocalData:local remoteData:remote] : nil;
    if (!merged) {_progressError = @"Portable progress could not be validated."; return NO;}
    if ([merged isEqual:local]) {_progressError = nil; return YES;}
    if (![_saveStore writeData:merged]) return NO;
    _runtime->cpu.call(0x8c85, {_runtime->game});
    _runtime->cpu.write8(_runtime->sound + 1, _soundEnabled);
    [self checkFault]; _progressError = nil;
    return !_failure;
}
- (BOOL)recoverAudioAfterMediaServicesReset {
    [self setAudioSuspended:YES];
    // Rebuild only native nodes. PCM, music identity/cursor and guest state
    // survive, and explicit OS-approved activation remains a separate step.
    if (![_audioMixer rebuildAfterMediaServicesReset]) {
        _audioSessionError = _audioMixer.failure ?: @"The native audio graph could not be rebuilt.";
        return NO;
    }
    [self configureAudioSession];
    return _audioSessionError == nil;
}
- (BOOL)audioSuspended {return _audioSuspended;}
- (NSString *)lastAudioError {return _audioSessionError ?: _audioMixer.failure;}
- (void)pauseAudioVoices {
    for (NSNumber *source in _players) if (_players[source].isPlaying) {
        [_pausedSources addObject:source];
        [_players[source] pause];
    }
}
- (void)setAudioSuspended:(BOOL)suspended {
    if (!suspended) {(void)[self tryResumeAudio]; return;}
    _audioSuspended = YES;
    NSNumber *music = @(_runtime->sound ? _runtime->cpu.read32(_runtime->sound + 0xec) : 0);
    // A paused menu may keep animating. Its sounds and interrupted one-shots
    // must not become deferred effects when native audio becomes available.
    for (NSNumber *source in [_players.allKeys copy]) if (![source isEqual:music]) {
        [_players[source] stop];
        [_players removeObjectForKey:source];
        [_pausedSources removeObject:source];
    }
    [self pauseAudioVoices];
    [_audioMixer suspend];
}
- (BOOL)activateAudioSession {
    [self configureAudioSession];
    if (_audioSessionError) return NO;
    #if !TARGET_OS_OSX
    NSError *error = nil;
    if (![AVAudioSession.sharedInstance setActive:YES error:&error]) {
        _audioSessionError = error.localizedDescription ?: @"The system audio session is temporarily unavailable.";
        return NO;
    }
    #endif
    return YES;
}
- (BOOL)resumeAudioVoices {
    if (_suspended || _audioSuspended) return YES;
    if (_soundEnabled) {
        for (NSNumber *source in [_pausedSources.allObjects copy]) if (_players[source] && ![_players[source] play]) {
            _audioSessionError = _audioMixer.failure ?: @"The native audio voice could not resume.";
            [self setAudioSuspended:YES];
            return NO;
        }
        NSNumber *music = @(_runtime->sound ? _runtime->cpu.read32(_runtime->sound + 0xec) : 0);
        if (_wantedMusicEntry >= 0 && !_players[music]) {
            _runtime->cpu.call(0xea15, {_runtime->sound, uint32_t(_wantedMusicEntry), uint32_t(_wantedMusicLoop)});
            [self checkFault];
        }
    }
    if (_audioSuspended) return NO;
    [_pausedSources removeAllObjects];
    return !_failure && !_audioSuspended;
}
- (BOOL)tryResumeAudio {
    if (_failure || !_audioMixer) return NO;
    if (![self activateAudioSession]) {[self setAudioSuspended:YES]; return NO;}
    // prepare retains a startup error. A later explicit retry replaces only
    // the orphaned native graph rather than poisoning or recreating the guest.
    if (_audioMixer.failure && ![_audioMixer rebuildAfterMediaServicesReset]) {
        _audioSessionError = _audioMixer.failure ?: @"The native audio graph could not be rebuilt.";
        [self setAudioSuspended:YES];
        return NO;
    }
    if (![_audioMixer prepare]) {
        _audioSessionError = _audioMixer.failure ?: @"The native audio graph is temporarily unavailable.";
        [self setAudioSuspended:YES];
        return NO;
    }
    _audioSessionError = nil;
    _audioSuspended = NO;
    if (_suspended) {[_audioMixer suspend]; return YES;}
    return [self resumeAudioVoices];
}
- (void)trimTransientResources {
    [_metalRenderer trimTransientResources];
    Runtime &r = *_runtime;
    r.invalidateMenuPacket();
    std::vector<SDBMetalVertex>().swap(r.menuVertices);
    std::vector<SDBMetalDraw>().swap(r.menuDraws);
    if (_suspended) {
        std::vector<uint8_t>().swap(r.pixels);
        std::vector<Vertex>().swap(r.drawVertices);
        std::vector<SDBMetalVertex>().swap(r.metalVertices);
        std::vector<SDBMetalDraw>().swap(r.metalDraws);
        std::vector<Matrix>().swap(r.stack);
    }
    // _frame is an immutable independent copy and remains visible to the host.
}
- (BOOL)canPause {
    if(_failure||_suspended||!_runtime->game)return NO;
    auto &r=*_runtime;return r.cpu.read32(r.cpu.read32(r.game+4)+0x20)==0;
}
- (BOOL)watchLayout {return _runtime->watchLayout;}
- (void)setWatchLayout:(BOOL)watchLayout {
    if(_failure||_runtime->watchLayout==bool(watchLayout))return;
    [self cancelShipSteering];
    _runtime->watchLayout=watchLayout;
    [self applyViewportPatch];[self checkFault];[self update:0];
}
- (double)shipNormalizedY {
    auto &r=*_runtime;uint32_t player=r.ship();
    if(!player)return .5;
    double limit=r.shipTravelLimit(player),position=real(r.cpu.read32(player+0xa0));
    if(!(limit>0)||!std::isfinite(position))return .5;
    return .5+(r.upsideDown()?-position:position)/(2*limit);
}
- (BOOL)shipAiming {auto &r=*_runtime;uint32_t marker=r.marker();return marker&&r.cpu.read8(marker+0x24)!=0;}
- (BOOL)canSteerShip {auto &r=*_runtime;uint32_t player=r.ship();return self.canPause&&player&&r.cpu.read32(player+0x10)==2;}
- (void)steerShipToNormalizedY:(double)fraction {
    if(!self.canPause||!std::isfinite(fraction))return;
    auto &r=*_runtime;uint32_t player=r.ship();
    if(r.touching||!player||r.cpu.read32(player+0x10)!=2)return;
    // Original Game::touchCancelled is a no-op. When the host already ended
    // ownership of that touch, finish a stale marker with its original ended
    // method. Unlike Game::touchEnded, this does not fire a charged volley.
    uint32_t marker=r.marker();
    if(marker&&r.cpu.read8(marker+0x24))r.cpu.call(0x4b3b,{marker});
    [self checkFault];if(_failure)return;
    r.steeringY=std::clamp(fraction,0.,1.);r.steeringActive=true;
}
- (void)cancelShipSteering {_runtime->steeringActive=false;}
- (void)cancelHeldInput {
    [self cancelShipSteering];
    if (_failure || !_runtime->game) {_runtime->touching = false; return;}
    [self touchPhase:3 x:0 y:0];
    _runtime->touching = false;
    const uint32_t marker = _runtime->marker();
    if (marker && _runtime->cpu.read8(marker + 0x24)) _runtime->cpu.call(0x4b3b, {marker});
    [self checkFault];
}
- (void)pauseGame {
    if(!self.canPause)return;
    [self cancelShipSteering];
    _pendingHapticEvents=0;
    [self touchPhase:3 x:0 y:0];
    auto &r=*_runtime;
    // Invoke the original P-button callback, including its pause-menu transition
    // and audio behavior, rather than only setting the simulation pause byte.
    r.cpu.call(0x9b0f,{r.cpu.read32(r.game+4),0,0x14ef8});
    [self checkFault];[self update:0];
}
- (void)applyViewportPatch {
    auto &r=*_runtime;r.displayPatch.apply(r.cpu,r.geometry,r.watchLayout);
    // Move the guest hit target with its replaced drawing. The native corner
    // button invokes the same original pause routine directly.
    if(TARGET_OS_IOS||r.watchLayout) {
        r.cpu.write32(0x14ef8,bits(float(r.geometry.logicalSize.height*2)));
        r.cpu.write32(0x14ef8+4,bits(float(r.geometry.logicalSize.width*2)));
    }
}
#if !TARGET_OS_WATCH
- (id<MTLDevice>)metalDevice {return _metalRenderer.device;}
- (BOOL)presentToDrawable:(id<CAMetalDrawable>)drawable {return [_metalRenderer presentCurrentFrameToDrawable:drawable];}
#endif
- (CGPoint)logicalPointForViewPoint:(CGPoint)point {
    auto p=_runtime->geometry.viewToLogical({point.x,point.y});return CGPointMake(p.x,p.y);
}
- (void)configureViewport:(CGSize)size displayScale:(double)scale safeArea:(CGRect)safe {
    if(_failure)return;
    auto geometry=DisplayGeometry::make({size.width,size.height},scale,
        {safe.origin.y,safe.origin.x,std::max(0.,double(size.height-CGRectGetMaxY(safe))),std::max(0.,double(size.width-CGRectGetMaxX(safe)))},
        16*1024*1024);
    if(!geometry.valid)return;
    [self cancelShipSteering];
    [self touchPhase:3 x:0 y:0];
    _runtime->geometry=geometry;
    _runtime->invalidateMenuPacket();
    [self applyViewportPatch];
    if(!_runtime->metal)_runtime->pixels.resize(size_t(geometry.pixelCount())*4);
    [self checkFault];[self update:0];
}
- (NSString *)failure {return _failure;}
- (NSString *)diagnostics {
    if(!_runtime)return @"Runtime unavailable";
    Runtime &r=*_runtime;
    NSString *category=@"system-output";
    #if !TARGET_OS_OSX
    category=AVAudioSession.sharedInstance.category;
    #endif
    return [NSString stringWithFormat:@"frames=%llu draws=%llu instructions=%llu heap=%u allocations=%lu audio=%llu game=%08x menu=%08x sound=%d respectSilent=%d category=%@ audioError=%@ menuType=%u viewport=%.1fx%.1f raster=%ux%u renderer=%@ audioSuspended=%d audioPolicyError=%@ rendererError=%@",
        r.frames,r.draws,r.cpu.instructionCount,r.heap,(unsigned long)r.allocations.size(),r.audioEvents,r.game,r.cpu.read32(r.game+4),_soundEnabled,_respectsSilentMode,category,self.lastAudioError?:@"none",r.cpu.read32(r.cpu.read32(r.game+4)+0x20),r.geometry.logicalSize.width,r.geometry.logicalSize.height,r.geometry.rasterWidth,r.geometry.rasterHeight,r.metal?@"Metal":@"CPU",_audioSuspended,_audioPolicyError?:@"none",_metalRenderer.failure?:@"none"];
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
    _audioSessionError=nil;
    #if !TARGET_OS_OSX
    AVAudioSession *session=AVAudioSession.sharedInstance;
    NSError *error=nil;
    AVAudioSessionCategory category=_respectsSilentMode?AVAudioSessionCategoryAmbient:AVAudioSessionCategoryPlayback;
    AVAudioSessionCategoryOptions options=_respectsSilentMode?0:AVAudioSessionCategoryOptionMixWithOthers;
    if (![session setCategory:category mode:AVAudioSessionModeDefault options:options error:&error])
        _audioSessionError=error.localizedDescription?:@"The system audio category is temporarily unavailable.";
    #if TARGET_OS_IOS
    // This preference applies to banners only; accepted/full-screen calls may
    // still interrupt. A denied preference never prevents normal playback.
    NSError *policyError=nil;
    _audioPolicyError=[session setPrefersNoInterruptionsFromSystemAlerts:YES error:&policyError]?nil:
        (policyError.localizedDescription?:@"The system-alert interruption preference was not accepted.");
    #endif
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
    } else if(changed&&!_suspended&&!_audioSuspended&&_wantedMusicEntry>=0) {
        _runtime->cpu.call(0xea15,{_runtime->sound,uint32_t(_wantedMusicEntry),uint32_t(_wantedMusicLoop)});
        [self checkFault];
    }
}
- (BOOL)respectsSilentMode {return _respectsSilentMode;}
- (BOOL)hapticsEnabled {return _hapticsEnabled;}
- (void)setHapticsEnabled:(BOOL)enabled {
    if(!_offersHaptics)return;
    _hapticsEnabled=enabled;
    _pendingHapticEvents=enabled?HapticMenu:0;
    [self storePreference:enabled key:@"feedback.hapticsEnabled"];
}
- (NSUInteger)consumeHapticEvents {
    NSUInteger events=_pendingHapticEvents;
    _pendingHapticEvents=0;
    if(!_hapticsEnabled||_suspended||_failure)return 0;
    return self.canPause?events:(events&HapticMenu);
}
- (void)setRespectsSilentMode:(BOOL)respect {
    _respectsSilentMode=respect;[self storePreference:respect key:@"audio.respectsSilentMode"];
    [self configureAudioSession];
    if(!_suspended&&!_audioSuspended&&_audioMixer)(void)[self tryResumeAudio];
}
- (void)checkFault {
    if(!_runtime->cpu.fault.empty())_failure=@(_runtime->cpu.fault.c_str());
}
- (instancetype)initWithResourcePath:(NSString *)path {
    return [self initWithResourcePath:path offersHaptics:NO];
}
- (instancetype)initWithResourcePath:(NSString *)path offersHaptics:(BOOL)offersHaptics {
    if((self=[super init])) {
        _offersHaptics=offersHaptics;
        _runtime=std::make_unique<Runtime>();_resourcePath=[path copy];
        #if defined(SDB_HEADLESS_TESTS)
        // The paired cache oracle is absent from production app builds.
        _runtime->softwareMenuCaching=getenv("SDB_TEST_DISABLE_SOFTWARE_MENU_CACHE")==nullptr;
        #endif
        _players=[NSMutableDictionary dictionary];
        _sourceBuffers=[NSMutableDictionary dictionary];_sourceLoops=[NSMutableDictionary dictionary];_sourceGains=[NSMutableDictionary dictionary];
        _pausedSources=[NSMutableSet set];
        _muted=NSProcessInfo.processInfo.environment[@"SDB_MUTE_AUDIO"]!=nil;
        // UI tests run in another sandbox. Resolve a caller-supplied ~/tmp path
        // inside this app's own home instead of using the test runner's home.
        NSString *override=[NSProcessInfo.processInfo.environment[@"SDB_SAVE_DIRECTORY"] stringByExpandingTildeInPath];
        NSURL *base=[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
        _savePath=override?:[[base URLByAppendingPathComponent:NSBundle.mainBundle.bundleIdentifier?:@"dev.cammalleri.space-undeadbeef"] path];
        _saveStore = [[SDBSaveCoordinator alloc] initWithDirectory:_savePath];
        if(override) {
            // Tests persist only inside their own temporary directory, never real user preferences.
            _testPreferencesPath=[override stringByAppendingPathComponent:@"audio-preferences.plist"];
            _testPreferences=[[NSDictionary dictionaryWithContentsOfFile:_testPreferencesPath] mutableCopy]?:[NSMutableDictionary dictionary];
        }
        _soundEnabled=[self preference:@"audio.soundEnabled"]?[[self preference:@"audio.soundEnabled"] boolValue]:YES;
        _respectsSilentMode=[self preference:@"audio.respectsSilentMode"]?[[self preference:@"audio.respectsSilentMode"] boolValue]:YES;
        NSNumber *hapticsPreference=[self preference:@"feedback.hapticsEnabled"];
        _hapticsEnabled=_offersHaptics&&(hapticsPreference?hapticsPreference.boolValue:YES);
        _wantedMusicEntry=-1;_wantedMusicLoop=YES;
        [self configureAudioSession];
        _audioMixer=[self newAudioMixer];
        _audioMixer.outputVolume=_muted?0:1;
        _metalRenderer=[[SDBMetalRenderer alloc] init];
        _runtime->metal=_metalRenderer.supported&&NSProcessInfo.processInfo.environment[@"SDB_CPU_RENDERER"]==nil;
        __unsafe_unretained SDBEngine *owner=self;
        _runtime->cpu.hook=[owner](GuestCPU &cpu,uint32_t pc) -> bool {
            if (pc == 0x97ac) ++owner->_menuGeneration;
            if(sdb::display::GameDisplayPatch::handlesPc(pc))return owner->_runtime->displayPatch.handleInstruction(cpu,pc);
            // Observe the original effect request before its Sound-OFF guard.
            // The guest method still executes unchanged after this hook.
            if(pc==0xe994&&owner->_hapticsEnabled) {
                if(cpu.r[1]==0)owner->_pendingHapticEvents|=HapticMenu; // Accepted executable menu button.
                else if(cpu.r[1]==2)owner->_pendingHapticEvents|=HapticRelease; // Targeted lock-on volley.
                else if(cpu.r[1]==3)owner->_pendingHapticEvents|=HapticTarget; // Successful target acquisition.
                else if(cpu.r[1]==4)owner->_pendingHapticEvents|=HapticPrimary; // Actual primary Bluster construction.
                else if(cpu.r[1]==5)owner->_pendingHapticEvents|=HapticExplosion; // Original Explosion construction.
            }
            // These original boundaries run only after primary-shot append or
            // after entry into the accepted native/guest pause callback.
            if(pc==0x286e&&owner->_hapticsEnabled)owner->_pendingHapticEvents|=HapticPrimary;
            if(pc==0x9b0e&&owner->_hapticsEnabled)owner->_pendingHapticEvents|=HapticMenu;
            if(pc==0x2796&&owner->_hapticsEnabled) {
                // Observe the actual Player health store, not enemy explosions.
                Runtime &runtime=*owner->_runtime;
                uint32_t game=cpu.read32(runtime.game+0xc),player=cpu.read32(game+0x4c);
                if(cpu.r[1]==0xd8&&cpu.r[2]==player&&
                   int32_t(cpu.r[3])<int32_t(cpu.read32(player+0xd8)))owner->_pendingHapticEvents|=HapticDamage;
            }
            if((pc>=0xee9c&&pc<0xf478)||pc==0xa80c||pc==0xa8a0||pc==0xa958||pc==0x8e04||pc==0xea14||pc==0xe86e||
               (pc>=SilentOn&&pc<=HapticsOffDraw))return [owner bridge:pc];
            return false;
        };
        [self loadOriginal];[self checkFault];
        if(!_failure)[self update:0];
    }
    return self;
}
- (void)dealloc {if(_frame)CGImageRelease(_frame);}
- (SDBAudioMixer *)newAudioMixer {return [SDBAudioMixer new];}

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
    if(!r.displayPatch.initialize(c))return;
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
        Texture t;t.width=pw;t.height=ph;t.contentWidth=w;t.contentHeight=h;t.pixels.resize(pw*ph*4);
        CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();
        CGContextRef context=CGBitmapContextCreate(t.pixels.data(),pw,ph,8,pw*4,space,kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big);
        CGColorSpaceRelease(space);
        CGContextDrawImage(context,CGRectMake(0,ph-h,w,h),image);CGContextRelease(context);CGImageRelease(image);
        // Texture2D uses straight-alpha GL blending. Convert decoded premultiplication once.
        for(size_t p=0;p<t.pixels.size();p+=4)if(t.pixels[p+3])for(int k=0;k<3;++k)t.pixels[p+k]=uint8_t(std::min(255u,unsigned(t.pixels[p+k])*255/t.pixels[p+3]));
        NSString *name=entry[@"name"];
        if([@[@"font.png",@"font_s.png"] containsObject:name]) {
            t.glyphAtlas=1;
            // Keep the original antialiasing. Atlas cells have no gutters, so
            // whole-atlas distance fields let neighbouring glyphs distort edges.
            // All original ink is white; extend that colour through transparent
            // texels to prevent a dark fringe when linearly filtering the alpha.
            for(size_t p=0;p<t.pixels.size();p+=4)t.pixels[p]=t.pixels[p+1]=t.pixels[p+2]=255;
        } else if([@[@"game_start.png",@"credits.png",@"continue.png",@"continue_left.png",@"quit.png",@"options.png"] containsObject:name]) {
            // The original baked labels are off-white lettering over a soft
            // black shadow. Split their premultiplied contribution before
            // sharpening only the foreground outline; retain the shadow mask.
            auto foreground=t.pixels;
            std::vector<uint8_t> shadow(size_t(pw)*ph);
            for(size_t p=0;p<t.pixels.size();p+=4) {
                const float alpha=t.pixels[p+3]/255.f;
                const float ink=std::clamp(t.pixels[p]/238.f*alpha,0.f,alpha);
                const float shade=ink<1?std::clamp((alpha-ink)/(1-ink),0.f,1.f):0;
                foreground[p+3]=uint8_t(std::round(ink*255));
                shadow[p/4]=uint8_t(std::round(shade*255));
            }
            auto field=sdb::text::TextDistanceField::make(foreground.data(),pw,ph);
            if(field.empty()) {c.fail("Original menu foreground distance field could not be created");return;}
            for(size_t p=0;p<t.pixels.size();p+=4) {
                t.pixels[p]=shadow[p/4];t.pixels[p+1]=t.pixels[p+2]=238;
                t.pixels[p+3]=field[p+3];
            }
            t.distanceField=2;
        }
        if(index==2) {
            // The original opaque title has a baked one-pixel image frame.
            // It was hidden at the old screen edge, but appears as a matte
            // line in an expanded viewport. Normalize that frame only; retain
            // every interior pixel and the original content dimensions/UVs.
            if(w<3||h<3) {c.fail("Original title is too small to normalize its border");return;}
            for(unsigned y=0;y<h;++y)for(unsigned x=0;x<w;++x) {
                if(x!=0&&y!=0&&x!=w-1&&y!=h-1)continue;
                const unsigned sx=std::clamp(x,1u,w-2),sy=std::clamp(y,1u,h-2);
                memcpy(t.pixels.data()+4*(size_t(y)*pw+x),t.pixels.data()+4*(size_t(sy)*pw+sx),4);
            }
            // maxS/maxT end at the content boundary inside a larger POT
            // texture. Extrude one texel into its unused padding so linear
            // filtering cannot introduce a transparent-black rim there.
            for(unsigned y=0;y<=h&&y<ph;++y)for(unsigned x=0;x<=w&&x<pw;++x) {
                if(x!=w&&y!=h)continue;
                const unsigned sx=std::min(x,w-1),sy=std::min(y,h-1);
                memcpy(t.pixels.data()+4*(size_t(y)*pw+x),t.pixels.data()+4*(size_t(sy)*pw+sx),4);
            }
        }
        if(r.metal&&![_metalRenderer setTexture:index+1 rgba:t.pixels.data() byteLength:t.pixels.size() width:pw height:ph]) {c.fail(_metalRenderer.failure.UTF8String?:"Texture upload failed");return;}
        r.textures[index+1]=std::move(t);
        ++r.textureGeneration;
        uint32_t p=records+32*index;c.write32(p,index+1);c.write32(p+4,bits(w));c.write32(p+8,bits(h));
        c.write32(p+12,pw);c.write32(p+16,ph);c.write32(p+20,0);c.write32(p+24,bits(float(w)/pw));c.write32(p+28,bits(float(h)/ph));
    }
    if(!c.fault.empty())return;
    [self loadExtendedTitle];
    r.sound=r.allocate(0x108);if(!c.fault.empty())return;
    c.call(0xe7e9,{r.sound});if(!c.fault.empty())return;
    c.call(0xeb01,{r.sound});if(!c.fault.empty())return;
    for(NSDictionary *entry in manifest[@"sounds"]) {
        uint32_t index=[entry[@"entry"] unsignedIntValue];if(index>=12)continue;
        uint32_t p=r.sound+12+16*index;
        c.write32(p,r.allocate(8));c.write32(p+4,8);c.write32(p+8,index+1);c.write32(p+12,bits([entry[@"volume"] floatValue]));
        NSURL *url=[NSURL fileURLWithPath:[_resourcePath stringByAppendingPathComponent:entry[@"name"]]];
        if(![_audioMixer loadBuffer:index+1 URL:url]) {c.fail(_audioMixer.failure.UTF8String?:"Original audio could not load");return;}
    }
    // An unavailable audio device must not prevent the original game/menu from
    // being constructed. Explicit native recovery can activate it later.
    (void)[self tryResumeAudio];
    if(!c.fault.empty())return;
    r.game=r.allocate(24);if(!c.fault.empty())return;c.call(0x8dfb,{r.game});
    if(!c.fault.empty())return;
    // The modern preference wins over the legacy game's initial sound-OFF byte.
    c.write8(r.sound+1,_soundEnabled);
    if(_offersHaptics&&c.read16(0x2796)!=0x5053) {c.fail("Unsupported original player-health store");return;}
    if(c.read32(0x562c)!=0x1c04b5b0||c.read32(0x291c)!=bits(80.f)||c.read16(0x4b3a)!=0x2324) {
        c.fail("Unsupported original ship-steering routines");return;
    }
    if(_offersHaptics&&(c.read32(0x286e)!=0x22e09912||c.read32(0x9b0e)!=0xaf01b590||
                       c.read32(0xe994)!=0x7843b5f0)) {c.fail("Unsupported original haptic event boundaries");return;}
    if(TARGET_OS_IOS||TARGET_OS_WATCH||_offersHaptics) {
    // Extend the original Options table using its own font, layout, buttons, and animations.
    const uint32_t old=c.read32(0x14680);
    if(old!=0x148e0) {c.fail("Unsupported original Options table");return;}
    const uint32_t rowCount=_offersHaptics?15:12;
    uint32_t table=r.allocate(rowCount*60);
    memcpy(c.memory.data()+table,c.memory.data()+old,7*60);
    memcpy(c.memory.data()+table+(rowCount-2)*60,c.memory.data()+old+7*60,2*60);
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
    if(_offersHaptics) {
        const char *haptics="Haptics";uint32_t hapticsText=r.allocate(uint32_t(strlen(haptics)+1));
        c.load(hapticsText,haptics,strlen(haptics)+1);
        for(unsigned i=0;i<3;++i) {
            uint32_t dest=table+(10+i)*60,source=old+(4+i)*60;
            memcpy(c.memory.data()+dest,c.memory.data()+source,60);
            if(i==0)c.write32(dest+36,hapticsText);
            else {c.write32(dest+40,(i==1?HapticsOn:HapticsOff)|1);c.write32(dest+44,(i==1?HapticsOnDraw:HapticsOffDraw)|1);}
        }
    }
    c.write32(0x14680,table);
    }
    NSString *version=[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"]?:@"dev";
    _menuVersion=[@"Ver." stringByAppendingString:version];
    const uint32_t versionRow=0x14d90;
    if(r.string(c.read32(versionRow+36))!="Ver.1.01") {c.fail("Unsupported original version row");return;}
    NSData *versionBytes=[_menuVersion dataUsingEncoding:NSASCIIStringEncoding];
    uint32_t versionText=r.allocate(uint32_t(versionBytes.length+1));
    c.load(versionText,versionBytes.bytes,versionBytes.length);c.write32(versionRow+36,versionText);
    [self applyViewportPatch];
}
- (void)loadExtendedTitle {
    // Modern artwork is kept separate from the untouched original resources.
    NSString *path=[[_resourcePath stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"Modern/title-sky.png"];
    CGImageSourceRef source=CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path],nullptr);
    CGImageRef image=source?CGImageSourceCreateImageAtIndex(source,0,nullptr):nullptr;
    if(source)CFRelease(source);
    if(!image)return;
    unsigned w=(unsigned)CGImageGetWidth(image),h=(unsigned)CGImageGetHeight(image),pw=1,ph=1;
    while(pw<w)pw*=2;while(ph<h)ph*=2;
    Texture t;t.width=pw;t.height=ph;t.contentWidth=w;t.contentHeight=h;t.pixels.resize(size_t(pw)*ph*4);
    CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();
    CGContextRef context=CGBitmapContextCreate(t.pixels.data(),pw,ph,8,pw*4,space,kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    // Keep the same padded top-left texture orientation as the originals.
    CGContextDrawImage(context,CGRectMake(0,ph-h,w,h),image);
    CGContextRelease(context);CGImageRelease(image);
    const auto originalIt=_runtime->textures.find(3);
    if(originalIt==_runtime->textures.end()||originalIt->second.contentWidth<=0||originalIt->second.contentHeight<=0) {
        _runtime->cpu.fail("Original title is unavailable for matching the extended sky");return;
    }
    const Texture &original=originalIt->second;
    // Match the scenery to the untouched original quad at its exact boundary.
    // Both textures use top-left content rows; the original is portrait and
    // appears clockwise in landscape. Sampling is expressed at texel centers,
    // so local landscape (x,y) maps to original (y-.5,height-.5-x).
    const double coreWidth=original.contentHeight,coreHeight=original.contentWidth;
    const double canvasWidth=2*coreWidth,canvasHeight=2*coreHeight;
    const double coreLeft=(canvasWidth-coreWidth)/2,coreTop=(canvasHeight-coreHeight)/2;
    const auto unmodifiedSky=t.pixels;
    const auto sample=[](const Texture &texture,const std::vector<uint8_t>&pixels,double x,double y) {
        x=std::clamp(x,0.,double(texture.contentWidth-1));
        y=std::clamp(y,0.,double(texture.contentHeight-1));
        const unsigned x0=unsigned(x),y0=unsigned(y);
        const unsigned x1=std::min(x0+1,unsigned(texture.contentWidth-1));
        const unsigned y1=std::min(y0+1,unsigned(texture.contentHeight-1));
        const double fx=x-x0,fy=y-y0;
        std::array<double,3> rgb{};
        for(unsigned channel=0;channel<3;++channel) {
            const auto value=[&](unsigned xx,unsigned yy) {return double(pixels[4*(size_t(yy)*texture.width+xx)+channel]);};
            rgb[channel]=(1-fy)*((1-fx)*value(x0,y0)+fx*value(x1,y0))+
                fy*((1-fx)*value(x0,y1)+fx*value(x1,y1));
        }
        return rgb;
    };
    // Diffuse the colour difference into the surrounding scenery rather than
    // extending each edge pixel along a ray, which produces visible streaks.
    // The original core and the outer sky border are fixed Dirichlet values.
    // A 240x160-cell field is sufficient for palette correction; the final
    // short-range residual below restores fine boundary detail separately.
    const unsigned cellsX=240,cellsY=160,columns=cellsX+1,rows=cellsY+1;
    std::vector<std::array<double,3>> field(size_t(columns)*rows);
    std::vector<uint8_t> fixed(field.size());
    for(unsigned y=0;y<rows;++y)for(unsigned x=0;x<columns;++x) {
        const size_t p=size_t(y)*columns+x;
        const double lx=x*canvasWidth/cellsX,ly=y*canvasHeight/cellsY;
        const bool inside=lx>=coreLeft&&lx<=coreLeft+coreWidth&&ly>=coreTop&&ly<=coreTop+coreHeight;
        fixed[p]=inside||x==0||y==0||x==cellsX||y==cellsY;
        if(inside) {
            const auto core=sample(original,original.pixels,ly-coreTop-.5,coreWidth-.5-(lx-coreLeft));
            const auto sky=sample(t,unmodifiedSky,lx*w/canvasWidth-.5,ly*h/canvasHeight-.5);
            for(unsigned channel=0;channel<3;++channel)field[p][channel]=core[channel]-sky[channel];
        }
    }
    for(unsigned iteration=0;iteration<160;++iteration)for(unsigned parity=0;parity<2;++parity) {
        for(unsigned y=1;y<cellsY;++y)for(unsigned x=1;x<cellsX;++x) {
            const size_t p=size_t(y)*columns+x;
            if(fixed[p]||((x+y)&1)!=parity)continue;
            for(unsigned channel=0;channel<3;++channel) {
                const double average=(field[p-1][channel]+field[p+1][channel]+
                    field[p-columns][channel]+field[p+columns][channel])/4;
                field[p][channel]+=1.5*(average-field[p][channel]);
            }
        }
    }
    const auto correction=[&](double lx,double ly) {
        const double gx=std::clamp(lx*cellsX/canvasWidth,0.,double(cellsX));
        const double gy=std::clamp(ly*cellsY/canvasHeight,0.,double(cellsY));
        const unsigned x0=unsigned(gx),y0=unsigned(gy),x1=std::min(x0+1,cellsX),y1=std::min(y0+1,cellsY);
        const double fx=gx-x0,fy=gy-y0;
        std::array<double,3> rgb{};
        for(unsigned channel=0;channel<3;++channel) {
            const auto value=[&](unsigned x,unsigned y) {return field[size_t(y)*columns+x][channel];};
            rgb[channel]=(1-fy)*((1-fx)*value(x0,y0)+fx*value(x1,y0))+
                fy*((1-fx)*value(x0,y1)+fx*value(x1,y1));
        }
        return rgb;
    };
    const double fineTransition=coreHeight/40;
    // The left extension should stay quiet. Derive its dark fill from the
    // original edge strip, then match only a short transition at the join.
    // This removes invented diagonal rays while retaining the original core.
    std::array<double,3> leftFill{};
    for(unsigned channel=0;channel<3;++channel) {
        std::vector<double> values;
        const unsigned stripWidth=unsigned(coreHeight/40);
        for(unsigned y=0;y<unsigned(coreHeight);++y)for(unsigned x=0;x<stripWidth;++x)
            values.push_back(sample(original,original.pixels,y,coreWidth-1-x)[channel]);
        auto middle=values.begin()+values.size()/2;
        std::nth_element(values.begin(),middle,values.end());leftFill[channel]=*middle;
    }
    const double leftTransition=coreHeight/20;
    for(unsigned y=0;y<h;++y)for(unsigned x=0;x<w;++x) {
        const size_t pixel=4*(size_t(y)*pw+x);
        t.pixels[pixel+3]=255;
        const double logicalX=(x+.5)*canvasWidth/w,logicalY=(y+.5)*canvasHeight/h;
        const double boundaryX=std::clamp(logicalX,coreLeft,coreLeft+coreWidth);
        const double boundaryY=std::clamp(logicalY,coreTop,coreTop+coreHeight);
        const double distance=std::hypot(logicalX-boundaryX,logicalY-boundaryY);
        const auto edge=sample(original,original.pixels,boundaryY-coreTop-.5,
            coreWidth-.5-(boundaryX-coreLeft));
        if(logicalX<coreLeft) {
            const double fraction=std::clamp((coreLeft-logicalX)/leftTransition,0.,1.);
            const double edgeWeight=1-fraction*fraction*(3-2*fraction);
            for(unsigned channel=0;channel<3;++channel)
                t.pixels[pixel+channel]=uint8_t(std::lround(leftFill[channel]+edgeWeight*(edge[channel]-leftFill[channel])));
            continue;
        }
        if(distance==0) {
            // Hidden beneath the opaque original quad. Matching this side of
            // the sampling boundary too prevents GL_LINEAR from blending an
            // adjacent uncorrected sky texel back into the visible outer edge.
            for(unsigned channel=0;channel<3;++channel)t.pixels[pixel+channel]=uint8_t(std::lround(edge[channel]));
            continue;
        }
        const auto coarse=correction(logicalX,logicalY);
        const auto boundary=correction(boundaryX,boundaryY);
        const auto sky=sample(t,unmodifiedSky,boundaryX*w/canvasWidth-.5,boundaryY*h/canvasHeight-.5);
        const double fraction=std::min(1.,distance/fineTransition);
        const double weight=1-fraction*fraction*(3-2*fraction);
        for(unsigned channel=0;channel<3;++channel) {
            const double residual=edge[channel]-sky[channel]-boundary[channel];
            const double corrected=unmodifiedSky[pixel+channel]+coarse[channel]+weight*residual;
            t.pixels[pixel+channel]=uint8_t(std::clamp(std::lround(corrected),0l,255l));
        }
    }
    if(_runtime->metal)[_metalRenderer setTexture:ExtendedTitle rgba:t.pixels.data() byteLength:t.pixels.size() width:pw height:ph];
    _runtime->textures[ExtendedTitle]=std::move(t);
    ++_runtime->textureGeneration;
}

- (BOOL)bridge:(uint32_t)pc {
    Runtime &r=*_runtime;GuestCPU &c=r.cpu;
    auto done=[&](uint32_t result=0)->BOOL {c.r[0]=result;c.returnFromHook();return YES;};
    if(pc==0x8e04) {[self setSoundEnabled:c.r[1]!=0];return done();}
    if(pc==0xea14) {_wantedMusicEntry=c.r[1];_wantedMusicLoop=c.r[2]!=0;return NO;}
    if(pc==0xe86e) {_wantedMusicEntry=-1;return NO;}
    if(pc==SilentOn||pc==SilentOff) {[self setRespectsSilentMode:pc==SilentOn];return done();}
    if(pc==HapticsOn||pc==HapticsOff) {[self setHapticsEnabled:pc==HapticsOn];return done();}
    if(pc==SilentOnDraw||pc==SilentOffDraw||pc==HapticsOnDraw||pc==HapticsOffDraw) {
        bool selected=pc>=HapticsOnDraw?(pc==HapticsOnDraw)==bool(_hapticsEnabled):(pc==SilentOnDraw)==bool(_respectsSilentMode);
        uint32_t button=c.r[1],data=c.r[2];
        c.call(0x9b2f,{selected?0xff80c0ffu:0xff808080u,button,data});return done();
    }
    // Only obsolete file I/O is replaced; SaveData packing and validation execute in the guest.
    if(pc==0xa80c||pc==0xa8a0||pc==0xa958) {
        if(pc==0xa958) {r.release(c.r[0]);return done();}
        std::string name=r.string(c.r[0]);
        if(name!="savedata.dat") {c.fail("Unexpected guest save filename");return done();}
        if(pc==0xa8a0) {
            NSData *bytes=[_saveStore loadData];
            if(!bytes) {c.write32(c.r[1],0);return done();}
            uint32_t p=r.allocate((uint32_t)bytes.length);c.load(p,bytes.bytes,bytes.length);c.write32(c.r[1],(uint32_t)bytes.length);return done(p);
        }
        if(!r.span(c.r[1],c.r[2])||c.r[2]>4096)return done();
        NSData *bytes=[NSData dataWithBytes:c.memory.data()+c.r[1] length:c.r[2]];
        if (_captureSaveOnly) {_capturedSaveData = bytes; return done([SDBSaveStore isValidOriginalData:bytes]);}
        const BOOL written = [_saveStore writeData:bytes];
        if (written) _progressError = nil;
        return done(written);
    }
    auto it=r.imports.find(pc);if(it==r.imports.end())return NO;
    const std::string &s=it->second;
    // Resolve std::string's storage once per bridge. Constructing this view in
    // every comparison repeatedly checks the string's short/long representation.
    const std::string_view importedName(s);
    auto is=[&](std::string_view name) {return importedName==name;};
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
        else if(is("_glBindTexture")) {
            // Both original fonts use the same 16x8 normalized glyph grid.
            // Use the larger original artwork without changing guest metrics.
            r.texture=c.r[1]==OriginalSmallFont?OriginalFont:c.r[1];
        }
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
            ++r.audioEvents;
            NSNumber *music=@(r.sound?c.read32(r.sound+0xec):0);
            SDBAudioVoice *player=[_audioMixer voiceForSource:c.r[0]];
            if(!player||![player configureBuffer:[_sourceBuffers[source] unsignedIntValue] loop:[_sourceLoops[source] boolValue]])
                c.fail(_audioMixer.failure.UTF8String?:"Original audio selected an invalid voice");
            else {
                player.volume=_muted?0:(_sourceGains[source]?[_sourceGains[source] floatValue]:1);
                if(_audioSuspended&&![source isEqual:music]) {
                    // Validate the original source/buffer even when dropping
                    // this transient event; the gate must not hide guest faults.
                    [player stop];[_players removeObjectForKey:source];[_pausedSources removeObject:source];
                    return done();
                }
                _players[source]=player;
                if(_audioSuspended&&[source isEqual:music])[_pausedSources addObject:source];
                if(!_suspended&&!_audioSuspended&&_soundEnabled) {
                    [_audioMixer wakeIfNeeded];
                    if(![player play]) {
                        _audioSessionError=_audioMixer.failure?:@"The native audio voice could not play.";
                        if([source isEqual:music])[_pausedSources addObject:source];
                        [self setAudioSuspended:YES];
                    }
                }
            }
        } else if(is("_alSourceStop")) {[_players[source] stop];[_players removeObjectForKey:source];[_pausedSources removeObject:source];}
        else if(!(is("_alListener3f")||is("_alcCloseDevice")||is("_alcDestroyContext")||is("_alDeleteSources")))c.fail("Unbridged audio call: "+s);
        return done();
    }
    c.fail("Unbridged original API: "+s);return done();
}

- (void)update:(double)delta {
    [self advanceSimulation:delta];
    [self renderFrame];
}
- (void)advanceSimulation:(double)delta {
    if(_failure||_suspended)return;
    Runtime &r=*_runtime;
    if(delta>0) {
        uint32_t player=r.steeringActive?r.ship():0;
        if(r.steeringActive) {
            if(!self.canPause||r.touching||!player||r.cpu.read32(player+0x10)!=2)r.steeringActive=false;
            else {
                double target=(r.steeringY*2-1)*r.shipTravelLimit(player);
                if(r.upsideDown())target=-target;
                // Same original spring target, stiffness and integration path
                // used by Player::update for marker steering, without its aim.
                r.cpu.call(0x562d,{player+0x98,bits(float(target)),r.cpu.read32(0x291c)});
                [self checkFault];if(_failure)return;
            }
        }
        r.cpu.call(0x8af3,{r.game,bits(1.f/60.f)});
    }
    [self checkFault];
}
- (void)renderFrame {
    if(_failure||_suspended)return;
    Runtime &r=*_runtime;
    const uint32_t type=uint32_t(self.gameMenuType);
    const bool collectMenu=!r.metal&&type!=0&&r.softwareMenuCaching;
    r.collectSoftwareDraws=collectMenu;r.softwarePacketFallback=false;
    if(!r.metal) {
        r.pixels.resize(size_t(r.geometry.pixelCount())*4);
        if(!collectMenu) {r.invalidateMenuPacket();std::fill(r.pixels.begin(),r.pixels.end(),0);}
    }
    r.metalVertices.clear();r.metalDraws.clear();r.titleDrawn=false;
    r.matrix=Matrix();r.stack.clear();r.colorArray=false;
    r.cpu.call(0x8b23,{r.game});[self checkFault];if(_failure)return;
    if(r.metal) {
        BOOL submitted=[_metalRenderer renderVertices:r.metalVertices.data() vertexCount:r.metalVertices.size()
            draws:r.metalDraws.data() drawCount:r.metalDraws.size() logicalSize:self.logicalSize
            pixelWidth:r.geometry.rasterWidth pixelHeight:r.geometry.rasterHeight];
        if(_metalRenderer.failure)_failure=_metalRenderer.failure;
        if(submitted&&_frame) {CGImageRelease(_frame);_frame=nullptr;}
    } else {
        r.collectSoftwareDraws=false;
        if(collectMenu&&!r.softwarePacketFallback&&_frame&&r.sameMenuPacket(type)) {++r.frames;return;}
        if(collectMenu&&!r.softwarePacketFallback) {
            std::fill(r.pixels.begin(),r.pixels.end(),0);
            r.rasterizeSoftwarePacket();[self checkFault];if(_failure)return;
            r.rememberMenuPacket(type);
        }
        for(size_t p=3;p<r.pixels.size();p+=4)r.pixels[p]=255;
        CFDataRef bytes=CFDataCreate(nullptr,r.pixels.data(),r.pixels.size());
        CGDataProviderRef provider=CGDataProviderCreateWithCFData(bytes);CFRelease(bytes);
        CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();
        CGImageRef next=CGImageCreate(r.geometry.rasterWidth,r.geometry.rasterHeight,8,32,r.geometry.rasterWidth*4,space,kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big,provider,nullptr,false,kCGRenderingIntentDefault);
        CGColorSpaceRelease(space);CGDataProviderRelease(provider);
        if(_frame)CGImageRelease(_frame);_frame=next;
    }
    ++r.frames;
}
- (void)touchPhase:(NSInteger)phase x:(double)x y:(double)y {
    if(_failure||_suspended)return;Runtime &r=*_runtime;
    auto guest=r.geometry.logicalToGuest({x,y});
    float gx=float(guest.x),gy=float(guest.y);
    if(phase==0) {[self cancelShipSteering];r.touching=true;r.cpu.call(0x8b3d,{r.game,bits(gx),bits(gy)});}
    else if(phase==1&&r.touching)r.cpu.call(0x8b77,{r.game,bits(gx),bits(gy),bits(r.lastX),bits(r.lastY)});
    else if(phase==2&&r.touching) {r.cpu.call(0x8bdb,{r.game,bits(gx),bits(gy)});r.touching=false;}
    else if(phase==3&&r.touching) {r.cpu.call(0x8c15,{r.game});r.touching=false;}
    r.lastX=gx;r.lastY=gy;[self checkFault];
}
- (void)setSuspended:(BOOL)suspended {
    if(suspended==_suspended)return;
    [self cancelShipSteering];
    _pendingHapticEvents=0;
    if(suspended) {
        [self touchPhase:3 x:0 y:0];
        [self pauseAudioVoices];
        if(!_failure) {_runtime->cpu.call(0x8e13,{_runtime->game});[self checkFault];}
        [_audioMixer suspend];
    } else {
        _suspended=NO;
        if(!_audioSuspended)(void)[self tryResumeAudio];
    }
    _suspended=suspended;[self checkFault];
}
@end
