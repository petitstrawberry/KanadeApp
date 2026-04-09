#import "HTTPInputSource.h"

#import <dispatch/dispatch.h>
#import <errno.h>
#import <fcntl.h>
#import <unistd.h>

static const NSInteger kInitialBufferThreshold = 131072;
static const NSInteger kMaxReconnectAttempts = 5;

@interface SFBInputSource ()
- (instancetype)initWithURL:(nullable NSURL *)url;
@end

@interface HTTPInputSource () <NSURLSessionDataDelegate>
@end

@implementation HTTPInputSource {
    NSCondition *_condition;
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
    NSURL *_tempFileURL;
    NSInteger _downloadedBytes;
    int _fileDescriptor;
    NSInteger _retryCount;
    NSInteger _reconnectGeneration;
    NSInteger _requestOffset;
    BOOL _requestRequiresResumeValidation;
    NSError *_pendingCompletionError;
    BOOL _pendingCompletionShouldRetry;
    NSOperationQueue *_delegateQueue;
}

- (instancetype)initWithURL:(NSURL *)url mimeTypeHint:(NSString *)mimeTypeHint {
    self = [super initWithURL:url];
    if(self) {
        _url = [url copy];
        _mimeTypeHint = [mimeTypeHint copy];
        _condition = [[NSCondition alloc] init];
        _fileDescriptor = -1;
        _delegateQueue = [[NSOperationQueue alloc] init];
        _delegateQueue.maxConcurrentOperationCount = 1;
    }
    return self;
}

- (void)dealloc {
    [self cleanupResources];
}

- (NSURL *)url {
    return _url;
}

- (NSString *)mimeTypeHint {
    [_condition lock];
    NSString *mimeTypeHint = _mimeTypeHint;
    [_condition unlock];
    return mimeTypeHint;
}

- (NSURL *)tempFileURL {
    [_condition lock];
    NSURL *tempFileURL = [_tempFileURL copy];
    [_condition unlock];
    return tempFileURL;
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
    [_condition unlock];

    NSError *tempFileError = nil;
    NSURL *tempFileURL = nil;
    int fileDescriptor = [self createTemporaryFileReturningURL:&tempFileURL error:&tempFileError];
    if(fileDescriptor < 0) {
        if(error != NULL) {
            *error = tempFileError;
        }
        return NO;
    }

    [_condition lock];
    _tempFileURL = [tempFileURL copy];
    _fileDescriptor = fileDescriptor;
    _streamError = nil;
    _bufferStartOffset = 0;
    _offset = 0;
    _length = 0;
    _hasLength = NO;
    _open = YES;
    _finished = NO;
    _eof = NO;
    _acceptsRanges = NO;
    _receivedResponse = NO;
    _reading = NO;
    _downloadedBytes = 0;
    _retryCount = 0;
    _reconnectGeneration = 0;
    _requestOffset = 0;
    _requestRequiresResumeValidation = NO;
    _pendingCompletionError = nil;
    _pendingCompletionShouldRetry = NO;
    [_condition unlock];

    [self startRequestFromOffset:0 requiresResumeValidation:NO];

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
    [_condition lock];
    while(!_receivedResponse && !_streamError && !_finished) {
        if(![_condition waitUntilDate:deadline]) {
            break;
        }
    }

    NSError *streamError = _streamError;
    BOOL hasLength = _hasLength;
    [_condition unlock];

    if(streamError) {
        [self closeReturningError:nil];
        if(error != NULL) {
            *error = streamError;
        }
        return NO;
    }

    if(hasLength) {
        deadline = [NSDate dateWithTimeIntervalSinceNow:10];
        [_condition lock];
        while(_downloadedBytes < kInitialBufferThreshold && !_streamError && !_finished) {
            if(![_condition waitUntilDate:deadline]) {
                break;
            }
        }
        streamError = _streamError;
        [_condition unlock];

        if(streamError) {
            [self closeReturningError:nil];
            if(error != NULL) {
                *error = streamError;
            }
            return NO;
        }
    }

    return YES;
}

- (BOOL)closeReturningError:(NSError **)error {
    [self cleanupResources];
    return YES;
}

