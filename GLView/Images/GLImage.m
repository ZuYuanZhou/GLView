//
//  GLImage.m
//
//  GLView Project
//  Version 1.2.2
//
//  Created by Nick Lockwood on 10/07/2011.
//  Copyright 2011 Charcoal Design
//
//  Distributed under the permissive zlib License
//  Get the latest version from either of these locations:
//
//  http://charcoaldesign.co.uk/source/cocoa#glview
//  https://github.com/nicklockwood/GLView
//
//  This software is provided 'as-is', without any express or implied
//  warranty.  In no event will the authors be held liable for any damages
//  arising from the use of this software.
//
//  Permission is granted to anyone to use this software for any purpose,
//  including commercial applications, and to alter it and redistribute it
//  freely, subject to the following restrictions:
//
//  1. The origin of this software must not be misrepresented; you must not
//  claim that you wrote the original software. If you use this software
//  in a product, an acknowledgment in the product documentation would be
//  appreciated but is not required.
//
//  2. Altered source versions must be plainly marked as such, and must not be
//  misrepresented as being the original software.
//
//  3. This notice may not be removed or altered from any source distribution.
//

#import "GLImage.h"
#import "GLView.h"
#import <QuartzCore/QuartzCore.h>
#import <OpenGLES/ES1/gl.h>
#import <OpenGLES/ES1/glext.h>


typedef struct
{
    GLuint headerSize;
    GLuint height;
    GLuint width;
    GLuint mipmapCount;
    GLuint pixelFormatFlags;
    GLuint textureDataSize;
    GLuint bitCount; 
    GLuint redBitMask;
    GLuint greenBitMask;
    GLuint blueBitMask;
    GLuint alphaBitMask;
    GLuint magicNumber;
    GLuint surfaceCount;
}
PVRTextureHeader;


typedef enum
{
    OGL_RGBA_4444 = 0x10,
    OGL_RGBA_5551,
    OGL_RGBA_8888,
    OGL_RGB_565,
    OGL_RGB_555,
    OGL_RGB_888,
    OGL_I_8,
    OGL_AI_88,
    OGL_PVRTC2,
    OGL_PVRTC4
}
PVRPixelType;


@interface GLView (Private)

+ (EAGLContext *)sharedContext;

@end


@interface GLImage ()

@property (nonatomic, assign) CGSize size;
@property (nonatomic, assign) CGFloat scale;
@property (nonatomic, assign) CGSize textureSize;
@property (nonatomic, assign) CGRect clipRect;
@property (nonatomic, assign) GLuint texture;
@property (nonatomic, assign) BOOL premultipliedAlpha;

@end


@implementation GLImage

@synthesize size = _size;
@synthesize scale = _scale;
@synthesize texture = _texture;
@synthesize textureSize = _textureSize;
@synthesize clipRect = _clipRect;
@synthesize premultipliedAlpha = _premultipliedAlpha;


#pragma mark -
#pragma mark Utils

+ (NSString *)scaleSuffixForImagePath:(NSString *)nameOrPath
{
    nameOrPath = [nameOrPath stringByDeletingPathExtension];
    if ([nameOrPath length] >= 3)
    {
        NSString *scaleSuffix = [nameOrPath substringFromIndex:[nameOrPath length] - 3];
        if ([[scaleSuffix substringToIndex:1] isEqualToString:@"@"] &&
            [[scaleSuffix substringFromIndex:2] isEqualToString:@"x"])
        {
            return scaleSuffix;
        }
    }
    return nil;
}

+ (NSString *)normalisedImagePath:(NSString *)nameOrPath
{
    //get or add file extension
    NSString *extension = [nameOrPath pathExtension];
    if ([extension isEqualToString:@""])
    {
        extension = @"png";
        nameOrPath = [nameOrPath stringByAppendingPathExtension:extension];
    }
    
    //convert to absolute path
    if (![nameOrPath isAbsolutePath])
    {
        nameOrPath = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:nameOrPath];
    }
    
    //get or add scale suffix
    NSString *scaleSuffix = [self scaleSuffixForImagePath:nameOrPath];
    if (!scaleSuffix)
    {
        scaleSuffix = [NSString stringWithFormat:@"@%ix", (int)[[UIScreen mainScreen] scale]];
        NSString *path = [[[nameOrPath stringByDeletingPathExtension] stringByAppendingString:scaleSuffix] stringByAppendingPathExtension:extension];
        if ([[NSFileManager defaultManager] fileExistsAtPath:path])
        {
            nameOrPath = path;
        }
    }
    
    //return normalised path
    return nameOrPath;
}

+ (CGSize)textureSizeForSize:(CGSize)size scale:(CGFloat)scale
{
    return CGSizeMake(powf(2.0f, ceilf(log2f(size.width * scale))),
                      powf(2.0f, ceilf(log2f(size.height * scale))));
}


#pragma mark -
#pragma mark Caching

static NSCache *imageCache = nil;

+ (void)initialize
{
    imageCache = [[NSCache alloc] init];
}

