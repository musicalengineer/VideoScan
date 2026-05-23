#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Executes `block` inside @try/@catch. Returns YES on success.
/// If an ObjC NSException fires, stores it in *outException and returns NO.
/// Swift's do/try/catch cannot catch ObjC exceptions — they become SIGABRT.
/// Use this to protect CoreML prediction calls from MLE5 crashes.
BOOL VSCatchObjCException(NS_NOESCAPE void (^_Nonnull block)(void),
                          NSException *_Nullable *_Nullable outException);

/// Installs one-shot signal handlers for SIGSEGV, SIGBUS, SIGFPE, SIGILL,
/// and SIGABRT. On fatal signal, writes a last-gasp line to the log file at
/// `logPath`, then re-raises with the default handler so the system crash
/// report is still generated.
///
/// Only async-signal-safe calls inside the handler: write(), fsync(), _exit().
/// Call once at app launch after the log file exists.
void VSInstallCrashGuard(const char *_Nonnull logPath);

NS_ASSUME_NONNULL_END
