#ifndef C_MAC_BRIDGE_H
#define C_MAC_BRIDGE_H
#include <stdint.h>
#include <stddef.h>

typedef struct {
    uint64_t user_ticks, system_ticks, idle_ticks, nice_ticks;
    uint64_t total_bytes, free_bytes, speculative_bytes, active_bytes;
    uint64_t inactive_bytes, wired_bytes, compressor_bytes;
    uint64_t swap_used_bytes;
    int cpu_error, memory_error, swap_error;
} cmm_system_sample;

typedef struct {
    int32_t pid;
    uint32_t uid;
    uint64_t start_seconds, start_microseconds;
    uint64_t user_ns, system_ns, footprint_bytes, resident_bytes;
    uint64_t disk_read_bytes, disk_write_bytes;
} cmm_process_sample;

int cmm_read_system(cmm_system_sample *sample);
int cmm_list_pids(int32_t *pids, size_t capacity);
int cmm_read_process(int32_t pid, cmm_process_sample *sample);
int cmm_process_path(int32_t pid, char *buffer, uint32_t capacity);
int cmm_registry_service_count(const char *service_class);
int cmm_smc_open_status(void);
uint64_t cmm_continuous_ns(void);
/* Read-only counters and sensor values; no privileged writes. */
int cmm_io_counters(uint64_t *network_read, uint64_t *network_write, uint64_t *disk_read, uint64_t *disk_write);
int cmm_memory_pressure(void);
int cmm_smc_temperature(const char key[4], double *value);
int cmm_gpu_percent(double *value);
typedef struct { char name[128]; double celsius; } cmm_hid_temperature;
int cmm_hid_temperatures(cmm_hid_temperature *values, size_t capacity);
typedef struct { char id[128], name[128]; double celsius; int status, external; } cmm_disk_temperature;
int cmm_disk_temperatures(cmm_disk_temperature *values, size_t capacity);
int cmm_ata_temperature(const uint8_t *data, size_t length, double *value);
typedef struct { char name[32]; uint64_t received_bytes, sent_bytes; } cmm_network_interface;
int cmm_network_interfaces(cmm_network_interface *values,size_t capacity);
typedef void (*cmm_power_callback)(void *context,int sleeping);
void cmm_watch_power(void *context,cmm_power_callback callback);

#endif
