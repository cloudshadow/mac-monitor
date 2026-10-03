#include "CMacBridge.h"
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <sys/sysctl.h>
#include <sys/resource.h>
#include <libproc.h>
#include <IOKit/IOKitLib.h>
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>

int cmm_read_system(cmm_system_sample *s) {
    memset(s, 0, sizeof(*s));
    host_cpu_load_info_data_t cpu;
    mach_msg_type_number_t count = HOST_CPU_LOAD_INFO_COUNT;
    mach_port_t host = mach_host_self();
    s->cpu_error = host_statistics(host, HOST_CPU_LOAD_INFO, (host_info_t)&cpu, &count);
    if (!s->cpu_error) {
        s->user_ticks = cpu.cpu_ticks[CPU_STATE_USER];
        s->system_ticks = cpu.cpu_ticks[CPU_STATE_SYSTEM];
        s->idle_ticks = cpu.cpu_ticks[CPU_STATE_IDLE];
        s->nice_ticks = cpu.cpu_ticks[CPU_STATE_NICE];
    }
    vm_statistics64_data_t vm;
    count = HOST_VM_INFO64_COUNT;
    s->memory_error = host_statistics64(host, HOST_VM_INFO64, (host_info64_t)&vm, &count);
    vm_size_t page = 0;
    if (!s->memory_error) s->memory_error = host_page_size(host, &page);
    mach_port_deallocate(mach_task_self(), host);
    size_t size = sizeof(s->total_bytes);
    if (sysctlbyname("hw.memsize", &s->total_bytes, &size, NULL, 0) != 0)
        s->memory_error = errno;
    if (!s->memory_error) {
        s->free_bytes = (uint64_t)vm.free_count * page;
        s->speculative_bytes = (uint64_t)vm.speculative_count * page;
        s->active_bytes = (uint64_t)vm.active_count * page;
        s->inactive_bytes = (uint64_t)vm.inactive_count * page;
        s->wired_bytes = (uint64_t)vm.wire_count * page;
        s->compressor_bytes = (uint64_t)vm.compressor_page_count * page;
    }
    struct xsw_usage swap;
    size = sizeof(swap);
    s->swap_error = sysctlbyname("vm.swapusage", &swap, &size, NULL, 0) == 0 ? 0 : errno;
    if (!s->swap_error) s->swap_used_bytes = swap.xsu_used;
    return s->cpu_error || s->memory_error ? -1 : 0;
}

int cmm_list_pids(int32_t *pids, size_t capacity) {
    if (capacity > INT_MAX / sizeof(int32_t)) return -EINVAL;
    int result = proc_listallpids(pids, (int)(capacity * sizeof(int32_t)));
    return result < 0 ? -errno : result;
}

int cmm_read_process(int32_t pid, cmm_process_sample *s) {
    struct proc_bsdinfo before, after;
    struct rusage_info_v4 usage;
    memset(s, 0, sizeof(*s));
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &before, sizeof(before)) != sizeof(before))
        return errno ? errno : ESRCH;
    if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&usage) != 0)
        return errno ? errno : ESRCH;
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &after, sizeof(after)) != sizeof(after))
        return errno ? errno : ESRCH;
    if (before.pbi_start_tvsec != after.pbi_start_tvsec || before.pbi_start_tvusec != after.pbi_start_tvusec)
        return ESRCH; // PID reused while reading; discard the entire mixed sample.
    s->pid = pid; s->uid = before.pbi_uid;
    s->start_seconds = before.pbi_start_tvsec; s->start_microseconds = before.pbi_start_tvusec;
    s->user_ns = usage.ri_user_time; s->system_ns = usage.ri_system_time;
    s->footprint_bytes = usage.ri_phys_footprint; s->resident_bytes = usage.ri_resident_size;
    s->disk_read_bytes = usage.ri_diskio_bytesread; s->disk_write_bytes = usage.ri_diskio_byteswritten;
    return 0;
}

int cmm_process_path(int32_t pid, char *buffer, uint32_t capacity) {
    return proc_pidpath(pid, buffer, capacity);
}

int cmm_registry_service_count(const char *class_name) {
    io_iterator_t iterator = IO_OBJECT_NULL;
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(class_name), &iterator);
    if (kr != KERN_SUCCESS) return -(int)kr;
    int count = 0;
    io_object_t entry;
    while ((entry = IOIteratorNext(iterator))) { count++; IOObjectRelease(entry); }
    IOObjectRelease(iterator);
    return count;
}

