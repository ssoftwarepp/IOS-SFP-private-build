import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


class SocketResourceCleanupTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = (ROOT / 'pccontrol/SocketServer.xm').read_text(encoding='utf-8')
        cls.client = (ROOT / 'zxtouch/zxtouch/Socket.m').read_text(encoding='utf-8')

    def test_disconnect_drains_replies_before_closing_socket(self):
        source = self.server
        self.assertIn('if (![socketClientHandles objectForKey:clientKey]) return;', source)
        self.assertIn('CFReadStreamSetClient(readStream, kCFStreamEventNone, NULL, NULL);', source)
        self.assertIn('CFReadStreamUnscheduleFromRunLoop(readStream, CFRunLoopGetCurrent(), kCFRunLoopCommonModes);', source)
        self.assertIn('CFReadStreamClose(readStream);', source)
        self.assertIn('CFRelease(readStream);', source)
        self.assertIn('dispatch_async(clientQueue, ^{\n        CFWriteStreamClose(writeStream);\n        CFRelease(writeStream);\n        close(socketHandle.intValue);', source)
        self.assertIn('dispatch_async(clientQueue, runTask);', source)
        self.assertIn('if (hasRead < 0 || CFReadStreamGetStatus(readStream) == kCFStreamStatusAtEnd)', source)

    def test_accepted_socket_is_closed_exactly_once(self):
        source = self.server
        self.assertIn('CFReadStreamSetProperty(clientReadStream, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanFalse)', source)
        self.assertIn('CFWriteStreamSetProperty(clientWriteStream, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanFalse)', source)
        self.assertIn('[socketClientHandles setObject:@(nativeSocketHandle)', source)
        self.assertIn('if (clientReadStream) CFRelease(clientReadStream);', source)
        self.assertIn('if (clientWriteStream) CFRelease(clientWriteStream);', source)
        self.assertIn('if (!CFReadStreamOpen(clientReadStream) || !CFWriteStreamOpen(clientWriteStream))', source)
        self.assertIn('if (!CFReadStreamSetClient(clientReadStream, streamEvents, readStream, &context))', source)
        self.assertIn('close(nativeSocketHandle);', source)

    def test_recording_reply_does_not_outlive_client_queue(self):
        recording = (ROOT / 'pccontrol/Record.xm').read_text(encoding='utf-8')
        start = recording.index('void startRecording(')
        end = recording.index('void stopRecording(', start)
        body = recording[start:end]
        self.assertLess(body.index('notifyClient((UInt8*)[scriptDirectory UTF8String], requestClient);'),
                        body.index('dispatch_async(dispatch_get_global_queue('))

    def test_listener_and_failed_client_connect_release_resources(self):
        self.assertIn('CFRelease(address);', self.server)
        self.assertIn('CFSocketInvalidate(_socket);', self.server)
        self.assertIn('CFRelease(_socket);', self.server)
        for failure in ('Invalid address. Address not supported', 'Connection Failed'):
            start = self.client.index(failure)
            self.assertIn('close(sock);', self.client[start:start + 110])


if __name__ == '__main__':
    unittest.main()
