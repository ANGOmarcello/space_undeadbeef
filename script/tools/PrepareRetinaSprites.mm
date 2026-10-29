// Created by Angelo Cammalleri on 29.10.2026.
// SPDX-License-Identifier: GPL-3.0-only
// Offline exporter only; never compile the external GPL-3.0 xBRZ into the app.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#include "xbrz.h"
#include <algorithm>
#include <vector>
#include <cstdio>
#include <cmath>

int main(int argc,const char **argv) { @autoreleasepool {
    if(argc!=4)return 64;
    NSString *root=@(argv[1]),*output=@(argv[2]);
    NSData *config=[NSData dataWithContentsOfFile:@(argv[3])];
    NSArray *entries=config?[NSJSONSerialization JSONObjectWithData:config options:0 error:nil]:nil;
    if(![entries isKindOfClass:NSArray.class]||entries.count!=16)return 1;
    CGColorSpaceRef space=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    for(NSDictionary *entry in entries) {
        NSString *name=entry[@"name"];
        const unsigned width=[entry[@"width"] unsignedIntValue],height=[entry[@"height"] unsignedIntValue];
        NSURL *url=[NSURL fileURLWithPath:[root stringByAppendingPathComponent:name]];
        CGImageSourceRef source=CGImageSourceCreateWithURL((__bridge CFURLRef)url,nullptr);
        CGImageRef image=source?CGImageSourceCreateImageAtIndex(source,0,nullptr):nullptr;
        if(source)CFRelease(source);
        if(!image||CGImageGetWidth(image)!=width||CGImageGetHeight(image)!=height)return 1;
        std::vector<uint8_t> rgba(size_t(width)*height*4);
        CGContextRef context=CGBitmapContextCreate(rgba.data(),width,height,8,width*4,space,
            CGBitmapInfo(kCGImageAlphaPremultipliedLast)|kCGBitmapByteOrder32Big);
        if(!context)return 1;
        CGContextDrawImage(context,CGRectMake(0,0,width,height),image);
        CGContextRelease(context);CGImageRelease(image);
        std::vector<uint32_t> argb(size_t(width)*height);
        for(size_t p=0;p<argb.size();++p) {
            const unsigned a=rgba[p*4+3];
            const auto channel=[&](unsigned k){return a?std::min(255u,(unsigned(rgba[p*4+k])*255+a/2)/a):0;};
            argb[p]=(a<<24)|(channel(0)<<16)|(channel(1)<<8)|channel(2);
        }
        for(unsigned scale:{2u,4u}) {
            const unsigned w=width*scale,h=height*scale;
            std::vector<uint32_t> enlarged(size_t(w)*h);
            NSArray *frames=entry[@"frames"];
            if([entry[@"filter"] isEqualToString:@"linear"]) {
                // Soft light has no hard contour to reconstruct. Preserve the
                // original linear gradient instead of creating xBRZ color bands.
                const auto sample=[&](int x,int y){return argb[size_t(std::clamp(y,0,int(height)-1))*width+std::clamp(x,0,int(width)-1)];};
                for(unsigned y=0;y<h;++y)for(unsigned x=0;x<w;++x) {
                    const double sx=(x+.5)/scale-.5,sy=(y+.5)/scale-.5;
                    const int ix=int(std::floor(sx)),iy=int(std::floor(sy));
                    const double fx=sx-ix,fy=sy-iy;
                    const uint32_t p[]={sample(ix,iy),sample(ix+1,iy),sample(ix,iy+1),sample(ix+1,iy+1)};
                    uint32_t value=0;
                    for(unsigned shift:{0u,8u,16u,24u}) {
                        const auto channel=[&](unsigned i){return double((p[i]>>shift)&255);};
                        const auto v=std::lround((channel(0)*(1-fx)+channel(1)*fx)*(1-fy)+(channel(2)*(1-fx)+channel(3)*fx)*fy);
                        value|=uint32_t(v)<<shift;
                    }
                    enlarged[size_t(y)*w+x]=value;
                }
            } else if(frames) {
                // Preserve unused cells/gaps. Scale frames without neighbours.
                for(unsigned y=0;y<h;++y)for(unsigned x=0;x<w;++x)
                    enlarged[size_t(y)*w+x]=argb[size_t(y/scale)*width+x/scale];
                for(NSArray *frame in frames) {
                    if(frame.count!=4)return 1;
                    const unsigned x=[frame[0] unsignedIntValue],y=[frame[1] unsignedIntValue],
                        fw=[frame[2] unsignedIntValue],fh=[frame[3] unsignedIntValue];
                    if(!fw||!fh||x+fw>width||y+fh>height)return 1;
                    std::vector<uint32_t> crop(size_t(fw)*fh),scaled(size_t(fw)*fh*scale*scale);
                    for(unsigned row=0;row<fh;++row)
                        std::copy_n(argb.data()+size_t(y+row)*width+x,fw,crop.data()+size_t(row)*fw);
                    xbrz::scale(scale,crop.data(),scaled.data(),fw,fh,xbrz::ColorFormat::argb);
                    for(unsigned row=0;row<fh*scale;++row)
                        std::copy_n(scaled.data()+size_t(row)*fw*scale,fw*scale,
                            enlarged.data()+size_t(y*scale+row)*w+x*scale);
                }
            } else {
                xbrz::scale(scale,argb.data(),enlarged.data(),width,height,xbrz::ColorFormat::argb);
            }
            std::vector<uint8_t> bytes(size_t(w)*h*4);
            for(size_t p=0;p<enlarged.size();++p) {
                const uint32_t value=enlarged[p];
                bytes[p*4]=(value>>16)&255;bytes[p*4+1]=(value>>8)&255;
                bytes[p*4+2]=value&255;bytes[p*4+3]=value>>24;
            }
            CFDataRef data=CFDataCreate(nullptr,bytes.data(),bytes.size());
            CGDataProviderRef provider=CGDataProviderCreateWithCFData(data);
            CGImageRef result=CGImageCreate(w,h,8,32,w*4,space,
                CGBitmapInfo(kCGImageAlphaLast)|kCGBitmapByteOrder32Big,provider,nullptr,false,kCGRenderingIntentDefault);
            if(!result)return 1;
            NSString *directory=[output stringByAppendingPathComponent:[NSString stringWithFormat:@"%ux",scale]];
            if(![[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil])return 1;
            NSURL *destination=[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:name]];
            CGImageDestinationRef writer=CGImageDestinationCreateWithURL((__bridge CFURLRef)destination,CFSTR("public.png"),1,nullptr);
            if(!writer)return 1;
            CGImageDestinationAddImage(writer,result,nullptr);
            if(!CGImageDestinationFinalize(writer))return 1;
            CFRelease(writer);CGImageRelease(result);CGDataProviderRelease(provider);CFRelease(data);
        }
        std::printf("Prepared %s\n",name.UTF8String);
    }
    CGColorSpaceRelease(space);
    return 0;
}}