int cmm_smc_open_status(void) {
    io_service_t smc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!smc) return -1;
    io_connect_t connection = IO_OBJECT_NULL;
    kern_return_t status = IOServiceOpen(smc, mach_task_self(), 0, &connection);
    if (connection) IOServiceClose(connection);
    IOObjectRelease(smc);
    return (int)status;
}

uint64_t cmm_continuous_ns(void) {
    mach_timebase_info_data_t scale;
    mach_timebase_info(&scale);
    return (uint64_t)(((__uint128_t)mach_continuous_time() * scale.numer) / scale.denom);
}

#include <CoreFoundation/CoreFoundation.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <math.h>

static int cmm_number(CFDictionaryRef dict, CFStringRef key, uint64_t *out) {
    CFTypeRef number = CFDictionaryGetValue(dict, key);
    int64_t value = 0;
    if (!number || CFGetTypeID(number) != CFNumberGetTypeID() || !CFNumberGetValue(number, kCFNumberSInt64Type, &value) || value < 0) return -1;
    *out = (uint64_t)value; return 0;
}
int cmm_memory_pressure(void) {
    int value = 0; size_t size = sizeof(value);
    return sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &size, NULL, 0) == 0 ? value : -1;
}
int cmm_io_counters(uint64_t *nr, uint64_t *nw, uint64_t *dr, uint64_t *dw) {
    *nr = *nw = *dr = *dw = 0;
    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) != 0) return -1;
    for (struct ifaddrs *p = list; p; p = p->ifa_next) {
        if (!p->ifa_addr || p->ifa_addr->sa_family != AF_LINK || (p->ifa_flags & IFF_LOOPBACK) || strncmp(p->ifa_name, "en", 2) || !p->ifa_data) continue;
        struct if_data *data = p->ifa_data; *nr += data->ifi_ibytes; *nw += data->ifi_obytes;
    }
    freeifaddrs(list);
    io_iterator_t iterator = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) != KERN_SUCCESS) return -2;
    io_object_t entry; int readable = 0;
    while ((entry = IOIteratorNext(iterator))) {
        CFTypeRef value = IORegistryEntryCreateCFProperty(entry, CFSTR("Statistics"), kCFAllocatorDefault, 0);
        if (value && CFGetTypeID(value) == CFDictionaryGetTypeID()) {
            uint64_t read = 0, write = 0;
            if (!cmm_number(value, CFSTR("Bytes (Read)"), &read) && !cmm_number(value, CFSTR("Bytes (Write)"), &write)) { *dr += read; *dw += write; readable++; }
        }
        if (value) CFRelease(value); IOObjectRelease(entry);
    }
    IOObjectRelease(iterator); return readable ? 0 : 1;
}

/* AppleSMC user-client ABI, readKeyInfo (9) and readBytes (5) only. */
typedef struct {
    uint32_t key;
    struct { uint8_t major, minor, build, reserved; uint16_t release; } version;
    struct { uint16_t version, length; uint32_t cpu, gpu, memory; } limits;
    struct { uint32_t size, type; uint8_t attributes; } info;
    uint8_t result, status, command;
    uint32_t data;
    uint8_t bytes[32];
} cmm_smc_message;
static uint32_t cmm_fourcc(const char *key) { return (uint32_t)(uint8_t)key[0]<<24 | (uint32_t)(uint8_t)key[1]<<16 | (uint32_t)(uint8_t)key[2]<<8 | (uint8_t)key[3]; }
int cmm_smc_temperature(const char key[4], double *value) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return ENOTSUP;
    io_connect_t connection = 0;
    kern_return_t code = IOServiceOpen(service, mach_task_self(), 0, &connection); IOObjectRelease(service);
    if (code != KERN_SUCCESS) return EACCES;
    cmm_smc_message input = {0}, output = {0}; size_t size = sizeof(output);
    input.key = cmm_fourcc(key); input.command = 9;
    code = IOConnectCallStructMethod(connection, 2, &input, sizeof(input), &output, &size);
    if (code || output.result || output.info.size > 32) { IOServiceClose(connection); return ENOTSUP; }
    input.info = output.info; input.command = 5; uint32_t type = output.info.type; size = sizeof(output);
    code = IOConnectCallStructMethod(connection, 2, &input, sizeof(input), &output, &size); IOServiceClose(connection);
    if (code || output.result) return EIO;
    if (type == cmm_fourcc("sp78") && input.info.size == 2) { int16_t raw = (int16_t)((output.bytes[0]<<8)|output.bytes[1]); *value = raw/256.0; }
    else if (type == cmm_fourcc("flt ") && input.info.size == 4) { float raw; memcpy(&raw, output.bytes, 4); *value = raw; }
    else return ENOTSUP;
    return isfinite(*value) && *value >= -20 && *value <= 130 ? 0 : EIO;
}
int cmm_gpu_percent(double *value) {
    io_iterator_t iterator = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator)) return EIO;
    io_object_t entry; int found = 0; double maximum = 0;
    while ((entry = IOIteratorNext(iterator))) {
        CFTypeRef property = IORegistryEntryCreateCFProperty(entry, CFSTR("PerformanceStatistics"), kCFAllocatorDefault, 0);
        if (property && CFGetTypeID(property) == CFDictionaryGetTypeID()) {
            CFTypeRef number = CFDictionaryGetValue(property, CFSTR("Device Utilization %"));
            double raw;
            if (number && CFGetTypeID(number) == CFNumberGetTypeID() &&
                CFNumberGetValue(number, kCFNumberDoubleType, &raw) && isfinite(raw) && raw >= 0 && raw <= 100) {
                maximum = fmax(maximum, raw); found++;
            }
        }
        if (property) CFRelease(property); IOObjectRelease(entry);
    }
    IOObjectRelease(iterator); if (!found) return ENOTSUP; *value = maximum; return 0;
}

