<!-- moved from Claude memory (reference_lldb_fifo_control) on 2026-10-23; operational reference, rewrite in place -->

When a hung macOS app needs deeper inspection than `sample` provides — specifically per-thread stacks, register state, or specific frame inspection — drive `lldb` from bash via a fifo. The pattern is non-interactive but flexible: write commands to the fifo as needed, read output from a log file.

## Setup

```bash
BIN="/path/to/AppName.app/Contents/MacOS/AppName"
LLDB_IN=/tmp/lldb.in
LLDB_OUT=/tmp/lldb.out
rm -f "$LLDB_IN" "$LLDB_OUT"
mkfifo "$LLDB_IN"

# Launch lldb reading commands from fifo, all output to log file
( lldb -X < "$LLDB_IN" > "$LLDB_OUT" 2>&1 ) &
LLDB_PID=$!

# Hold the fifo open from a sleeping background process so writes
# don't EOF after lldb consumes them
( sleep 99999 > "$LLDB_IN" ) &
HOLDER_PID=$!

sleep 2
{
  echo 'target create "'"$BIN"'"'
  echo 'process launch --working-dir /Users/rickb'
} > "$LLDB_IN"
```

Or attach to an already-running PID:
```bash
echo "process attach --pid $TARGET_PID" > "$LLDB_IN"
```

## When the user reports "hung", interrupt and dump

```bash
kill -SIGINT $LLDB_PID    # interrupts the inferior, returns lldb prompt
sleep 2
{
  echo 'thread list'
  echo 'thread backtrace all'
  echo 'process status'
} > "$LLDB_IN"
sleep 8                    # let output flush
```

Then parse `/tmp/lldb.out` for the dump. Useful greps:
- `awk '/^\* thread #1/,/^[* ]\s*thread #/'` — Main Thread stack
- `awk '...VideoScan|libswift_Concurrency...'` — only frames in your code or Swift Concurrency runtime
- `grep -E 'mach_msg2_trap|__psynch_cvwait|semaphore_wait_trap'` — what threads are parked on

## Detach cleanly

```bash
echo 'detach' > "$LLDB_IN"; sleep 2
echo 'quit'   > "$LLDB_IN"; sleep 2
kill $HOLDER_PID 2>/dev/null
rm -f "$LLDB_IN" "$LLDB_OUT"
```

## Gotchas

- `lldb -X` disables the curses UI so all output stays line-based and greppable.
- The `sleep 99999 > fifo` holder is essential — without it, the fifo writer side closes after each write batch and lldb sees EOF mid-session.
- `SIGINT` to lldb's PID interrupts the *inferior*, not lldb itself. lldb then awaits the next command from its stdin (your fifo).
- If the inferior is a SwiftUI app and main thread shows `mach_msg2_trap` only, that's the normal CFRunLoop park — NOT a blocking wait. Look elsewhere (per [[feedback_diagnostic_methodology]]).

Related: [[feedback_diagnostic_methodology]] for what to do with the dump once you have it.
