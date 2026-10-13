# mailbox — result: WORKS (non-blocking API only under --no-timing)

Probe: `tb_mailbox.sv` — typed `mailbox #(txn)`, bounded mailbox
capacity/backpressure, `try_put/try_get/try_peek/num`, and plain
class-handle queues (`push_back/pop_front/size/index/drain`).

Evidence (`run.log`):

```
[tb] two try_puts accepted, num()==2
[tb] try_get: id=1 data=0xaa
[tb] try_peek sees id=2 (still queued)
[tb] try_get on empty mailbox returned 0
[tb] bounded mailbox(cap 2) backpressures 3rd put
[tb] class-handle queue push/size/index ok
[tb] queue drain order ok (sum=18)
MAILBOX: PASS
```

Important constraint discovered (mini-probes m1–m3 in the spike log):
blocking `mailbox::put()`/`get()` and `semaphore::put()` are built on the
blocking mailbox and **fail to compile under `--no-timing`** with:

```
%Error-NOTIMING: s1.sv:7:9: mailbox::put() requires --timing
```

They compile and run correctly with `--timing`. Since the F1 harness is
`--no-timing`, agent↔scoreboard communication must use `try_*` (poll each
cycle — natural in a per-cycle `tick()` architecture) or class-handle
queues. Semaphores are effectively unavailable in harness mode.