#include <dlfcn.h>
int cmm_hid_temperatures(cmm_hid_temperature *values, size_t capacity) {
    if (capacity > 64) return -EINVAL;
    typedef CFTypeRef (*create_fn)(CFAllocatorRef);
    typedef int (*match_fn)(CFTypeRef, CFDictionaryRef);
    typedef CFArrayRef (*services_fn)(CFTypeRef);
    typedef CFTypeRef (*property_fn)(CFTypeRef, CFStringRef);
    typedef CFTypeRef (*event_fn)(CFTypeRef, int64_t, int32_t, int64_t);
    typedef double (*float_fn)(CFTypeRef, int32_t);
    void *library = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY | RTLD_LOCAL);
    if (!library) return -ENOTSUP;
    create_fn create = (create_fn)dlsym(library,"IOHIDEventSystemClientCreate");
    match_fn match = (match_fn)dlsym(library,"IOHIDEventSystemClientSetMatching");
    services_fn services = (services_fn)dlsym(library,"IOHIDEventSystemClientCopyServices");
    property_fn property = (property_fn)dlsym(library,"IOHIDServiceClientCopyProperty");
    event_fn event = (event_fn)dlsym(library,"IOHIDServiceClientCopyEvent");
    float_fn number = (float_fn)dlsym(library,"IOHIDEventGetFloatValue");
    if (!create || !match || !services || !property || !event || !number) { dlclose(library); return -ENOTSUP; }
    CFTypeRef client = create(kCFAllocatorDefault);
    if (!client) { dlclose(library); return -EACCES; }
    int page = 0xff00, usage = 5;
    CFNumberRef pageNumber = CFNumberCreate(NULL,kCFNumberIntType,&page), usageNumber = CFNumberCreate(NULL,kCFNumberIntType,&usage);
    const void *keys[] = {CFSTR("PrimaryUsagePage"),CFSTR("PrimaryUsage")}, *objects[] = {pageNumber,usageNumber};
    CFDictionaryRef matching = CFDictionaryCreate(NULL,keys,objects,2,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
    match(client,matching); CFRelease(matching); CFRelease(pageNumber); CFRelease(usageNumber);
    CFArrayRef list = services(client); int count = 0;
    if (list) {
        CFIndex length = CFArrayGetCount(list); if (length > 256) length = 256;
        for (CFIndex index = 0; index < length && count < (int)capacity; index++) {
            CFTypeRef service = CFArrayGetValueAtIndex(list,index), sample = event(service,15,0,0);
            if (!sample) continue;
            double value = number(sample,15<<16); CFRelease(sample);
            if (!isfinite(value) || value < -20 || value > 130) continue;
            CFTypeRef name = property(service,CFSTR("Product"));
            if (name && CFGetTypeID(name) == CFStringGetTypeID() && CFStringGetCString(name,values[count].name,sizeof(values[count].name),kCFStringEncodingUTF8)) { values[count].celsius = value; count++; }
            if (name) CFRelease(name);
        }
        CFRelease(list);
    }
    CFRelease(client); dlclose(library); return count;
}
int cmm_network_interfaces(cmm_network_interface *values, size_t capacity) {
    if (capacity > 16) return -EINVAL;
    struct ifaddrs *list = NULL; if (getifaddrs(&list)) return -errno; int count = 0;
    for (struct ifaddrs *p = list; p && count < (int)capacity; p = p->ifa_next) {
        if (!p->ifa_addr || p->ifa_addr->sa_family != AF_LINK || (p->ifa_flags & IFF_LOOPBACK) || strncmp(p->ifa_name,"en",2) || !p->ifa_data) continue;
        struct if_data *data = p->ifa_data;
        if (strlen(p->ifa_name) >= sizeof(values[count].name)) continue;
        strcpy(values[count].name,p->ifa_name); values[count].received_bytes = data->ifi_ibytes; values[count].sent_bytes = data->ifi_obytes; count++;
    }
    freeifaddrs(list); return count;
}

