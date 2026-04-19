@import Foundation;
@import CSFBAudioEngine;

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

static NSString * const kErrorDomain = @"dev.ichigo.KanadeApp.SFBProgressiveInputSource";
static NSTimeInterval const kWaitTimeout = 30.0;

#pragma mark - SFBProgressiveInputSource interface (private to this unit)

@interface SFBInputSource ()
- (instancetype)initWithURL:(NSURL *)url;
- (NSError *)posixErrorWithCode:(NSInteger)code;
@end

@interface SFBProgressiveInputSource : SFBInputSource <NSURLSessionDataDelegate, NSURLSessionTaskDelegate>

@property (nonatomic, readonly) NSInteger contentLength;
@property (nonatomic, strong, readonly) NSLock *lock;
@property (nonatomic, strong, readonly) NSMutableArray<NSValue *> *downloadedRanges;
@property (nonatomic, strong, nullable) NSURLSession *backingSession;
@property (nonatomic, strong, nullable) NSURL *temporaryFileURL;
@property (nonatomic, strong, nullable) NSURLSessionDataTask *currentTask;
@property (nonatomic, strong, nullable) NSError *downloadError;
@property (nonatomic) dispatch_semaphore_t semaphore;
@property (nonatomic) NSInteger readOffset;
@property (nonatomic) NSInteger requestStartOffset;
@property (nonatomic) NSInteger writeOffset;
@property (nonatomic) int fd;
@property (nonatomic) BOOL openFlag;
@property (nonatomic) BOOL closeRequested;
@property (nonatomic) BOOL downloadComplete;

@end

#pragma mark - SFBProgressiveInputSource implementation

@implementation SFBProgressiveInputSource

- (nullable instancetype)initWithURL:(NSURL *)url
                       contentLength:(NSInteger)contentLength
                             session:(NSURLSession *)session
{
    self = [super initWithURL:url];
    if (!self) return nil;

    _contentLength = MAX(contentLength, 0);
    _lock = [[NSLock alloc] init];
    _downloadedRanges = [[NSMutableArray alloc] init];
    _semaphore = dispatch_semaphore_create(0);
    _fd = -1;
    _readOffset = 0;
    _requestStartOffset = NSNotFound;
    _writeOffset = 0;
    _openFlag = NO;
    _closeRequested = NO;
    _downloadComplete = NO;

    NSURLSessionConfiguration *config = session.configuration ?: [NSURLSessionConfiguration defaultSessionConfiguration];
    _backingSession = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];

    return self;
}

- (void)dealloc { [self closeReturningError:nil]; }

- (void)startDownload {
    [self.lock lock];
    if (self.openFlag && !self.downloadComplete && !self.currentTask) {
        [self beginDownloadLockedFrom:0];
    }
    [self.lock unlock];
}

#pragma mark SFBInputSource overrides

- (BOOL)openReturningError:(NSError **)error {
    [self.lock lock];
    if (self.openFlag) { [self.lock unlock]; return YES; }

    self.downloadError = nil;
    self.closeRequested = NO;
    self.downloadComplete = NO;
    self.readOffset = 0;
    self.requestStartOffset = NSNotFound;
    self.writeOffset = 0;
    [self.downloadedRanges removeAllObjects];

    NSString *filename = [NSString stringWithFormat:@"SFBProgressive_%@.tmp", NSUUID.UUID.UUIDString];
    NSURL *tmpURL = [[NSFileManager defaultManager].temporaryDirectory URLByAppendingPathComponent:filename];
    int fd = open(tmpURL.fileSystemRepresentation, O_CREAT | O_EXCL | O_RDWR, S_IRUSR | S_IWUSR);
    if (fd < 0) {
        [self.lock unlock];
        if (error) *error = [self posixErrorWithCode:errno];
        return NO;
    }
    self.fd = fd;
    self.openFlag = YES;

    if (self.contentLength > 0)
        [self beginDownloadLockedFrom:0];

    [self.lock unlock];
    return YES;
}

- (BOOL)closeReturningError:(NSError **)error {
    [self.lock lock];
    self.closeRequested = YES;
    self.openFlag = NO;
    self.downloadComplete = NO;
    NSURLSessionDataTask *task = self.currentTask;
    self.currentTask = nil;
    int fd = self.fd;
    self.fd = -1;
    NSURL *tmpURL = self.temporaryFileURL;
    [self.downloadedRanges removeAllObjects];
    dispatch_semaphore_signal(self.semaphore);
    [self.lock unlock];

    [task cancel];
    if (fd >= 0) close(fd);
    if (tmpURL) [[NSFileManager defaultManager] removeItemAtURL:tmpURL error:nil];
    [self.backingSession invalidateAndCancel];
    self.backingSession = nil;
    return YES;
}

