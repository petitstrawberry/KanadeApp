#import <Foundation/Foundation.h>

@class SFBInputSource;

SFBInputSource *SFBProgressiveInputSourceCreate(NSURL *url, NSInteger contentLength, NSURLSession *session);