#include <IOKit/pwr_mgt/IOPMLib.h>
#include <IOKit/IOMessage.h>
typedef struct { void *context; cmm_power_callback callback; io_connect_t root; } cmm_power_observer;
static void cmm_power_event(void *reference,io_service_t service,natural_t message,void *argument) {
    (void)service; cmm_power_observer *observer = reference;
    if (message == kIOMessageSystemWillSleep) { observer->callback(observer->context,1); IOAllowPowerChange(observer->root,(long)argument); }
    else if (message == kIOMessageCanSystemSleep) { IOAllowPowerChange(observer->root,(long)argument); }
    else if (message == kIOMessageSystemHasPoweredOn) { observer->callback(observer->context,0); }
}
void cmm_watch_power(void *context,cmm_power_callback callback) {
    cmm_power_observer observer = {context,callback,0}; IONotificationPortRef port = NULL; io_object_t notifier = 0;
    observer.root = IORegisterForSystemPower(&observer,&port,cmm_power_event,&notifier);
    if (!observer.root || !port) return;
    CFRunLoopAddSource(CFRunLoopGetCurrent(),IONotificationPortGetRunLoopSource(port),kCFRunLoopDefaultMode);
    CFRunLoopRun();
    IODeregisterForSystemPower(&notifier); IOServiceClose(observer.root); IONotificationPortDestroy(port);
}

#include <IOKit/IOCFPlugIn.h>
#include <IOKit/storage/ata/ATASMARTLib.h>
#include <IOKit/storage/nvme/NVMeSMARTLibExternal.h>

/* Read a checksummed ATA SMART page, using only temperature attribute 194.
 * Do not enable SMART, start tests, write logs, or change drive power state. */
