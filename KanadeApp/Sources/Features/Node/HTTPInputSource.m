#import "HTTPInputSource.h"

#import <objc/message.h>

@interface HTTPInputSource () <NSURLSessionDataDelegate>
@end

@implementation HTTPInputSource {
    NSCondition *_condition;
    NSMutableData *_buffer;
    NSURLSession *_session;
    NSURLSessionDataTask *_task;
    NSError *_streamError;
    NSInteger _bufferStartOffset;
    NSInteger _offset;
    NSInteger _length;
    BOOL _hasLength;
    BOOL _open;
    BOOL _finished;
    BOOL _eof;
    BOOL _acceptsRanges;
    BOOL _receivedResponse;
    BOOL _reading;
    NSString *_mimeTypeHint;
    NSURL *_url;
}

- (instancetype)initWithURL:(NSURL *)url mimeTypeHint:(NSString *)mimeTypeHint {
    struct objc_super superInfo = {
        .receiver = self,
        .super_class = [SFBInputSource class],
    };
    id (*sendSuperInit)(struct objc_super *, SEL) = (id (*)(struct objc_super *, SEL))objc_msgSendSuper;
    self = sendSuperInit(&superInfo, @selector(init));
    if(self) {
        _url = [url copy];
        _mimeTypeHint = [mimeTypeHint copy];
        _condition = [[NSCondition alloc] init];
        _buffer = [[NSMutableData alloc] init];
    }
    return self;
}

- (NSURL *)url {
    return _url;
}

- (NSString *)mimeTypeHint {
    return _mimeTypeHint;
}

- (NSString *)resolvedMimeTypeHint {
    [_condition lock];
    NSString *hint = _mimeTypeHint;
    [_condition unlock];
    if(hint.length) return hint;
    NSString *ext = _url.pathExtension.lowercaseString;
    if([ext isEqualToString:@"flac"]) return @"audio/flac";
    if([ext isEqualToString:@"mp3"]) return @"audio/mpeg";
    if([ext isEqualToString:@"m4a"] || [ext isEqualToString:@"mp4"] || [ext isEqualToString:@"m4b"]) return @"audio/mp4";
    if([ext isEqualToString:@"wav"]) return @"audio/wav";
    if([ext isEqualToString:@"ogg"] || [ext isEqualToString:@"oga"]) return @"audio/ogg";
    if([ext isEqualToString:@"opus"]) return @"audio/opus";
    if([ext isEqualToString:@"wma"]) return @"audio/x-ms-wma";
    if([ext isEqualToString:@"aiff"] || [ext isEqualToString:@"aif"]) return @"audio/aiff";
    if([ext isEqualToString:@"aac"]) return @"audio/aac";
    if([ext isEqualToString:@"dsf"]) return @"audio/x-dsf";
    if([ext isEqualToString:@"dff"] || [ext isEqualToString:@"dsdiff"]) return @"audio/x-dsdiff";
    if([ext isEqualToString:@"ape"]) return @"audio/x-ape";
    if([ext isEqualToString:@"wv"]) return @"audio/x-wavpack";
    return nil;
}

- (BOOL)openReturningError:(NSError **)error {
    [_condition lock];
    if(_open) {
        [_condition unlock];
        return YES;
    }

    _buffer = [[NSMutableData alloc] init];
    _streamError = nil;
    _bufferStartOffset = 0;
    _offset = 0;
    _length = 0;
    _hasLength = NO;
    _finished = NO;
    _eof = NO;
    _acceptsRanges = NO;
    _receivedResponse = NO;
    _reading = NO;
    _open = YES;
    [_condition unlock];

    [self startRequestFromOffset:0];

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
    [_condition lock];
    while(!_receivedResponse && !_streamError && !_finished) {
        if(![_condition waitUntilDate:deadline]) {
            break;
        }
    }

    NSError *streamError = _streamError;
    [_condition unlock];
    if(streamError) {
        if(error != NULL) {
            *error = streamError;
        }
        return NO;
    }

    if(_hasLength) {
        deadline = [NSDate dateWithTimeIntervalSinceNow:10];
        [_condition lock];
        while(_buffer.length < 131072 && !_streamError && !_finished) {
            if(![_condition waitUntilDate:deadline]) {
                break;
            }
        }
        [_condition unlock];
    }

    return YES;
}

