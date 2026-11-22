#import "PaddleOCRBridge.h"
#import <UIKit/UIKit.h>
#import <roothide.h>
#import "Common.h"
#import <arpa/inet.h>
#import <errno.h>
#import <fcntl.h>
#import <math.h>
#import <poll.h>
#import <signal.h>
#import <spawn.h>
#import <sys/select.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import <unistd.h>

static NSString *ZXOCRInstalledPath(NSString *suffix) {
    return [jbroot(suffix) copy];
}

typedef NS_ENUM(NSInteger, ZXOCRTransferStatus) {
    ZXOCRTransferOK, ZXOCRTransferTimeout, ZXOCRTransferClosed, ZXOCRTransferIOError
};

static ZXOCRTransferStatus ZXOCRTransfer(int fd, void *buffer, size_t length, BOOL writing,
                                           CFAbsoluteTime deadline, int *failureErrno) {
    uint8_t *cursor = buffer;
    while (length) {
        NSTimeInterval remaining = deadline - CFAbsoluteTimeGetCurrent();
        if (remaining <= 0) return ZXOCRTransferTimeout;
        struct pollfd ready = {fd, writing ? POLLOUT : POLLIN, 0};
        int interval = (int)MIN(remaining * 1000, 1000);
        int result = poll(&ready, 1, interval);
        if (result < 0 && errno == EPERM && fd < FD_SETSIZE) {
            fd_set descriptors; FD_ZERO(&descriptors); FD_SET(fd, &descriptors);
            struct timeval wait = {interval / 1000, (interval % 1000) * 1000};
            result = select(fd + 1, writing ? NULL : &descriptors,
                            writing ? &descriptors : NULL, NULL, &wait);
            if (result > 0) ready.revents = writing ? POLLOUT : POLLIN;
        }
        if (result < 0 && errno == EINTR) continue;
        if (result < 0) { *failureErrno = errno; return ZXOCRTransferIOError; }
        if (!result) continue;
        if (ready.revents & POLLNVAL) { *failureErrno = EBADF; return ZXOCRTransferIOError; }
        if (ready.revents & POLLERR) { *failureErrno = EIO; return ZXOCRTransferIOError; }
        ssize_t count = writing ? send(fd, cursor, length, MSG_DONTWAIT) : recv(fd, cursor, length, MSG_DONTWAIT);
        if (count < 0 && (errno == EINTR || errno == EAGAIN)) continue;
        if (count < 0) { *failureErrno = errno; return ZXOCRTransferIOError; }
        if (!count) return ZXOCRTransferClosed;
        cursor += count;
        length -= (size_t)count;
    }
    return ZXOCRTransferOK;
}

