"""tools/hw/common.py: the hwsh contract's status and exit codes (CONTRACT.md) on top of hwout."""
import argparse
import os
import sys
import time

sys.path.insert(0, os.environ.get('HWSH_LIB', os.path.expanduser('~/src/hwsh/lib')))
from hwout import HwError, emit  # noqa: E402

EXIT = {'HW-E-BADREQ': 2, 'HW-E-TIMEOUT': 4, 'HW-E-INTERNAL': 4}


class Parser(argparse.ArgumentParser):
    """A bad request is a record (HW-E-BADREQ, exit 2), not argparse's usage text."""
    def error(self, message):
        raise HwError('HW-E-BADREQ', message, '%s --help' % self.prog)


def record(area, argv, res, seconds):
    """With HW_PROJECT set, record the answer in that project's hw state DB (hwsh STATE.md v2).
    A recording failure never changes the answer; it is reported on stderr."""
    project = os.environ.get('HW_PROJECT')
    if not project:
        return
    try:
        import hwstate
        verb = next((a for a in argv if not a.startswith('-')), None)
        hwstate.record(project, area, verb, argv, res, inputs=res.pop('_inputs', ()), checks=res.pop('_checks', ()),
                       metrics=res.pop('_metrics', ()), assumptions=res.pop('_assumptions', None),
                       tool=res.pop('_tool', None), tool_version=res.pop('_tool_version', None), seconds=seconds)
    except Exception as e:  # noqa: BLE001
        sys.stderr.write('hw: state not recorded: %s: %s\n' % (type(e).__name__, e))


def run(fn, argv, parse, area=None):
    json_out = '--json' in argv
    t0 = time.time()
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
    if area:
        record(area, argv, res, time.time() - t0)
    for k in [k for k in res if k.startswith('_')]: res.pop(k)
    emit(res, json_out)
    return rc