- (BOOL)readBytes:(void *)buffer length:(NSInteger)length bytesRead:(NSInteger *)bytesRead error:(NSError **)error {
    if(bytesRead != NULL) {
        *bytesRead = 0;
    }
    if(length <= 0) {
        return YES;
    }

    NSInteger requestedOffset = 0;
    NSInteger available = 0;
    int fileDescriptor = -1;

    [_condition lock];
    _reading = YES;
    while(_open && !_streamError && _offset >= _downloadedBytes && !_finished) {
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

    if(_offset >= _downloadedBytes && _finished) {
        [self updateEOFLocked];
        [_condition unlock];
        return YES;
    }

    requestedOffset = _offset;
    available = _downloadedBytes - requestedOffset;
    fileDescriptor = _fileDescriptor;
    [_condition unlock];

    NSInteger requestedCount = MIN(length, available);
    NSError *readError = nil;
    ssize_t readCount = [self readFromFileDescriptor:fileDescriptor buffer:buffer length:requestedCount offset:requestedOffset error:&readError];
    if(readCount < 0) {
        [_condition lock];
        if(_streamError == nil) {
            _streamError = readError;
            _finished = YES;
            [self updateEOFLocked];
            [_condition broadcast];
        }
        NSError *streamError = _streamError;
        [_condition unlock];
        if(error != NULL) {
            *error = streamError;
        }
        return NO;
    }

    [_condition lock];
    if(_offset == requestedOffset) {
        _offset += readCount;
    }
    [self updateEOFLocked];
    [_condition unlock];

    if(bytesRead != NULL) {
        *bytesRead = readCount;
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
    NSInteger currentLength = _hasLength ? _length : _downloadedBytes;
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
    BOOL hasLength = _hasLength;

    if(offset < 0) {
        [_condition unlock];
        if(error != NULL) {
            *error = [NSError errorWithDomain:SFBInputSourceErrorDomain code:SFBInputSourceErrorCodeInputOutput userInfo:nil];
        }
        return NO;
    }

    if(offset <= _downloadedBytes) {
        _offset = offset;
        [self updateEOFLocked];
        [_condition broadcast];
        [_condition unlock];
        return YES;
    }

    if(hasLength && offset <= _length) {
        _offset = offset;
        [self updateEOFLocked];
        [_condition broadcast];
        [_condition unlock];
        return YES;
    }
    
    [_condition unlock];
    if(error != NULL) {
        NSInteger code = hasLength ? SFBInputSourceErrorCodeInputOutput : SFBInputSourceErrorCodeNotSeekable;
        *error = [NSError errorWithDomain:SFBInputSourceErrorDomain code:code userInfo:nil];
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

- (void)reconnectFromDownloadedBytes {
    [_condition lock];
    if(!_open || _fileDescriptor < 0) {
        [_condition unlock];
        return;
    }
    NSInteger downloadedBytes = _downloadedBytes;
    [_condition unlock];

    [self startRequestFromOffset:downloadedBytes requiresResumeValidation:YES];
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    [_condition lock];
    if(session != _session || dataTask != _task) {
        [_condition unlock];
        completionHandler(NSURLSessionResponseCancel);
        return;
    }

    _pendingCompletionError = nil;
    _pendingCompletionShouldRetry = NO;

    if([response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        NSInteger statusCode = httpResponse.statusCode;

        if([self isRetryableHTTPStatusCode:statusCode]) {
            _receivedResponse = NO;
            _pendingCompletionError = [self HTTPErrorForStatusCode:statusCode URL:_url];
            _pendingCompletionShouldRetry = YES;
            [_condition broadcast];
            [_condition unlock];
            completionHandler(NSURLSessionResponseCancel);
            return;
        }

        if([self isTerminalHTTPStatusCode:statusCode] || statusCode < 200 || statusCode >= 300) {
            _receivedResponse = YES;
            _streamError = [self HTTPErrorForStatusCode:statusCode URL:_url];
            _finished = YES;
            [self updateEOFLocked];
            [_condition broadcast];
            [_condition unlock];
            completionHandler(NSURLSessionResponseCancel);
            return;
        }

        if(!_mimeTypeHint.length && httpResponse.MIMEType.length) {
            _mimeTypeHint = [httpResponse.MIMEType copy];
        }

        NSString *acceptRanges = [self headerValueForKey:@"Accept-Ranges" headers:httpResponse.allHeaderFields];
        _acceptsRanges = acceptRanges != nil && [[acceptRanges lowercaseString] containsString:@"bytes"];

        if(_requestRequiresResumeValidation) {
            if(statusCode != 206) {
                _streamError = [self invalidResumeResponseErrorForStatusCode:statusCode expectedOffset:_requestOffset];
                _finished = YES;
                [self updateEOFLocked];
                [_condition broadcast];
                [_condition unlock];
                completionHandler(NSURLSessionResponseCancel);
                return;
            }

            NSInteger contentRangeStart = NSNotFound;
            NSInteger totalLength = NSNotFound;
            NSString *contentRange = [self headerValueForKey:@"Content-Range" headers:httpResponse.allHeaderFields];
            if(![self parseContentRange:contentRange start:&contentRangeStart totalLength:&totalLength] || contentRangeStart != _requestOffset) {
                _streamError = [self invalidResumeResponseErrorForStatusCode:statusCode expectedOffset:_requestOffset];
                _finished = YES;
                [self updateEOFLocked];
                [_condition broadcast];
                [_condition unlock];
                completionHandler(NSURLSessionResponseCancel);
                return;
            }

            if(totalLength != NSNotFound) {
                _hasLength = YES;
                _length = totalLength;
            }
        } else if(statusCode == 206) {
            NSInteger contentRangeStart = NSNotFound;
            NSInteger totalLength = NSNotFound;
            NSString *contentRange = [self headerValueForKey:@"Content-Range" headers:httpResponse.allHeaderFields];
            if([self parseContentRange:contentRange start:&contentRangeStart totalLength:&totalLength]) {
                if(totalLength != NSNotFound) {
                    _hasLength = YES;
                    _length = totalLength;
                }
            }
        }
    }

    if(response.expectedContentLength > 0) {
        if(_requestRequiresResumeValidation) {
            NSInteger inferredLength = _requestOffset + (NSInteger)response.expectedContentLength;
            if(!_hasLength || _length < inferredLength) {
                _hasLength = YES;
                _length = inferredLength;
            }
        } else if(!_hasLength) {
            _hasLength = YES;
            _length = (NSInteger)response.expectedContentLength;
        }
    }

    _receivedResponse = YES;
    _retryCount = 0;
    [self updateEOFLocked];
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

    NSInteger writeOffset = _downloadedBytes;
    int fileDescriptor = _fileDescriptor;
    [_condition unlock];

    NSError *writeError = nil;
    BOOL didWrite = [self writeData:data toFileDescriptor:fileDescriptor offset:writeOffset error:&writeError];

    [_condition lock];
    if(session != _session || dataTask != _task) {
        [_condition unlock];
        return;
    }

    if(!didWrite) {
        if(_streamError == nil) {
            _streamError = writeError;
            _finished = YES;
            [self updateEOFLocked];
            [_condition broadcast];
        }
        [_condition unlock];
        [dataTask cancel];
        return;
    }

    _downloadedBytes += data.length;
    [self updateEOFLocked];
    [_condition broadcast];
    [_condition unlock];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    NSInteger reconnectGeneration = NSNotFound;
    NSError *completionError = nil;
    BOOL shouldRetry = NO;

    [_condition lock];
    if(session != _session || task != _task) {
        [_condition unlock];
        return;
    }

    _session = nil;
    _task = nil;

    if(_streamError != nil) {
        _finished = YES;
        [self updateEOFLocked];
        [_condition broadcast];
        [_condition unlock];
        [session finishTasksAndInvalidate];
        return;
    }

    if(_pendingCompletionError != nil) {
        completionError = _pendingCompletionError;
        shouldRetry = _pendingCompletionShouldRetry;
        _pendingCompletionError = nil;
        _pendingCompletionShouldRetry = NO;
    } else if(error != nil && error.code != NSURLErrorCancelled) {
        completionError = error;
        shouldRetry = [self isTransientNetworkError:error];
    }

    if(shouldRetry && _open && _retryCount < kMaxReconnectAttempts) {
        _retryCount += 1;
        reconnectGeneration = ++_reconnectGeneration;
        _finished = NO;
        [self updateEOFLocked];
        [_condition broadcast];
        [_condition unlock];
        [session finishTasksAndInvalidate];
        [self scheduleReconnectForGeneration:reconnectGeneration attempt:_retryCount];
        return;
    }

    if(completionError != nil) {
        _streamError = completionError;
    }
    _finished = YES;
    [self updateEOFLocked];
    [_condition broadcast];
    [_condition unlock];
    [session finishTasksAndInvalidate];
}

- (void)cleanupResources {
    NSURLSession *session = nil;
    NSURLSessionTask *task = nil;
    NSURL *tempFileURL = nil;
    int fileDescriptor = -1;

    [_condition lock];
    _open = NO;
    _reading = NO;
    _finished = YES;
    _eof = YES;
    _receivedResponse = YES;
    _pendingCompletionError = nil;
    _pendingCompletionShouldRetry = NO;
    _reconnectGeneration += 1;
    session = _session;
    task = _task;
    tempFileURL = _tempFileURL;
    fileDescriptor = _fileDescriptor;
    _session = nil;
    _task = nil;
    _tempFileURL = nil;
    _fileDescriptor = -1;
    [_condition broadcast];
    [_condition unlock];

    [task cancel];
    [session invalidateAndCancel];

    if(fileDescriptor >= 0) {
        close(fileDescriptor);
    }

    if(tempFileURL != nil) {
        [[NSFileManager defaultManager] removeItemAtURL:tempFileURL error:nil];
    }
}

- (void)startRequestFromOffset:(NSInteger)offset requiresResumeValidation:(BOOL)requiresResumeValidation {
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    configuration.timeoutIntervalForRequest = 30;
    configuration.timeoutIntervalForResource = 0;

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:_url];
    request.HTTPMethod = @"GET";

    if(requiresResumeValidation) {
        NSString *rangeHeader = [NSString stringWithFormat:@"bytes=%ld-", (long)offset];
        [request setValue:rangeHeader forHTTPHeaderField:@"Range"];
    }

    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:_delegateQueue];
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request];

    [_condition lock];
    if(!_open || _fileDescriptor < 0) {
        [_condition unlock];
        [task cancel];
        [session invalidateAndCancel];
        return;
    }

    _session = session;
    _task = task;
    _receivedResponse = NO;
    _finished = NO;
    _streamError = nil;
    _requestOffset = offset;
    _requestRequiresResumeValidation = requiresResumeValidation;
    _pendingCompletionError = nil;
    _pendingCompletionShouldRetry = NO;
    [self updateEOFLocked];
    [_condition broadcast];
    [_condition unlock];

    [task resume];
}

- (void)updateEOFLocked {
    NSInteger endOffset = _hasLength ? _length : _downloadedBytes;
    _eof = _finished && _offset >= endOffset;
}

- (void)scheduleReconnectForGeneration:(NSInteger)generation attempt:(NSInteger)attempt {
    int64_t delaySeconds = 1;
    if(attempt > 1) {
        delaySeconds = (int64_t)1 << MIN((int)attempt - 1, 4);
    }

    __weak typeof(self) weakSelf = self;
    NSInteger expectedGeneration = generation;
    dispatch_time_t when = dispatch_time(DISPATCH_TIME_NOW, delaySeconds * NSEC_PER_SEC);
    dispatch_after(when, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        typeof(self) strongSelf = weakSelf;
        if(strongSelf == nil) {
            return;
        }
        [strongSelf->_delegateQueue addOperationWithBlock:^{
            [strongSelf->_condition lock];
            BOOL shouldReconnect = strongSelf->_open && strongSelf->_reconnectGeneration == expectedGeneration;
            [strongSelf->_condition unlock];
            if(!shouldReconnect) {
                return;
            }
            [strongSelf reconnectFromDownloadedBytes];
        }];
    });
}

- (int)createTemporaryFileReturningURL:(NSURL **)tempFileURL error:(NSError **)error {
    NSString *directoryPath = NSTemporaryDirectory();
    if(directoryPath.length == 0) {
        if(error != NULL) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOENT userInfo:nil];
        }
        return -1;
    }

    for(NSUInteger attempt = 0; attempt < 10; ++attempt) {
        NSString *fileName = [NSString stringWithFormat:@"kanade_stream_%@.tmp", NSUUID.UUID.UUIDString];
        NSString *filePath = [directoryPath stringByAppendingPathComponent:fileName];
        int fileDescriptor = open(filePath.fileSystemRepresentation, O_RDWR | O_CREAT | O_EXCL, 0600);
        if(fileDescriptor >= 0) {
            if(tempFileURL != NULL) {
                *tempFileURL = [NSURL fileURLWithPath:filePath];
            }
            return fileDescriptor;
        }
        if(errno != EEXIST) {
            break;
        }
    }

    if(error != NULL) {
        *error = [self POSIXErrorWithCode:errno];
    }
    return -1;
}