- (BOOL)closeReturningError:(NSError **)error {
    [_condition lock];
    _open = NO;
    _reading = NO;
    _finished = YES;
    _eof = YES;
    [_condition broadcast];
    [_condition unlock];

    [_task cancel];
    [_session invalidateAndCancel];
    _task = nil;
    _session = nil;
    return YES;
}

- (BOOL)readBytes:(void *)buffer length:(NSInteger)length bytesRead:(NSInteger *)bytesRead error:(NSError **)error {
    if(bytesRead != NULL) {
        *bytesRead = 0;
    }

    [_condition lock];
    _reading = YES;
    while(_open && !_streamError && (_offset - _bufferStartOffset) >= (NSInteger)_buffer.length && !_finished) {
        [_condition wait];
    }
    _reading = NO;

    if(_streamError) {
        NSError *streamError = _streamError;
        [_condition unlock];
        if(error != NULL) {
            *error = streamError;
        }
        return NO;
    }

    NSInteger bufferOffset = _offset - _bufferStartOffset;
    NSInteger available = (NSInteger)_buffer.length - bufferOffset;
    if(available <= 0) {
        _eof = _finished;
        [_condition unlock];
        return YES;
    }

    NSInteger count = MIN(length, available);
    memcpy(buffer, ((const uint8_t *)_buffer.bytes) + bufferOffset, (size_t)count);
    _offset += count;
    _eof = _finished && (_offset - _bufferStartOffset) >= (NSInteger)_buffer.length;
    [_condition unlock];

    if(bytesRead != NULL) {
        *bytesRead = count;
    }
    return YES;
}

- (BOOL)getOffset:(NSInteger *)offset error:(NSError **)error {
    [_condition lock];
    NSInteger currentOffset = _offset;
    [_condition unlock];
    if(offset != NULL) {
        *offset = currentOffset;
    }
    return YES;
}

- (BOOL)getLength:(NSInteger *)length error:(NSError **)error {
    [_condition lock];
    BOOL hasLength = _hasLength || _finished;
    NSInteger currentLength = _hasLength ? _length : _bufferStartOffset + (NSInteger)_buffer.length;
    [_condition unlock];

    if(!hasLength) {
        if(error != NULL) {
            *error = [NSError errorWithDomain:SFBInputSourceErrorDomain code:SFBInputSourceErrorCodeInputOutput userInfo:nil];
        }
        return NO;
    }

    if(length != NULL) {
        *length = currentLength;
    }
    return YES;
}

- (BOOL)supportsSeeking {
    [_condition lock];
    BOOL seekable = _acceptsRanges && _hasLength;
    [_condition unlock];
    return seekable;
}

- (BOOL)seekToOffset:(NSInteger)offset error:(NSError **)error {
    [_condition lock];

    if(!_acceptsRanges || !_hasLength) {
        [_condition unlock];
        if(error != NULL) {
            *error = [NSError errorWithDomain:SFBInputSourceErrorDomain code:SFBInputSourceErrorCodeNotSeekable userInfo:nil];
        }
        return NO;
    }

    if(offset < 0 || offset > _length) {
        [_condition unlock];
        if(error != NULL) {
            *error = [NSError errorWithDomain:SFBInputSourceErrorDomain code:SFBInputSourceErrorCodeInputOutput userInfo:nil];
        }
        return NO;
    }

    NSInteger previousOffset = _offset;

    if(offset != previousOffset) {
        [_task cancel];
        _task = nil;
        [_session invalidateAndCancel];
        _session = nil;
        _receivedResponse = NO;
        _finished = NO;
        _eof = NO;
        _streamError = nil;
        [_condition broadcast];
        [_condition unlock];

        [self startRequestFromOffset:offset];

        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
        [_condition lock];
        while(!_receivedResponse && !_streamError && !_finished) {
            if(![_condition waitUntilDate:deadline]) {
                break;
            }
        }

        if(_streamError) {
            NSError *streamError = _streamError;
            [_condition unlock];
            if(error != NULL) {
                *error = streamError;
            }
            return NO;
        }
        [_condition unlock];
    } else {
        [_condition unlock];
    }

    return YES;
}