+ (GLImage *)imageNamed:(NSString *)nameOrPath
{
    NSString *path = [self normalisedImagePath:nameOrPath];
    GLImage *image = nil;
    if (path)
    {
        image = [imageCache objectForKey:path];
        if (!image)
        {
            image = [self imageWithContentsOfFile:path];
            if (image)
            {
                [imageCache setObject:image forKey:path];
            }
        }
    }
    return image;
}


#pragma mark -
#pragma mark Loading

+ (GLImage *)imageWithContentsOfFile:(NSString *)nameOrPath
{
    return AH_AUTORELEASE([[self alloc] initWithContentsOfFile:nameOrPath]);
}

+ (GLImage *)imageWithUIImage:(UIImage *)image
{
    return AH_AUTORELEASE([[self alloc] initWithUIImage:image]);
}

+ (GLImage *)imageWithSize:(CGSize)size scale:(CGFloat)scale drawingBlock:(GLImageDrawingBlock)drawingBlock
{
    return AH_AUTORELEASE([[self alloc] initWithSize:size scale:scale drawingBlock:drawingBlock]);
}

- (GLImage *)initWithContentsOfFile:(NSString *)nameOrPath
{
    NSString *path = [[self class] normalisedImagePath:nameOrPath];
    NSString *extension = [[path pathExtension] lowercaseString];
    if ([extension isEqualToString:@"pvr"] || [extension isEqualToString:@"pvrtc"])
    {
        if ((self = [super init]))
        {
            //get scale factor
            NSString *scaleSuffix = [[self class] scaleSuffixForImagePath:path];
            self.scale = scaleSuffix? [[scaleSuffix substringWithRange:NSMakeRange(1, 1)] floatValue]: 1.0;
            
            //load data
            NSData *data = [NSData dataWithContentsOfFile:path];
            if (!data)
            {
                //bail early before something bad happens
                AH_RELEASE(self);
                return nil;
            }
            
            if ([data length] < sizeof(PVRTextureHeader))
            {
                //can't be correct file type
                NSLog(@"PVR image data was not in a recognised format, or is missing header information");
                AH_RELEASE(self);
                return nil;
            }
            
            //parse header
            PVRTextureHeader *header = (PVRTextureHeader *)[data bytes];
            
            //check magic number
            if (CFSwapInt32HostToBig(header->magicNumber) != 'PVR!')
            {
                NSLog(@"PVR image data was not in a recognised format, or is missing header information");
                AH_RELEASE(self);
                return nil;
            }
            
            //dimensions
            GLint width = header->width;
            GLint height = header->height;
            self.size = CGSizeMake((float)width/self.scale, (float)height/self.scale);
            self.textureSize = CGSizeMake(width, height);
            self.clipRect = CGRectMake(0.0f, 0.0f, width, height);
            
            //format
            BOOL compressed;
            NSInteger bitsPerPixel;
            GLuint type;
            GLuint format;
            self.premultipliedAlpha = NO;
            BOOL hasAlpha = header->alphaBitMask;
            switch (header->pixelFormatFlags & 0xff)
            {
                case OGL_RGB_565:
                {
                    compressed = NO;
                    bitsPerPixel = 16;
                    format = GL_RGB;
                    type = GL_UNSIGNED_SHORT_5_6_5;
                    break;
                }
                case OGL_RGBA_5551:
                {
                    compressed = NO;
                    bitsPerPixel = 16;
                    format = GL_RGBA;
                    type = GL_UNSIGNED_SHORT_5_5_5_1;
                    break;
                }
                case OGL_RGBA_4444:
                {
                    compressed = NO;
                    bitsPerPixel = 16;
                    format = GL_RGBA;
                    type = GL_UNSIGNED_SHORT_4_4_4_4;
                    break;
                }
                case OGL_RGBA_8888:
                {
                    compressed = NO;
                    bitsPerPixel = 32;
                    format = GL_RGBA;
                    type = GL_UNSIGNED_BYTE;
                    break;
                }
                case OGL_I_8:
                {
                    NSLog(@"I8 PVR format is not currently supported");
                    AH_RELEASE(self);
                    return nil;
                }
                case OGL_AI_88:
                {
                    NSLog(@"AI88 PVR format is not currently supported");
                    AH_RELEASE(self);
                    return nil;
                }
                case OGL_PVRTC2:
                {
                    compressed = YES;
                    bitsPerPixel = 2;
                    format = hasAlpha? GL_COMPRESSED_RGBA_PVRTC_2BPPV1_IMG: GL_COMPRESSED_RGB_PVRTC_2BPPV1_IMG;
                    type = 0;
                    break;
                }
                case OGL_PVRTC4:
                {
                    compressed = YES;
                    bitsPerPixel = 4;
                    format = hasAlpha? GL_COMPRESSED_RGBA_PVRTC_4BPPV1_IMG: GL_COMPRESSED_RGB_PVRTC_4BPPV1_IMG;
                    type = 0;
                    break;
                }
                default:
                {
                    NSLog(@"Unrecognised PVR image format: %i", header->pixelFormatFlags & 0xff);
                    AH_RELEASE(self);
                    return nil;
                }
            }
            
            //bind context
            [EAGLContext setCurrentContext:[GLView performSelector:@selector(sharedContext)]];
            
            //create texture
            glGenTextures(1, &_texture);
            glBindTexture(GL_TEXTURE_2D, self.texture);
            glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_LINEAR); 
            glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
            if (compressed)
            {
                glCompressedTexImage2D(GL_TEXTURE_2D, 0, format, width, height, 0,
                                       MAX(32, width * height * bitsPerPixel / 8),
                                       [data bytes] + header->headerSize);
            }
            else
            {
                glTexImage2D(GL_TEXTURE_2D, 0, format, width, height, 0, format, type,
                             [data bytes] + header->headerSize);
            }
        }
        return self;
    }
    else
    {
        return [self initWithUIImage:[UIImage imageWithContentsOfFile:path]];
    }
}

