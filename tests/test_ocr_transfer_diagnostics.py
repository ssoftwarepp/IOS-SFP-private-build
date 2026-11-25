import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


class OCRTransferDiagnosticsTests(unittest.TestCase):
    def test_io_failure_logs_each_syscall_result_and_errno(self):
        source = (ROOT / 'pccontrol/PaddleOCRBridge.m').read_text(encoding='utf-8')
        self.assertIn('int pollResult = -2, pollErrno = 0;', source)
        self.assertIn('pollErrno = pollResult < 0 ? errno : 0;', source)
        self.assertIn('selectErrno = selectResult < 0 ? errno : 0;', source)
        self.assertIn('int transferErrno = count < 0 ? errno : 0;', source)
        for field in ('poll=%d poll_errno=%d', 'select=%d select_errno=%d',
                      'send=%zd send_errno=%d', 'fd=%d', '(-2=not-called)'):
            self.assertIn(field, source)
        self.assertIn('zxAppendRuntimeLog(detail);', source)
        self.assertIn('if (pollResult < 0 && pollErrno == EPERM', source)
        self.assertIn('if (count < 0 && transferErrno == EINTR) continue;', source)

    def test_high_fd_poll_eperm_uses_bounded_nonblocking_io(self):
        source = (ROOT / 'pccontrol/PaddleOCRBridge.m').read_text(encoding='utf-8')
        transfer = source.split('static ZXOCRTransferStatus ZXOCRTransfer(', 1)[1].split('@implementation', 1)[0]
        self.assertIn('if (pollResult < 0 && pollErrno == EPERM)', transfer)
        self.assertIn('if (fd < FD_SETSIZE)', transfer)
        self.assertIn('select(fd + 1,', transfer)
        self.assertIn('directTransfer = YES;', transfer)
        self.assertIn('result = 1;', transfer)
        self.assertLess(transfer.index('directTransfer = YES;'), transfer.index('ssize_t count = writing ? send('))
        self.assertIn('send(fd, cursor, length, MSG_DONTWAIT)', transfer)
        self.assertIn('recv(fd, cursor, length, MSG_DONTWAIT)', transfer)
        self.assertIn('transferErrno == EAGAIN || transferErrno == EWOULDBLOCK', transfer)
        self.assertIn('if (pause) usleep(pause);', transfer)
        self.assertIn('if (remaining <= 0) return ZXOCRTransferTimeout;', transfer)
        self.assertIn('if (!count) return ZXOCRTransferClosed;', transfer)
        self.assertIn('return ZXOCRTransferIOError;', transfer)


if __name__ == '__main__':
    unittest.main()
