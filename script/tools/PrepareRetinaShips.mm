// Created by Angelo Cammalleri on 29.10.2026.
// SPDX-License-Identifier: GPL-3.0-only
// Offline-only image exporter. Compile with the external GPL-3.0 xBRZ 1.9
// source, never with an application target. See Documentation/RetinaShip.md.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#include "xbrz.h"
#include <vector>
#include <algorithm>
int main(int argc,const char **argv) {
 @autoreleasepool {
  if(argc!=3)return 64;
  NSString *root=@(argv[1]),*output=@(argv[2]);
  [[NSFileManager defaultManager] createDirectoryAtPath:output withIntermediateDirectories:YES attributes:nil error:nil];
  for(int frame=1;frame<=25;++frame) {
   NSString *name=[NSString stringWithFormat:@"playerShip_%02d.png",frame];
   NSURL *url=[NSURL fileURLWithPath:[root stringByAppendingPathComponent:name]];
   CGImageSourceRef source=CGImageSourceCreateWithURL((__bridge CFURLRef)url,nullptr);
   CGImageRef image=source?CGImageSourceCreateImageAtIndex(source,0,nullptr):nullptr;
   if(!image||CGImageGetWidth(image)!=128||CGImageGetHeight(image)!=128)return 1;
   std::vector<uint8_t> rgba(128*128*4);
   CGColorSpaceRef space=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
   CGContextRef context=CGBitmapContextCreate(rgba.data(),128,128,8,128*4,space,CGBitmapInfo(kCGImageAlphaPremultipliedLast)|kCGBitmapByteOrder32Big);
   if(!context)return 1;
   CGContextDrawImage(context,CGRectMake(0,0,128,128),image);
   CGContextRelease(context);CGImageRelease(image);CFRelease(source);
   std::vector<uint32_t> argb(128*128);
   for(size_t p=0;p<argb.size();++p) {
    unsigned a=rgba[p*4+3];
    unsigned r=a?std::min(255u,(unsigned(rgba[p*4])*255+a/2)/a):0;
    unsigned g=a?std::min(255u,(unsigned(rgba[p*4+1])*255+a/2)/a):0;
    unsigned b=a?std::min(255u,(unsigned(rgba[p*4+2])*255+a/2)/a):0;
    argb[p]=(a<<24)|(r<<16)|(g<<8)|b;
   }
   for(int scale:{2,4}) {
    unsigned side=128*scale;
    std::vector<uint32_t> enlarged(side*side);
    xbrz::scale(scale,argb.data(),enlarged.data(),128,128,xbrz::ColorFormat::argb);
    std::vector<uint8_t> bytes(side*side*4);
    for(size_t p=0;p<enlarged.size();++p) {
     auto value=enlarged[p]; unsigned a=value>>24;
     bytes[p*4]=(value>>16)&255;
     bytes[p*4+1]=(value>>8)&255;
     bytes[p*4+2]=value&255;bytes[p*4+3]=a;
    }
    // Encode straight-alpha RGBA directly. A second premultiply/unpremultiply
    // round trip would quantize the thin translucent outline unnecessarily.
    CFDataRef data=CFDataCreate(nullptr,bytes.data(),bytes.size());
    CGDataProviderRef provider=CGDataProviderCreateWithCFData(data);
    CGImageRef result=CGImageCreate(side,side,8,32,side*4,space,
        CGBitmapInfo(kCGImageAlphaLast)|kCGBitmapByteOrder32Big,provider,nullptr,false,kCGRenderingIntentDefault);
    if(!result)return 1;
    NSString *directory=[output stringByAppendingPathComponent:[NSString stringWithFormat:@"%dx",scale]];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *destination=[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:name]];
    CGImageDestinationRef writer=CGImageDestinationCreateWithURL((__bridge CFURLRef)destination,CFSTR("public.png"),1,nullptr);
    CGImageDestinationAddImage(writer,result,nullptr);
    if(!CGImageDestinationFinalize(writer))return 1;
    CFRelease(writer);CGImageRelease(result);CGDataProviderRelease(provider);CFRelease(data);
   }
   CGColorSpaceRelease(space);
  }
 }
}