@implementation ZXPaddleOCRBridge {
    NSLock *_lock;
    int _socket;
    pid_t _pid;
}
+ (instancetype)sharedBridge {
    static ZXPaddleOCRBridge *bridge;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ bridge = [self new]; });
    return bridge;
}
- (instancetype)init {
    if ((self = [super init])) {
        _lock = [NSLock new];
        _socket = -1;
        _pid = -1;
    }
    return self;
}
- (void)resetWorker {
    if (_socket >= 0) { close(_socket); _socket = -1; }
    if (_pid > 0) {
        int status = 0;
        pid_t child = waitpid(_pid, &status, WNOHANG);
        if (child == 0) {
            kill(_pid, SIGKILL);
            while ((child = waitpid(_pid, &status, 0)) < 0 && errno == EINTR) {}
        }
        _pid = -1;
    }
}
- (void)dealloc { [self resetWorker]; }
- (NSString *)failure:(NSString *)code stage:(NSString *)stage status:(ZXOCRTransferStatus)state
             systemError:(int)systemError {
    int workerPID = _pid;
    int childStatus = 0;
    pid_t child = workerPID > 0 ? waitpid(workerPID, &childStatus, WNOHANG) : -1;
    NSString *exitDetail = child == workerPID ?
        (WIFEXITED(childStatus) ? [NSString stringWithFormat:@"exit=%d", WEXITSTATUS(childStatus)] :
         (WIFSIGNALED(childStatus) ? [NSString stringWithFormat:@"signal=%d", WTERMSIG(childStatus)] : @"exited")) :
        (child < 0 && errno == ECHILD ? @"already-reaped" : @"running");
    if (child == workerPID) _pid = -1;
    NSString *reason = state == ZXOCRTransferTimeout ? @"TIMEOUT" :
                       (state == ZXOCRTransferClosed ? @"CLOSED" : @"IO");
    NSString *detail = [NSString stringWithFormat:@"OCR_%@_%@: %@ pid=%d %@ errno=%d",
                        code, reason, stage, workerPID, exitDetail, systemError];
    NSLog(@"[IOS-SFP OCR] %@", detail);
    zxAppendRuntimeLog([NSString stringWithFormat:@"IOS-SFP OCR: %@", detail]);
    [self resetWorker];
    return detail;
}
- (BOOL)startWorker:(NSString *)worker resources:(NSString *)resources error:(NSString **)error {
    if (_socket >= 0 && _pid > 0) return YES;
    if (_socket >= 0 || _pid > 0) [self resetWorker];
    int pair[2] = {-1, -1};
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, pair) != 0) {
        if (error) *error = [NSString stringWithFormat:@"OCR_SOCKETPAIR_IO: errno=%d", errno];
        return NO;
    }
    for (int i = 0; i < 2; ++i) {
        if (pair[i] >= 3) continue;
        int moved = fcntl(pair[i], F_DUPFD_CLOEXEC, 3);
        if (moved < 0) {
            int code = errno;
            close(pair[0]); close(pair[1]);
            if (error) *error = [NSString stringWithFormat:@"OCR_DUPFD_IO: errno=%d", code];
            return NO;
        }
        close(pair[i]); pair[i] = moved;
    }
    int noSignal = 1;
    setsockopt(pair[0], SOL_SOCKET, SO_NOSIGPIPE, &noSignal, sizeof(noSignal));
    fcntl(pair[0], F_SETFD, FD_CLOEXEC);
    fcntl(pair[1], F_SETFD, FD_CLOEXEC);
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, pair[1], STDIN_FILENO);
    posix_spawn_file_actions_adddup2(&actions, pair[1], STDOUT_FILENO);
    posix_spawn_file_actions_addclose(&actions, pair[0]);
    posix_spawn_file_actions_addclose(&actions, pair[1]);
    posix_spawnattr_t attributes;
    posix_spawnattr_init(&attributes);
    posix_spawnattr_setflags(&attributes, POSIX_SPAWN_CLOEXEC_DEFAULT);
    char *argv[] = {(char *)worker.fileSystemRepresentation, "--resources", (char *)resources.fileSystemRepresentation, NULL};
    char *env[] = {"PATH=/usr/bin:/bin", "LANG=en_US.UTF-8", NULL};
    pid_t pid = -1;
    int launched = posix_spawn(&pid, worker.fileSystemRepresentation, &actions, &attributes, argv, env);
    posix_spawnattr_destroy(&attributes);
    posix_spawn_file_actions_destroy(&actions);
    close(pair[1]);
    if (launched) {
        close(pair[0]);
        if (error) *error = [NSString stringWithFormat:@"OCR_SPAWN_IO: errno=%d", launched];
        return NO;
    }
    _socket = pair[0]; _pid = pid;
    NSLog(@"[IOS-SFP OCR] worker started pid=%d", _pid);
    zxAppendRuntimeLog([NSString stringWithFormat:@"IOS-SFP OCR: worker started pid=%d", _pid]);
    return YES;
}
- (NSDictionary *)recognizePNG:(NSData *)png region:(NSArray<NSNumber *> *)region error:(NSString **)error {
    if (![_lock tryLock]) { if (error) *error = @"OCR_BUSY: worker request in progress"; return nil; }
    @try {
        NSString *worker = ZXOCRInstalledPath(@"/usr/libexec/zxtouch/zxtouch-ocr-worker");
        NSString *resources = ZXOCRInstalledPath(@"/usr/share/zxtouch/paddleocr");
        if (!zxPathLooksExecutable(worker.fileSystemRepresentation)) {
            if (error) *error = @"OCR_WORKER_MISSING: executable not installed";
            return nil;
        }
        UIImage *image = [UIImage imageWithData:png];
        if (!image.CGImage || region.count != 4) {
            if (error) *error = @"OCR_IMAGE_INVALID: screenshot or region";
            return nil;
        }
        CGFloat width = CGImageGetWidth(image.CGImage), height = CGImageGetHeight(image.CGImage);
        if (!width || !height) { if (error) *error = @"OCR_IMAGE_INVALID: image size"; return nil; }
        CGFloat x = region[0].doubleValue, y = region[1].doubleValue;
        CGFloat w = region[2].doubleValue, h = region[3].doubleValue;
        if (w <= 0 || h <= 0) { x = y = 0; w = width; h = height; }
        if (x < 0 || y < 0 || x + w > width || y + h > height) {
            if (error) *error = @"OCR_ROI_INVALID: outside screenshot";
            return nil;
        }
        NSDictionary *payload = @{ @"image": [png base64EncodedStringWithOptions:0], @"orientation": @1,
                                   @"min_confidence": @0.3,
                                   @"roi": @[@(x / width), @(y / height), @(w / width), @(h / height)] };
        NSData *request = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
        if (!request || request.length > 32 * 1024 * 1024) {
            if (error) *error = @"OCR_REQUEST_INVALID: payload exceeds 32 MiB";
            return nil;
        }
        if (![self startWorker:worker resources:resources error:error]) return nil;
        CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + 30;
        uint32_t length = htonl((uint32_t)request.length), responseLength = 0;
        int systemError = 0;
        ZXOCRTransferStatus state = ZXOCRTransfer(_socket, &length, 4, YES, deadline, &systemError);
        if (state != ZXOCRTransferOK) {
            if (error) *error = [self failure:@"SEND_HEADER" stage:@"request length" status:state systemError:systemError];
            return nil;
        }
        state = ZXOCRTransfer(_socket, (void *)request.bytes, request.length, YES, deadline, &systemError);
        if (state != ZXOCRTransferOK) {
            if (error) *error = [self failure:@"SEND_BODY" stage:@"request JSON" status:state systemError:systemError];
            return nil;
        }
        state = ZXOCRTransfer(_socket, &responseLength, 4, NO, deadline, &systemError);
        if (state != ZXOCRTransferOK) {
            if (error) *error = [self failure:@"RECV_HEADER" stage:@"response length" status:state systemError:systemError];
            return nil;
        }
        responseLength = ntohl(responseLength);
        if (!responseLength || responseLength > 1024 * 1024) {
            if (error) *error = [self failure:@"HEADER_INVALID" stage:@"response length outside 1..1048576"
                                              status:ZXOCRTransferIOError systemError:0];
            return nil;
        }
        NSMutableData *response = [NSMutableData dataWithLength:responseLength];
        state = ZXOCRTransfer(_socket, response.mutableBytes, responseLength, NO, deadline, &systemError);
        if (state != ZXOCRTransferOK) {
            if (error) *error = [self failure:@"RECV_BODY" stage:@"response JSON" status:state systemError:systemError];
            return nil;
        }
        NSDictionary *result = [NSJSONSerialization JSONObjectWithData:response options:0 error:nil];
        if (![result isKindOfClass:NSDictionary.class] || ![result[@"texts"] isKindOfClass:NSArray.class]) {
            NSString *reason = [result[@"error"] isKindOfClass:NSString.class] ? result[@"error"] : @"invalid JSON or missing texts";
            if (error) *error = [NSString stringWithFormat:@"OCR_RESPONSE_INVALID: %@", reason];
            NSLog(@"[IOS-SFP OCR] OCR_RESPONSE_INVALID: %@", reason);
            zxAppendRuntimeLog([NSString stringWithFormat:@"IOS-SFP OCR: OCR_RESPONSE_INVALID: %@", reason]);
            if (![result isKindOfClass:NSDictionary.class]) [self resetWorker];
            return nil;
        }
        NSMutableArray *texts = [NSMutableArray array];
        for (NSDictionary *item in result[@"texts"]) {
            NSArray *box = item[@"box"];
            if (![box isKindOfClass:NSArray.class] || box.count != 4 || ![item[@"text"] isKindOfClass:NSString.class]) continue;
            [texts addObject:@{ @"text": item[@"text"], @"x": @((NSInteger)round([box[0] doubleValue] * width)),
                                @"y": @((NSInteger)round([box[1] doubleValue] * height)),
                                @"width": @((NSInteger)round([box[2] doubleValue] * width)),
                                @"height": @((NSInteger)round([box[3] doubleValue] * height)),
                                @"confidence": item[@"confidence"] ?: @0 }];
        }
        return @{ @"texts": texts, @"engine": @"paddleocr", @"provider": result[@"provider"] ?: @"CPUExecutionProvider",
                  @"worker_pid": @(_pid) };
    } @finally {
        [_lock unlock];
    }
}
@end
