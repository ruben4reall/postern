#ifdef __linux__
#define _GNU_SOURCE
#endif
#include "CPosternSys.h"

#ifdef __linux__
#include <errno.h>
#include <fcntl.h>
#include <spawn.h>
#include <stddef.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <linux/audit.h>
#include <linux/filter.h>
#include <linux/seccomp.h>

#if defined(__x86_64__)
#define POSTERN_ARCH AUDIT_ARCH_X86_64
#elif defined(__aarch64__)
#define POSTERN_ARCH AUDIT_ARCH_AARCH64
#else
#error "Postern's reader jail knows x86_64 and aarch64 only."
#endif

#define ALLOW(name) BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_##name, 0, 1), BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW)

// What the reader needs once its input is in memory: memory, threads, time, randomness, its three pipes, and exit.
// Everything else fails with EPERM: open and openat, socket, connect, execve, ptrace, kill, mount, and the rest.
static int apply_seccomp(void) {
    struct sock_filter filter[] = {
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, arch)),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, POSTERN_ARCH, 1, 0),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS),
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr)),
        ALLOW(read), ALLOW(write), ALLOW(readv), ALLOW(writev), ALLOW(close), ALLOW(fstat), ALLOW(lseek),
        ALLOW(exit), ALLOW(exit_group),
        ALLOW(mmap), ALLOW(munmap), ALLOW(mprotect), ALLOW(mremap), ALLOW(madvise), ALLOW(brk),
        ALLOW(futex), ALLOW(clone), ALLOW(clone3), ALLOW(set_robust_list), ALLOW(rseq), ALLOW(set_tid_address),
        ALLOW(sched_yield), ALLOW(sched_getaffinity), ALLOW(gettid), ALLOW(getpid), ALLOW(tgkill),
        ALLOW(rt_sigaction), ALLOW(rt_sigprocmask), ALLOW(rt_sigreturn), ALLOW(sigaltstack),
        ALLOW(clock_gettime), ALLOW(clock_getres), ALLOW(clock_nanosleep), ALLOW(nanosleep), ALLOW(gettimeofday),
        ALLOW(getrandom), ALLOW(prlimit64), ALLOW(membarrier), ALLOW(getrlimit), ALLOW(newfstatat),
#ifdef __NR_futex_waitv
        ALLOW(futex_waitv),
#endif
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | (EPERM & SECCOMP_RET_DATA)),
    };
    struct sock_fprog program = { .len = (unsigned short)(sizeof(filter) / sizeof(filter[0])), .filter = filter };
    return prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &program, 0, 0);
}

// Landlock, declared here so older kernel headers still build. Every filesystem right is handled and none is
// granted; on ABI 4 and later, TCP bind and connect are handled too.
struct postern_ruleset_attr { uint64_t handled_access_fs; uint64_t handled_access_net; };
#ifndef __NR_landlock_create_ruleset
#define __NR_landlock_create_ruleset 444
#define __NR_landlock_restrict_self 446
#endif

static int apply_landlock(void) {
    long abi = syscall(__NR_landlock_create_ruleset, NULL, 0, 1UL /* LANDLOCK_CREATE_RULESET_VERSION */);
    if (abi < 1) return -1;
    struct postern_ruleset_attr attr = { 0, 0 };
    attr.handled_access_fs = (1ULL << 13) - 1; // ABI 1: execute to make_sym
    if (abi >= 2) attr.handled_access_fs |= 1ULL << 13; // refer
    if (abi >= 3) attr.handled_access_fs |= 1ULL << 14; // truncate
    if (abi >= 5) attr.handled_access_fs |= 1ULL << 15; // ioctl_dev
    if (abi >= 4) attr.handled_access_net = 3; // bind_tcp, connect_tcp
    size_t size = abi >= 4 ? sizeof attr : sizeof attr.handled_access_fs;
    int ruleset = (int)syscall(__NR_landlock_create_ruleset, &attr, size, 0);
    if (ruleset < 0) return -1;
    int result = (int)syscall(__NR_landlock_restrict_self, ruleset, 0);
    close(ruleset);
    return result;
}

static int apply_limits(uint64_t max_memory_bytes, uint32_t max_cpu_seconds) {
    int ok = 0;
    struct rlimit memory = { (rlim_t)max_memory_bytes, (rlim_t)max_memory_bytes };
    struct rlimit cpu = { (rlim_t)max_cpu_seconds, (rlim_t)max_cpu_seconds + 1 };
    struct rlimit nothing = { 0, 0 };
    if (max_memory_bytes > 0 && setrlimit(RLIMIT_AS, &memory) != 0) ok = -1;
    if (max_cpu_seconds > 0 && setrlimit(RLIMIT_CPU, &cpu) != 0) ok = -1;
    if (setrlimit(RLIMIT_FSIZE, &nothing) != 0) ok = -1;
    if (setrlimit(RLIMIT_CORE, &nothing) != 0) ok = -1;
    return ok;
}

int postern_jail(uint64_t max_memory_bytes, uint32_t max_cpu_seconds) {
    int applied = 0;
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) return -1;
    prctl(PR_SET_DUMPABLE, 0, 0, 0, 0);
    if (apply_limits(max_memory_bytes, max_cpu_seconds) == 0) applied |= 4;
    if (apply_landlock() == 0) applied |= 2;
    if (apply_seccomp() != 0) return -1;
    applied |= 1;
    return applied;
}

int postern_peer_credentials(int fd, uint32_t *uid, int32_t *pid) {
    struct ucred credentials;
    socklen_t length = sizeof credentials;
    if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &credentials, &length) != 0) return -1;
    *uid = (uint32_t)credentials.uid;
    *pid = (int32_t)credentials.pid;
    return 0;
}

void postern_not_dumpable(void) { prctl(PR_SET_DUMPABLE, 0, 0, 0, 0); }

extern char **environ;

int postern_spawn_detached(const char *path) {
    posix_spawnattr_t attributes;
    posix_spawn_file_actions_t actions;
    pid_t pid = -1;
    if (posix_spawnattr_init(&attributes) != 0) return -1;
    posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETSID);
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0);
    char *argv[] = { (char *)path, NULL };
    int result = posix_spawn(&pid, path, &actions, &attributes, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attributes);
    return result == 0 ? (int)pid : -1;
}

#else

int postern_jail(uint64_t max_memory_bytes, uint32_t max_cpu_seconds) { (void)max_memory_bytes; (void)max_cpu_seconds; return 0; }
int postern_peer_credentials(int fd, uint32_t *uid, int32_t *pid) { (void)fd; *uid = 0; *pid = 0; return -1; }
void postern_not_dumpable(void) {}
int postern_spawn_detached(const char *path) { (void)path; return -1; }

#endif
