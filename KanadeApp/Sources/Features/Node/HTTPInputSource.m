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
    NSInteger _offset;
    NSInteger _length;
    BOOL _hasLength;
    BOOL _open;
    BOOL _finished;
    BOOL _eof;
    BOOL _seekable;
    BOOL _receivedResponse;
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

- (BOOL)openReturningError:(NSError **)error {
    [_condition lock];
    if(_open) {
        [_condition unlock];
        return YES;
    }

    _buffer = [[NSMutableData alloc] init];
    _streamError = nil;
    _offset = 0;
    _length = 0;
    _hasLength = NO;
    _finished = NO;
    _eof = NO;
    _seekable = NO;
    _receivedResponse = NO;
    _open = YES;
    [_condition unlock];

    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    configuration.timeoutIntervalForRequest = 30;
    configuration.timeoutIntervalForResource = 0;

    NSOperationQueue *delegateQueue = [[NSOperationQueue alloc] init];
    delegateQueue.maxConcurrentOperationCount = 1;
    _session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:delegateQueue];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:_url];
    request.HTTPMethod = @"GET";
    _task = [_session dataTaskWithRequest:request];
    [_task resume];

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

    return YES;
}

- (BOOL)closeReturningError:(NSError **)error {
    [_condition lock];
    _open = NO;
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
    while(_open && !_streamError && _offset >= (NSInteger)_buffer.length && !_finished) {
        [_condition wait];
    }

    if(_streamError) {
        NSError *streamError = _streamError;
        [_condition unlock];
        if(error != NULL) {
            *error = streamError;
        }
        return NO;
    }

    NSInteger available = (NSInteger)_buffer.length - _offset;
    if(available <= 0) {
        _eof = _finished;
        [_condition unlock];
        return NO;
    }

    NSInteger count = MIN(length, available);
    memcpy(buffer, ((const uint8_t *)_buffer.bytes) + _offset, (size_t)count);
    _offset += count;
    _eof = _finished && _offset >= (NSInteger)_buffer.length;
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
    NSInteger currentLength = _hasLength ? _length : (NSInteger)_buffer.length;
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
    BOOL seekable = _seekable && (_hasLength || _finished);
    [_condition unlock];
    return seekable;
}

- (BOOL)seekToOffset:(NSInteger)offset error:(NSError **)error {
    [_condition lock];
    BOOL seekable = _seekable && (_hasLength || _finished);
    NSInteger maximumLength = _hasLength ? _length : (NSInteger)_buffer.length;
    if(seekable && offset >= 0 && offset <= maximumLength) {
        _offset = offset;
        _eof = _finished && _offset >= (NSInteger)_buffer.length;
        [_condition unlock];
        return YES;
    }
    [_condition unlock];

    if(error != NULL) {
        *error = [NSError errorWithDomain:SFBInputSourceErrorDomain code:SFBInputSourceErrorCodeNotSeekable userInfo:nil];
    }
    return NO;
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

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    [_condition lock];
    _receivedResponse = YES;

    if([response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        NSInteger statusCode = httpResponse.statusCode;
        if(statusCode < 200 || statusCode >= 300) {
            _streamError = [NSError errorWithDomain:NSURLErrorDomain code:statusCode userInfo:nil];
            [_condition broadcast];
            [_condition unlock];
            completionHandler(NSURLSessionResponseCancel);
            return;
        }

        if(!_mimeTypeHint.length && httpResponse.MIMEType.length) {
            _mimeTypeHint = [httpResponse.MIMEType copy];
        }
    }

    if(response.expectedContentLength > 0) {
        _hasLength = YES;
        _length = (NSInteger)response.expectedContentLength;
    }

    [_condition broadcast];
    [_condition unlock];
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    [_condition lock];
    [_buffer appendData:data];
    _eof = _finished && _offset >= (NSInteger)_buffer.length;
    [_condition broadcast];
    [_condition unlock];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    [_condition lock];
    if(error != nil && error.code != NSURLErrorCancelled) {
        _streamError = error;
    }
    _finished = YES;
    _seekable = _streamError == nil;
    _eof = _offset >= (NSInteger)_buffer.length;
    [_condition broadcast];
    [_condition unlock];
}

@end
