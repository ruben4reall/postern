#ifndef CPOSTERN_SYS_H
#define CPOSTERN_SYS_H

#include <stdint.h>

// Locks the calling process in before it reads hostile input (Linux): no new privileges, no core dump, Landlock with
// no filesystem or TCP access, a seccomp allowlist without open, socket, connect or exec, and resource limits.
// Returns a bit field of what was applied (1 seccomp, 2 Landlock, 4 limits); a negative value when seccomp, the
// part Postern requires, could not be applied. Elsewhere it does nothing and returns 0.
int postern_jail(uint64_t max_memory_bytes, uint32_t max_cpu_seconds);

// The user id and process id of the peer of a connected Unix socket (Linux). Returns 0 on success.
int postern_peer_credentials(int fd, uint32_t *uid, int32_t *pid);

// Keeps other programs of the same user from reading the core's memory through ptrace or /proc (Linux).
void postern_not_dumpable(void);

// Starts a program in a session of its own, its standard streams on /dev/null, so it outlives the caller (Linux).
// Returns its process id, or -1.
int postern_spawn_detached(const char *path);

#endif