- (GLImage *)initWithUIImage:(UIImage *)image
{
    return [self initWithSize:image.size scale:image.scale drawingBlock:^(CGContextRef context)
    {
        [image drawAtPoint:CGPointZero];
    }];
}

- (GLImage *)initWithSize:(CGSize)size scale:(CGFloat)scale drawingBlock:(GLImageDrawingBlock)drawingBlock
{
    if ((self = [super init]))
    {
        //dimensions and scale
        self.scale = scale;
        self.size = size;
        self.textureSize = [GLImage textureSizeForSize:size scale:scale];
        GLint width = self.textureSize.width;
        GLint height = self.textureSize.height;
        
        //clip rect
        self.clipRect = CGRectMake(0.0f, 0.0f, size.width * scale, size.height * scale);
        
        //alpha
        self.premultipliedAlpha = YES;
        
        //create cg context
        void *imageData = calloc(height * width, 4);
        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        CGContextRef context = CGBitmapContextCreate(imageData, width, height, 8, 4 * width, colorSpace,
                                                     kCGBitmapByteOrder32Big | kCGImageAlphaPremultipliedLast);
        CGColorSpaceRelease(colorSpace);
        
        //perform drawing
        CGContextTranslateCTM(context, 0, height);
        CGContextScaleCTM(context, self.scale, -self.scale);
        UIGraphicsPushContext(context);
        if (drawingBlock) drawingBlock(context);
        UIGraphicsPopContext();
        
        //bind gl context
        if (![EAGLContext currentContext])
        {
            [EAGLContext setCurrentContext:[GLView sharedContext]];
        }
        
        //create texture
        glGenTextures(1, &_texture);
        glBindTexture(GL_TEXTURE_2D, self.texture);
        glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_LINEAR); 
        glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, imageData);
        
        //free cg context
        CGContextRelease(context);
        free(imageData);
    }
    return self;
}

- (void)dealloc
{     
    glDeleteTextures(1, &_texture);
    AH_SUPER_DEALLOC;
}


#pragma mark -
#pragma mark Drawing

- (void)bindTexture
{
    glEnable(GL_TEXTURE_2D);
    glEnable(GL_BLEND);
    glBlendFunc(self.premultipliedAlpha? GL_ONE: GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    
    glBindTexture(GL_TEXTURE_2D, self.texture);
}

- (void)drawAtPoint:(CGPoint)point
{
    [self drawInRect:CGRectMake(point.x, point.y, self.size.width, self.size.height)];
}

- (void)drawInRect:(CGRect)rect
{    
    GLfloat vertices[] =
    {
        rect.origin.x, rect.origin.y,
        rect.origin.x + rect.size.width, rect.origin.y,
        rect.origin.x + rect.size.width, rect.origin.y + rect.size.height,
        rect.origin.x, rect.origin.y + rect.size.height
    };
    
    CGRect clipRect = self.clipRect;
    clipRect.origin.x /= self.textureSize.width;
    clipRect.origin.y /= self.textureSize.height;
    clipRect.size.width /= self.textureSize.width;
    clipRect.size.height /= self.textureSize.height;
    
    GLfloat texCoords[] =
    {
        clipRect.origin.x, clipRect.origin.y,
        clipRect.origin.x + clipRect.size.width, clipRect.origin.y,
        clipRect.origin.x + clipRect.size.width, clipRect.origin.y + clipRect.size.height,
        clipRect.origin.x, clipRect.origin.y + clipRect.size.height
    };
    
    [self bindTexture];
    
    glEnableClientState(GL_VERTEX_ARRAY);
    glEnableClientState(GL_TEXTURE_COORD_ARRAY);
    glDisableClientState(GL_NORMAL_ARRAY);
    
    glVertexPointer(2, GL_FLOAT, 0, vertices);
    glTexCoordPointer(2, GL_FLOAT, 0, texCoords);
    glDrawArrays(GL_TRIANGLE_FAN, 0, 4);
}

@end