- (ssize_t)readFromFileDescriptor:(int)fileDescriptor buffer:(void *)buffer length:(NSInteger)length offset:(NSInteger)offset error:(NSError **)error {
    ssize_t totalRead = 0;
    while(totalRead < length) {
        ssize_t result = pread(fileDescriptor, ((uint8_t *)buffer) + totalRead, (size_t)(length - totalRead), (off_t)(offset + totalRead));
        if(result < 0) {
            if(errno == EINTR) {
                continue;
            }
            if(error != NULL) {
                *error = [self POSIXErrorWithCode:errno];
            }
            return -1;
        }
        if(result == 0) {
            break;
        }
        totalRead += result;
    }
    return totalRead;
}

- (BOOL)writeData:(NSData *)data toFileDescriptor:(int)fileDescriptor offset:(NSInteger)offset error:(NSError **)error {
    const uint8_t *bytes = data.bytes;
    ssize_t totalWritten = 0;
    ssize_t length = (ssize_t)data.length;

    while(totalWritten < length) {
        ssize_t result = pwrite(fileDescriptor, bytes + totalWritten, (size_t)(length - totalWritten), (off_t)(offset + totalWritten));
        if(result < 0) {
            if(errno == EINTR) {
                continue;
            }
            if(error != NULL) {
                *error = [self POSIXErrorWithCode:errno];
            }
            return NO;
        }
        if(result == 0) {
            if(error != NULL) {
                *error = [self POSIXErrorWithCode:EIO];
            }
            return NO;
        }
        totalWritten += result;
    }

    return YES;
}