- (BOOL)isOpen {
    [_condition lock];
    BOOL open = _open;
    [_condition unlock];
    return open;
}

- (BOOL)atEOF {
    [_condition lock];
    BOOL eof = _eof;
    [_condition unlock];
    return eof;
}

- (void)startRequestFromOffset:(NSInteger)offset {
    [_condition lock];
    _offset = offset;
    _bufferStartOffset = offset;
    [_buffer setLength:0];
    _receivedResponse = NO;
    _finished = NO;
    _eof = NO;
    _streamError = nil;
    [_condition broadcast];
    [_condition unlock];

    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    configuration.timeoutIntervalForRequest = 30;
    configuration.timeoutIntervalForResource = 0;

    NSOperationQueue *delegateQueue = [[NSOperationQueue alloc] init];
    delegateQueue.maxConcurrentOperationCount = 1;
    _session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:delegateQueue];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:_url];
    request.HTTPMethod = @"GET";

    if(offset > 0 && _hasLength) {
        NSString *rangeHeader = [NSString stringWithFormat:@"bytes=%ld-", (long)offset];
        [request setValue:rangeHeader forHTTPHeaderField:@"Range"];
    }

    _task = [_session dataTaskWithRequest:request];
    [_task resume];
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    [_condition lock];
    if(session != _session || dataTask != _task) {
        [_condition unlock];
        completionHandler(NSURLSessionResponseCancel);
        return;
    }
    _receivedResponse = YES;

    if([response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        NSInteger statusCode = httpResponse.statusCode;

        if(statusCode >= 400 || statusCode == 304) {
            _streamError = [NSError errorWithDomain:NSURLErrorDomain code:statusCode userInfo:nil];
            [_condition broadcast];
            [_condition unlock];
            completionHandler(NSURLSessionResponseCancel);
            return;
        }

        if(!_mimeTypeHint.length && httpResponse.MIMEType.length) {
            _mimeTypeHint = [httpResponse.MIMEType copy];
        }

        NSString *acceptRanges = [httpResponse.allHeaderFields objectForKey:@"Accept-Ranges"];
        _acceptsRanges = acceptRanges != nil && [acceptRanges containsString:@"bytes"];

        if(statusCode == 206) {
            NSString *contentRange = [httpResponse.allHeaderFields objectForKey:@"Content-Range"];
            if(contentRange) {
                NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"bytes (\\d+)-\\d+/(\\d+)" options:0 error:nil];
                NSTextCheckingResult *match = [regex firstMatchInString:contentRange options:0 range:NSMakeRange(0, contentRange.length)];
                if(match.numberOfRanges == 3) {
                    _bufferStartOffset = [[contentRange substringWithRange:[match rangeAtIndex:1]] integerValue];
                    _length = [[contentRange substringWithRange:[match rangeAtIndex:2]] integerValue];
                    _hasLength = YES;
                }
            }
        } else if(statusCode == 200 && _offset > 0) {
            _bufferStartOffset = 0;
        }
    }

    if(response.expectedContentLength > 0 && !_hasLength) {
        _hasLength = YES;
        _length = (NSInteger)response.expectedContentLength;
    }

    [_condition broadcast];
    [_condition unlock];
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    [_condition lock];
    if(session != _session || dataTask != _task) {
        [_condition unlock];
        return;
    }
    [_buffer appendData:data];
    _eof = _finished && (_offset - _bufferStartOffset) >= (NSInteger)_buffer.length;
    [_condition broadcast];
    [_condition unlock];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    [_condition lock];
    if(session != _session || task != _task) {
        [_condition unlock];
        return;
    }
    if(error != nil && error.code != NSURLErrorCancelled) {
        _streamError = error;
    }
    _finished = YES;
    _eof = (_offset - _bufferStartOffset) >= (NSInteger)_buffer.length;
    [_condition broadcast];
    [_condition unlock];
}

@end
