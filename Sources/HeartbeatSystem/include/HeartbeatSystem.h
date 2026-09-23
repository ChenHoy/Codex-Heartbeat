#ifndef HEARTBEAT_SYSTEM_H
#define HEARTBEAT_SYSTEM_H
#include <stdint.h>
#include <sys/types.h>
uint64_t hb_process_stamp(pid_t pid);
int hb_process_path(pid_t pid, char *buffer, int size);
int hb_owns_listener(pid_t pid, uint16_t port);
int hb_free_port(void);
pid_t hb_spawn_terminal(const char *path, char *const argv[]);
void hb_install_signals(void);
int hb_received_signal(void);
int hb_poll_child(pid_t pid, int *exit_code);
#endif