- (NSError *)POSIXErrorWithCode:(int)code {
    return [NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:nil];
}

- (NSError *)HTTPErrorForStatusCode:(NSInteger)statusCode URL:(NSURL *)url {
    NSMutableDictionary *userInfo = [[NSMutableDictionary alloc] init];
    if(url != nil) {
        userInfo[NSURLErrorKey] = url;
    }
    return [NSError errorWithDomain:NSURLErrorDomain code:statusCode userInfo:userInfo.count > 0 ? userInfo : nil];
}

- (NSError *)invalidResumeResponseErrorForStatusCode:(NSInteger)statusCode expectedOffset:(NSInteger)expectedOffset {
    NSDictionary *userInfo = @{
        NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Invalid resume response for offset %ld", (long)expectedOffset],
        @"statusCode": @(statusCode),
        @"expectedOffset": @(expectedOffset)
    };
    return [NSError errorWithDomain:SFBInputSourceErrorDomain code:SFBInputSourceErrorCodeInputOutput userInfo:userInfo];
}

- (NSString *)headerValueForKey:(NSString *)key headers:(NSDictionary<id, id> *)headers {
    __block NSString *value = nil;
    [headers enumerateKeysAndObjectsUsingBlock:^(id headerKey, id object, BOOL *stop) {
        if([headerKey isKindOfClass:[NSString class]] && [object isKindOfClass:[NSString class]] && [(NSString *)headerKey caseInsensitiveCompare:key] == NSOrderedSame) {
            value = object;
            *stop = YES;
        }
    }];
    return value;
}

