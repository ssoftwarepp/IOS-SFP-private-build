import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


class OCRTransferDiagnosticsTests(unittest.TestCase):
    def test_io_failure_logs_each_syscall_result_and_errno(self):
        source = (ROOT / 'pccontrol/PaddleOCRBridge.m').read_text(encoding='utf-8')
        self.assertIn('int pollErrno = pollResult < 0 ? errno : 0;', source)
        self.assertIn('selectErrno = selectResult < 0 ? errno : 0;', source)
        self.assertIn('int transferErrno = count < 0 ? errno : 0;', source)
        for field in ('poll=%d poll_errno=%d', 'select=%d select_errno=%d',
                      'send=%zd send_errno=%d', 'fd=%d', '(-2=not-called)'):
            self.assertIn(field, source)
        self.assertIn('zxAppendRuntimeLog(detail);', source)
        self.assertIn('if (pollResult < 0 && pollErrno == EPERM', source)
        self.assertIn('if (count < 0 && (transferErrno == EINTR || transferErrno == EAGAIN))', source)


if __name__ == '__main__':
    unittest.main()