- (BOOL)isOpen { [self.lock lock]; BOOL o = self.openFlag; [self.lock unlock]; return o; }

- (BOOL)readBytes:(void *)buffer length:(NSInteger)length bytesRead:(NSInteger *)bytesRead error:(NSError **)error {
    if (bytesRead) *bytesRead = 0;
    if (length <= 0) return YES;
    if (![self waitForOffset:self.readOffset error:error]) return NO;

    [self.lock lock];
    if (!self.openFlag || self.fd < 0 || self.readOffset >= self.contentLength) {
        [self.lock unlock];
        return YES;
    }
    NSRange avail = [self rangeContainingOffsetLocked:self.readOffset];
    if (avail.location == NSNotFound) {
        [self.lock unlock];
        if (error) *error = self.downloadError ?: [NSError errorWithDomain:kErrorDomain code:2 userInfo:@{NSLocalizedDescriptionKey: @"Data not available"}];
        return NO;
    }
    NSInteger maxLen = MIN(length, MIN((NSInteger)NSMaxRange(avail) - self.readOffset, self.contentLength - self.readOffset));
    int fd = self.fd;
    [self.lock unlock];

    ssize_t n = pread(fd, buffer, (size_t)maxLen, (off_t)self.readOffset);
    if (n < 0) { if (error) *error = [self posixErrorWithCode:errno]; return NO; }

    [self.lock lock];
    self.readOffset += (NSInteger)n;
    [self.lock unlock];
    if (bytesRead) *bytesRead = (NSInteger)n;
    return YES;
}

- (BOOL)getOffset:(NSInteger *)offset error:(NSError **)error {
    [self.lock lock]; if (offset) *offset = self.readOffset; [self.lock unlock]; return YES;
}

- (BOOL)getLength:(NSInteger *)length error:(NSError **)error {
    if (length) *length = self.contentLength; return YES;
}

- (BOOL)supportsSeeking { return YES; }

- (BOOL)seekToOffset:(NSInteger)offset error:(NSError **)error {
    if (offset < 0 || offset > self.contentLength) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:nil];
        return NO;
    }
    [self.lock lock];
    if (!self.openFlag) { [self.lock unlock]; return NO; }
    self.readOffset = offset;
    if (offset < self.contentLength && ![self isDownloadedLocked:offset]) {
        self.downloadComplete = NO;
        [self beginDownloadLockedFrom:offset];
    }
    [self.lock unlock];
    return (offset >= self.contentLength) || [self waitForOffset:offset error:error];
}

- (BOOL)atEOF {
    [self.lock lock];
    BOOL eof = self.readOffset >= self.contentLength && self.downloadComplete;
    [self.lock unlock];
    return eof;
}

#pragma mark Download

- (void)beginDownloadLockedFrom:(NSInteger)offset {
    if (!self.openFlag || self.closeRequested || self.contentLength == 0) return;
    NSInteger clamped = MAX(0, MIN(offset, self.contentLength));
    if (clamped >= self.contentLength) { self.downloadComplete = YES; dispatch_semaphore_signal(self.semaphore); return; }
    if (self.currentTask && self.requestStartOffset == clamped) return;

    NSURLSessionDataTask *prev = self.currentTask;
    self.requestStartOffset = clamped;
    self.writeOffset = clamped;
    self.downloadError = nil;
    self.downloadComplete = NO;

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:self.url];
    req.HTTPMethod = @"GET";
    [req setValue:[NSString stringWithFormat:@"bytes=%ld-", (long)clamped] forHTTPHeaderField:@"Range"];

    self.currentTask = [self.backingSession dataTaskWithRequest:req];
    [prev cancel];
    [self.currentTask resume];
}

- (BOOL)waitForOffset:(NSInteger)offset error:(NSError **)error {
    if (offset >= self.contentLength) return YES;
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + kWaitTimeout;

    while (true) {
        [self.lock lock];
        if (!self.openFlag || self.closeRequested) { [self.lock unlock]; return NO; }
        if (self.downloadError) { NSError *e = self.downloadError; [self.lock unlock]; if (error) *error = e; return NO; }
        if ([self isDownloadedLocked:offset]) { [self.lock unlock]; return YES; }
        if (!self.currentTask) [self beginDownloadLockedFrom:offset];
        [self.lock unlock];

        CFTimeInterval rem = deadline - CFAbsoluteTimeGetCurrent();
        if (rem <= 0) { if (error) *error = [NSError errorWithDomain:kErrorDomain code:6 userInfo:@{NSLocalizedDescriptionKey: @"Timeout"}]; return NO; }
        if (dispatch_semaphore_wait(self.semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(rem * NSEC_PER_SEC))) != 0) {
            if (error) *error = [NSError errorWithDomain:kErrorDomain code:6 userInfo:@{NSLocalizedDescriptionKey: @"Timeout"}]; return NO;
        }
    }
}