- (BOOL)parseContentRange:(NSString *)contentRange start:(NSInteger *)start totalLength:(NSInteger *)totalLength {
    if(contentRange.length == 0) {
        return NO;
    }

    NSError *regexError = nil;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"^bytes (\\d+)-(\\d+)/(\\d+|\\*)$" options:0 error:&regexError];
    if(regex == nil || regexError != nil) {
        return NO;
    }

    NSTextCheckingResult *match = [regex firstMatchInString:contentRange options:0 range:NSMakeRange(0, contentRange.length)];
    if(match.numberOfRanges != 4) {
        return NO;
    }

    NSString *startString = [contentRange substringWithRange:[match rangeAtIndex:1]];
    NSString *totalLengthString = [contentRange substringWithRange:[match rangeAtIndex:3]];

    if(start != NULL) {
        *start = startString.integerValue;
    }

    if(totalLength != NULL) {
        if([totalLengthString isEqualToString:@"*"]) {
            *totalLength = NSNotFound;
        } else {
            *totalLength = totalLengthString.integerValue;
        }
    }

    return YES;
}

- (BOOL)isTransientNetworkError:(NSError *)error {
    if(![error.domain isEqualToString:NSURLErrorDomain]) {
        return NO;
    }

    switch(error.code) {
        case NSURLErrorTimedOut:
        case NSURLErrorCannotFindHost:
        case NSURLErrorCannotConnectToHost:
        case NSURLErrorNetworkConnectionLost:
        case NSURLErrorDNSLookupFailed:
        case NSURLErrorNotConnectedToInternet:
        case NSURLErrorInternationalRoamingOff:
        case NSURLErrorCallIsActive:
        case NSURLErrorDataNotAllowed:
        case NSURLErrorCannotLoadFromNetwork:
            return YES;
        case NSURLErrorCancelled:
            return NO;
        default:
            return NO;
    }
}

- (BOOL)isRetryableHTTPStatusCode:(NSInteger)statusCode {
    return statusCode == 408 || statusCode == 429 || (statusCode >= 500 && statusCode <= 599);
}

- (BOOL)isTerminalHTTPStatusCode:(NSInteger)statusCode {
    switch(statusCode) {
        case 401:
        case 403:
        case 404:
        case 410:
        case 416:
            return YES;
        default:
            return NO;
    }
}

@end
