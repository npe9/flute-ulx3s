"""tools/hw/common.py: the hwsh contract's status and exit codes (CONTRACT.md) on top of hwout."""
import argparse
import os
import sys

sys.path.insert(0, os.environ.get('HWSH_LIB', os.path.expanduser('~/src/hwsh/lib')))
from hwout import HwError, emit  # noqa: E402

EXIT = {'HW-E-BADREQ': 2, 'HW-E-TIMEOUT': 4, 'HW-E-INTERNAL': 4}


class Parser(argparse.ArgumentParser):
    """A bad request is a record (HW-E-BADREQ, exit 2), not argparse's usage text."""
    def error(self, message):
        raise HwError('HW-E-BADREQ', message, '%s --help' % self.prog)


def run(fn, argv, parse):
    json_out = '--json' in argv
    try:
        res = fn(parse(argv))
        res.setdefault('status', 'ok')
        res.setdefault('cached', False)          # these answers are cheap; nothing is cached yet
        rc = {'ok': 0, 'fail': 1}.get(res['status'], EXIT.get(res.get('code'), 3))
    except HwError as e:
        res = {'status': 'error', 'code': e.code, 'reason': e.reason, 'hint': e.hint, 'cached': False}
        rc = EXIT.get(e.code, 3)
    except OSError as e:
        res, rc = {'status': 'error', 'code': 'HW-E-IO', 'reason': str(e), 'cached': False}, 3
    except Exception as e:  # noqa: BLE001 - never a traceback
        res, rc = {'status': 'error', 'code': 'HW-E-INTERNAL', 'reason': '%s: %s' % (type(e).__name__, e), 'cached': False}, 4
    emit(res, json_out)
    return rc