#pragma mark Range tracking

- (NSRange)rangeContainingOffsetLocked:(NSInteger)offset {
    for (NSValue *v in self.downloadedRanges) {
        NSRange r = v.rangeValue;
        if (offset >= (NSInteger)r.location && offset < (NSInteger)NSMaxRange(r)) return r;
        if (offset < (NSInteger)r.location) break;
    }
    return NSMakeRange(NSNotFound, 0);
}

- (BOOL)isDownloadedLocked:(NSInteger)offset {
    return [self rangeContainingOffsetLocked:offset].location != NSNotFound;
}

- (void)addDownloadedRangeLocked:(NSRange)nr {
    if (nr.length == 0) return;
    NSUInteger loc = nr.location, end = NSMaxRange(nr);
    NSUInteger i = 0;
    while (i < self.downloadedRanges.count) {
        NSRange er = self.downloadedRanges[i].rangeValue;
        if (end < er.location) break;
        if (loc > NSMaxRange(er)) { i++; continue; }
        loc = MIN(loc, er.location);
        end = MAX(end, NSMaxRange(er));
        [self.downloadedRanges removeObjectAtIndex:i];
    }
    [self.downloadedRanges insertObject:[NSValue valueWithRange:NSMakeRange(loc, end - loc)] atIndex:i];
}

#pragma mark NSURLSession delegates

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    [self.lock lock];
    BOOL isCurrent = self.currentTask && dataTask.taskIdentifier == self.currentTask.taskIdentifier;
    [self.lock unlock];
    if (!isCurrent) { completionHandler(NSURLSessionResponseCancel); return; }

    NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
    NSInteger status = http.statusCode;
    if (status != 200 && status != 206) {
        [self.lock lock]; self.downloadError = [NSError errorWithDomain:kErrorDomain code:8 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"HTTP %ld", (long)status]}]; self.currentTask = nil; dispatch_semaphore_signal(self.semaphore); [self.lock unlock];
        completionHandler(NSURLSessionResponseCancel); return;
    }
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    [self.lock lock];
    if (!self.openFlag || self.closeRequested || self.fd < 0 || !self.currentTask || dataTask.taskIdentifier != self.currentTask.taskIdentifier) { [self.lock unlock]; return; }
    NSInteger wo = self.writeOffset;
    self.writeOffset += data.length;
    [self.lock unlock];

    const uint8_t *bytes = data.bytes;
    NSInteger remaining = data.length, cursor = 0;
    while (remaining > 0) {
        ssize_t w = pwrite(self.fd, bytes + cursor, (size_t)remaining, (off_t)(wo + cursor));
        if (w < 0) { [self.lock lock]; self.downloadError = [self posixErrorWithCode:errno]; [self.currentTask cancel]; self.currentTask = nil; dispatch_semaphore_signal(self.semaphore); [self.lock unlock]; return; }
        remaining -= (NSInteger)w; cursor += (NSInteger)w;
    }

    [self.lock lock];
    [self addDownloadedRangeLocked:NSMakeRange((NSUInteger)wo, (NSUInteger)data.length)];
    dispatch_semaphore_signal(self.semaphore);
    [self.lock unlock];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    [self.lock lock];
    BOOL isCurrent = self.currentTask && task.taskIdentifier == self.currentTask.taskIdentifier;
    if (!isCurrent) { [self.lock unlock]; return; }
    self.currentTask = nil;
    BOOL cancelled = error && [error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled;
    if (error && !cancelled) { self.downloadError = error; }
    else if (!self.closeRequested) { self.downloadComplete = YES; }
    dispatch_semaphore_signal(self.semaphore);
    [self.lock unlock];
}

@end

#pragma mark - Swift-facing factory function

SFBInputSource *SFBProgressiveInputSourceCreate(NSURL *url, NSInteger contentLength, NSURLSession *session) {
    SFBProgressiveInputSource *src = [[SFBProgressiveInputSource alloc] initWithURL:url contentLength:contentLength session:session];
    [src startDownload];
    return src;
}
