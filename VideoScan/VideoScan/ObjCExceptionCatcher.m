#import "ObjCExceptionCatcher.h"
#include <signal.h>
#include <unistd.h>
#include <string.h>
#include <fcntl.h>
#include <time.h>
#include <sys/time.h>

// -- ObjC exception catcher --

BOOL VSCatchObjCException(void (NS_NOESCAPE ^block)(void), NSException **outException) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (outException) {
            *outException = exception;
        }
        return NO;
    }
}

// -- Last-gasp signal handler --
// Everything below is pure C. No ObjC, no Swift, no malloc.
// Only async-signal-safe functions: write, fsync, open, close, _exit, raise.

static int vs_crash_fd = -1;

// Manual integer-to-string for the timestamp (snprintf is not async-signal-safe
// on all platforms). Writes decimal digits into buf, returns count written.
static int vs_itoa(char *buf, int buflen, long val) {
    if (buflen < 2) return 0;
    if (val < 0) { buf[0] = '-'; int n = vs_itoa(buf + 1, buflen - 1, -val); return n + 1; }
    char tmp[20];
    int len = 0;
    do { tmp[len++] = '0' + (char)(val % 10); val /= 10; } while (val > 0 && len < 20);
    if (len > buflen - 1) len = buflen - 1;
    for (int i = 0; i < len; i++) buf[i] = tmp[len - 1 - i];
    return len;
}

static void vs_write_str(const char *s) {
    if (vs_crash_fd >= 0) write(vs_crash_fd, s, strlen(s));
}

static void vs_write_int(long v) {
    char buf[24];
    int n = vs_itoa(buf, sizeof(buf), v);
    if (vs_crash_fd >= 0 && n > 0) write(vs_crash_fd, buf, (size_t)n);
}

static const char *vs_signal_name(int sig) {
    switch (sig) {
        case SIGSEGV: return "SIGSEGV (segmentation fault)";
        case SIGBUS:  return "SIGBUS (bus error)";
        case SIGFPE:  return "SIGFPE (arithmetic exception)";
        case SIGILL:  return "SIGILL (illegal instruction)";
        case SIGABRT: return "SIGABRT (abort)";
        default:      return "unknown signal";
    }
}

static void vs_crash_handler(int sig) {
    if (vs_crash_fd < 0) {
        // No log file — just re-raise
        signal(sig, SIG_DFL);
        raise(sig);
        return;
    }

    // Timestamp: seconds since epoch (async-signal-safe via time())
    struct timeval tv;
    gettimeofday(&tv, NULL);

    vs_write_str("\n!!! FATAL SIGNAL: ");
    vs_write_str(vs_signal_name(sig));
    vs_write_str(" (signal ");
    vs_write_int(sig);
    vs_write_str(") at epoch ");
    vs_write_int(tv.tv_sec);
    vs_write_str(".");
    vs_write_int(tv.tv_usec / 1000);  // milliseconds
    vs_write_str("\n!!! Process will terminate. Full crash report: ~/Library/Logs/DiagnosticReports/\n");

    fsync(vs_crash_fd);

    // Re-raise with default handler so the system crash report is generated
    signal(sig, SIG_DFL);
    raise(sig);
}

void VSInstallCrashGuard(const char *logPath) {
    // Pre-open the log file in append mode. We keep this fd for the lifetime
    // of the process — the signal handler needs it and can't open files safely.
    vs_crash_fd = open(logPath, O_WRONLY | O_CREAT | O_APPEND, 0644);

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = vs_crash_handler;
    sa.sa_flags = SA_RESETHAND;  // one-shot: prevents recursive fault loops

    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS,  &sa, NULL);
    sigaction(SIGFPE,  &sa, NULL);
    sigaction(SIGILL,  &sa, NULL);
    sigaction(SIGABRT, &sa, NULL);
    // SIGTRAP intentionally omitted — interferes with debugger/lldb
}