int cmm_ata_temperature(const uint8_t *data, size_t length, double *value) {
    if (!data || !value || length != 512) return EINVAL;
    unsigned sum = 0;
    for (size_t i = 0; i < length; i++) sum += data[i];
    if ((sum & 255) != 0) return EIO;
    for (size_t offset = 2; offset + 12 <= 362; offset += 12) {
        if (data[offset] == 194) {
            double celsius = data[offset + 5];
            if (celsius < 1 || celsius > 130) return EIO;
            *value = celsius; return 0;
        }
    }
    return ENOTSUP;
}
static int cmm_smart_temperature(io_service_t service, int nvme, double *value) {
    IOCFPlugInInterface **plugin = NULL; SInt32 score = 0;
    IOReturn code = IOCreatePlugInInterfaceForService(service,
        nvme ? kIONVMeSMARTUserClientTypeID : kIOATASMARTUserClientTypeID,
        kIOCFPlugInInterfaceID, &plugin, &score);
    if (code != kIOReturnSuccess || !plugin)
        return code == kIOReturnNotPrivileged || code == kIOReturnNotPermitted ? EACCES : ENOTSUP;
    int result = ENOTSUP;
    if (nvme) {
        IONVMeSMARTInterface **smart = NULL;
        HRESULT query = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIONVMeSMARTInterfaceID), (void **)&smart);
        if (query == S_OK && smart) {
            NVMeSMARTData page = {0}; code = (*smart)->SMARTReadData(smart, &page);
            if (code == kIOReturnSuccess) {
                const uint8_t *bytes = (const uint8_t *)&page;
                double celsius = (bytes[1] | (bytes[2] << 8)) - 273.15;
                if (isfinite(celsius) && celsius >= -20 && celsius <= 130) { *value = celsius; result = 0; }
                else result = EIO;
            } else result = code == kIOReturnNotPrivileged || code == kIOReturnNotPermitted ? EACCES : EIO;
            (*smart)->Release(smart);
        }
    } else {
        IOATASMARTInterface **smart = NULL;
        HRESULT query = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOATASMARTInterfaceID), (void **)&smart);
        if (query == S_OK && smart) {
            ATASMARTData page = {0}; code = (*smart)->SMARTReadData(smart, &page);
            result = code == kIOReturnSuccess ? cmm_ata_temperature((const uint8_t *)&page, sizeof(page), value) :
                code == kIOReturnNotPrivileged || code == kIOReturnNotPermitted ? EACCES : EIO;
            (*smart)->Release(smart);
        }
    }
    IODestroyPlugInInterface(plugin); return result;
}
static void cmm_disk_string(CFDictionaryRef dictionary, CFStringRef key, char *out, size_t size) {
    CFTypeRef value = dictionary ? CFDictionaryGetValue(dictionary, key) : NULL;
    if (value && CFGetTypeID(value) == CFStringGetTypeID()) CFStringGetCString(value, out, size, kCFStringEncodingUTF8);
}
int cmm_disk_temperatures(cmm_disk_temperature *values, size_t capacity) {
    if (!values || capacity > 32) return -EINVAL;
    io_iterator_t iterator = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDevice"), &iterator)) return -EIO;
    io_service_t service; int count = 0;
    while (count < (int)capacity && (service = IOIteratorNext(iterator))) {
        cmm_disk_temperature *reading = &values[count]; memset(reading, 0, sizeof(*reading));
        CFTypeRef characteristics = IORegistryEntryCreateCFProperty(service, CFSTR("Device Characteristics"), NULL, 0);
        if (characteristics && CFGetTypeID(characteristics) == CFDictionaryGetTypeID()) {
            cmm_disk_string(characteristics, CFSTR("Product Name"), reading->name, sizeof(reading->name));
            cmm_disk_string(characteristics, CFSTR("Serial Number"), reading->id, sizeof(reading->id));
        }
        if (characteristics) CFRelease(characteristics);
        if (!reading->name[0]) IORegistryEntryGetName(service, reading->name);
        if (!reading->id[0]) {
            CFTypeRef bsd = IORegistryEntrySearchCFProperty(service, kIOServicePlane, CFSTR("BSD Name"), NULL, kIORegistryIterateRecursively);
            if (bsd && CFGetTypeID(bsd) == CFStringGetTypeID()) CFStringGetCString(bsd, reading->id, sizeof(reading->id), kCFStringEncodingUTF8);
            if (bsd) CFRelease(bsd);
        }
        if (!reading->id[0]) { uint64_t id = 0; IORegistryEntryGetRegistryEntryID(service, &id); snprintf(reading->id, sizeof(reading->id), "%llu", (unsigned long long)id); }
        CFTypeRef protocol = IORegistryEntryCreateCFProperty(service, CFSTR("Protocol Characteristics"), NULL, 0);
        char location[64] = {0};
        if (protocol && CFGetTypeID(protocol) == CFDictionaryGetTypeID()) cmm_disk_string(protocol, CFSTR("Physical Interconnect Location"), location, sizeof(location));
        if (protocol) CFRelease(protocol);
        reading->external = strcmp(location, "External") == 0;
        CFTypeRef nvme = IORegistryEntryCreateCFProperty(service, CFSTR(kIOPropertyNVMeSMARTCapableKey), NULL, 0);
        CFTypeRef ata = IORegistryEntryCreateCFProperty(service, CFSTR("SMART Capable"), NULL, 0);
        int hasNVMe = nvme && CFEqual(nvme, kCFBooleanTrue), hasATA = ata && CFEqual(ata, kCFBooleanTrue);
        reading->status = hasNVMe || hasATA ? cmm_smart_temperature(service, hasNVMe, &reading->celsius) : ENOTSUP;
        if (nvme) CFRelease(nvme); if (ata) CFRelease(ata);
        IOObjectRelease(service); count++;
    }
    IOObjectRelease(iterator); return count;
}
