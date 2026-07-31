#ifndef SYSTEM_RESOURCE_MONITOR_H
#define SYSTEM_RESOURCE_MONITOR_H

#include <cstdint>
#include <string>

class SystemResourceMonitor {
public:
    SystemResourceMonitor();
    ~SystemResourceMonitor();

    // 获取CPU使用率 (0.0 - 100.0)，首次调用返回0.0或-1.0
    double getCPUUsage();

    // 获取内存使用率 (0.0 - 100.0)
    double getMemoryUsage();

    // 获取总内存 (MB)
    uint64_t getTotalMemory() const;

    // 获取已用内存 (MB)
    uint64_t getUsedMemory() const;

    // 获取可用内存 (MB)
    uint64_t getAvailableMemory() const;

    // 获取进程CPU使用率 (0.0 - 100.0)
    double getProcessCPUUsage();

    // 获取进程内存使用 (MB)
    uint64_t getProcessMemoryUsage() const;

    std::string getError() const { return m_error; }

private:
    void updateCPUTimes();
    double calculateCPUUsage();

    // Linux 实现
    void initLinux();
    double getCPUUsageLinux();
    void getMemoryInfoLinux(uint64_t& total, uint64_t& available);

    // Windows 实现
    void initWindows();
    double getCPUUsageWindows();
    void getMemoryInfoWindows(uint64_t& total, uint64_t& available);

    // macOS 实现
    void initMacOS();
    double getCPUUsageMacOS();
    void getMemoryInfoMacOS(uint64_t& total, uint64_t& available);

private:
    bool m_initialized;
    std::string m_error;

    // CPU 采样数据
    uint64_t m_prevUser;
    uint64_t m_prevNice;
    uint64_t m_prevSystem;
    uint64_t m_prevIdle;
    uint64_t m_prevIowait;
    uint64_t m_prevIrq;
    uint64_t m_prevSoftirq;
    uint64_t m_prevSteal;
    uint64_t m_prevTotal;
    bool m_firstSample;

    // 平台相关句柄
    void* m_platformData;
};

#endif
#include "system_resource_monitor.h"
#include <cmath>
#include <cstdio>
#include <cstring>
#include <chrono>
#include <thread>

#if defined(_WIN32)
    #include <windows.h>
    #include <pdh.h>
    #include <psapi.h>
    #pragma comment(lib, "pdh.lib")
    #pragma comment(lib, "psapi.lib")
#elif defined(__APPLE__)
    #include <mach/mach.h>
    #include <mach/mach_host.h>
    #include <mach/vm_statistics.h>
    #include <host_info.h>
    #include <sys/types.h>
    #include <sys/sysctl.h>
#else
    #include <unistd.h>
    #include <fstream>
    #include <sstream>
    #include <iostream>
#endif

struct PlatformData {
#if defined(_WIN32)
    PDH_HQUERY query;
    PDH_HCOUNTER counter;
    bool hasCounter;
#elif defined(__APPLE__)
    host_cpu_load_info_data_t prevCpuInfo;
    bool firstSample;
#else
    uint64_t prevUser;
    uint64_t prevNice;
    uint64_t prevSystem;
    uint64_t prevIdle;
    uint64_t prevIowait;
    uint64_t prevIrq;
    uint64_t prevSoftirq;
    uint64_t prevSteal;
    bool firstSample;
#endif
};

SystemResourceMonitor::SystemResourceMonitor() : m_initialized(false), m_error(""), m_platformData(nullptr) {
    m_prevUser = m_prevNice = m_prevSystem = m_prevIdle = m_prevIowait = 
    m_prevIrq = m_prevSoftirq = m_prevSteal = m_prevTotal = 0;
    m_firstSample = true;

    m_platformData = new PlatformData();
    PlatformData* data = static_cast<PlatformData*>(m_platformData);
#if defined(_WIN32)
    data->query = nullptr;
    data->counter = nullptr;
    data->hasCounter = false;
#elif defined(__APPLE__)
    data->firstSample = true;
    memset(&data->prevCpuInfo, 0, sizeof(data->prevCpuInfo));
#else
    data->prevUser = data->prevNice = data->prevSystem = data->prevIdle = 
    data->prevIowait = data->prevIrq = data->prevSoftirq = data->prevSteal = 0;
    data->firstSample = true;
#endif

#if defined(_WIN32)
    initWindows();
#elif defined(__APPLE__)
    initMacOS();
#else
    initLinux();
#endif

    m_initialized = true;
}

SystemResourceMonitor::~SystemResourceMonitor() {
    if (m_platformData) {
        PlatformData* data = static_cast<PlatformData*>(m_platformData);
#if defined(_WIN32)
        if (data->counter) PdhRemoveCounter(data->counter);
        if (data->query) PdhCloseQuery(data->query);
#endif
        delete data;
    }
}

#if defined(_WIN32)
void SystemResourceMonitor::initWindows() {
    PlatformData* data = static_cast<PlatformData*>(m_platformData);
    if (PdhOpenQuery(nullptr, 0, &data->query) != ERROR_SUCCESS) {
        m_error = "Failed to open PDH query";
        return;
    }
    if (PdhAddCounter(data->query, L"\\Processor(_Total)\\% Processor Time", 0, &data->counter) != ERROR_SUCCESS) {
        m_error = "Failed to add PDH counter";
        return;
    }
    PdhCollectQueryData(data->query);
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
    PdhCollectQueryData(data->query);
    data->hasCounter = true;
}
#endif

#if defined(__APPLE__)
void SystemResourceMonitor::initMacOS() {
    PlatformData* data = static_cast<PlatformData*>(m_platformData);
    data->firstSample = true;
}
#endif

void SystemResourceMonitor::initLinux() {
    PlatformData* data = static_cast<PlatformData*>(m_platformData);
    data->firstSample = true;
    std::ifstream statFile("/proc/stat");
    if (statFile.is_open()) {
        std::string line;
        std::getline(statFile, line);
        std::istringstream iss(line);
        std::string cpu;
        iss >> cpu;
        if (cpu == "cpu") {
            iss >> data->prevUser >> data->prevNice >> data->prevSystem >> 
                   data->prevIdle >> data->prevIowait >> data->prevIrq >> 
                   data->prevSoftirq >> data->prevSteal;
            data->firstSample = false;
        }
        statFile.close();
    }
}

double SystemResourceMonitor::getCPUUsage() {
    if (!m_initialized) return -1.0;
#if defined(_WIN32)
    return getCPUUsageWindows();
#elif defined(__APPLE__)
    return getCPUUsageMacOS();
#else
    return getCPUUsageLinux();
#endif
}

#if defined(_WIN32)
double SystemResourceMonitor::getCPUUsageWindows() {
    PlatformData* data = static_cast<PlatformData*>(m_platformData);
    if (!data->hasCounter) return -1.0;
    
    PDH_FMT_COUNTERVALUE counterVal;
    if (PdhCollectQueryData(data->query) != ERROR_SUCCESS) return -1.0;
    if (PdhGetFormattedCounterValue(data->counter, PDH_FMT_DOUBLE, nullptr, &counterVal) != ERROR_SUCCESS) return -1.0;
    
    if (counterVal.CStatus != ERROR_SUCCESS) return -1.0;
    return counterVal.doubleValue;
}
#endif

#if defined(__APPLE__)
double SystemResourceMonitor::getCPUUsageMacOS() {
    PlatformData* data = static_cast<PlatformData*>(m_platformData);
    mach_msg_type_number_t count = HOST_CPU_LOAD_INFO_COUNT;
    host_cpu_load_info_data_t cpuInfo;
    
    if (host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, (host_info_t)&cpuInfo, &count) != KERN_SUCCESS) {
        return -1.0;
    }

    if (data->firstSample) {
        data->prevCpuInfo = cpuInfo;
        data->firstSample = false;
        return 0.0;
    }

    uint64_t user = cpuInfo.cpu_ticks[CPU_STATE_USER] - data->prevCpuInfo.cpu_ticks[CPU_STATE_USER];
    uint64_t nice = cpuInfo.cpu_ticks[CPU_STATE_NICE] - data->prevCpuInfo.cpu_ticks[CPU_STATE_NICE];
    uint64_t sys = cpuInfo.cpu_ticks[CPU_STATE_SYSTEM] - data->prevCpuInfo.cpu_ticks[CPU_STATE_SYSTEM];
    uint64_t idle = cpuInfo.cpu_ticks[CPU_STATE_IDLE] - data->prevCpuInfo.cpu_ticks[CPU_STATE_IDLE];
    uint64_t total = user + nice + sys + idle;

    data->prevCpuInfo = cpuInfo;

    if (total == 0) return 0.0;
    return (double)(total - idle) / (double)total * 100.0;
}
#endif

double SystemResourceMonitor::getCPUUsageLinux() {
    PlatformData* data = static_cast<PlatformData*>(m_platformData);
    std::ifstream statFile("/proc/stat");
    if (!statFile.is_open()) {
        m_error = "Cannot open /proc/stat";
        return -1.0;
    }

    std::string line;
    std::getline(statFile, line);
    statFile.close();

    std::istringstream iss(line);
    std::string cpu;
    uint64_t user, nice, system, idle, iowait, irq, softirq, steal;
    iss >> cpu;
    
    if (cpu != "cpu" || !(iss >> user >> nice >> system >> idle >> iowait >> irq >> softirq >> steal)) {
        m_error = "Failed to parse /proc/stat";
        return -1.0;
    }

    if (data->firstSample) {
        data->prevUser = user; data->prevNice = nice; data->prevSystem = system;
        data->prevIdle = idle; data->prevIowait = iowait; data->prevIrq = irq;
        data->prevSoftirq = softirq; data->prevSteal = steal;
        data->firstSample = false;
        return 0.0;
    }

    uint64_t prevIdle = data->prevIdle + data->prevIowait;
    uint64_t idle = idle + iowait;
    
    uint64_t prevNonIdle = data->prevUser + data->prevNice + data->prevSystem + 
                           data->prevIrq + data->prevSoftirq + data->prevSteal;
    uint64_t nonIdle = user + nice + system + irq + softirq + steal;
    
    uint64_t prevTotal = prevIdle + prevNonIdle;
    uint64_t total = idle + nonIdle;
    
    uint64_t totalDiff = total - prevTotal;
    uint64_t idleDiff = idle - prevIdle;

    data->prevUser = user; data->prevNice = nice; data->prevSystem = system;
    data->prevIdle = idle - iowait; data->prevIowait = iowait; data->prevIrq = irq;
    data->prevSoftirq = softirq; data->prevSteal = steal;

    if (totalDiff == 0) return 0.0;
    return (double)(totalDiff - idleDiff) / (double)totalDiff * 100.0;
}

double SystemResourceMonitor::getMemoryUsage() {
    if (!m_initialized) return -1.0;
    uint64_t total = 0, available = 0;
#if defined(_WIN32)
    getMemoryInfoWindows(total, available);
#elif defined(__APPLE__)
    getMemoryInfoMacOS(total, available);
#else
    getMemoryInfoLinux(total, available);
#endif
    if (total == 0) return 0.0;
    return (double)(total - available) / (double)total * 100.0;
}

uint64_t SystemResourceMonitor::getTotalMemory() const {
    uint64_t total = 0, available = 0;
#if defined(_WIN32)
    const_cast<SystemResourceMonitor*>(this)->getMemoryInfoWindows(total, available);
#elif defined(__APPLE__)
    const_cast<SystemResourceMonitor*>(this)->getMemoryInfoMacOS(total, available);
#else
    const_cast<SystemResourceMonitor*>(this)->getMemoryInfoLinux(total, available);
#endif
    return total;
}

uint64_t SystemResourceMonitor::getUsedMemory() const {
    uint64_t total = 0, available = 0;
#if defined(_WIN32)
    const_cast<SystemResourceMonitor*>(this)->getMemoryInfoWindows(total, available);
#elif defined(__APPLE__)
    const_cast<SystemResourceMonitor*>(this)->getMemoryInfoMacOS(total, available);
#else
    const_cast<SystemResourceMonitor*>(this)->getMemoryInfoLinux(total, available);
#endif
    return total - available;
}

uint64_t SystemResourceMonitor::getAvailableMemory() const {
    uint64_t total = 0, available = 0;
#if defined(_WIN32)
    const_cast<SystemResourceMonitor*>(this)->getMemoryInfoWindows(total, available);
#elif defined(__APPLE__)
    const_cast<SystemResourceMonitor*>(this)->getMemoryInfoMacOS(total, available);
#else
    const_cast<SystemResourceMonitor*>(this)->getMemoryInfoLinux(total, available);
#endif
    return available;
}

#if defined(_WIN32)
void SystemResourceMonitor::getMemoryInfoWindows(uint64_t& total, uint64_t& available) {
    MEMORYSTATUSEX memInfo;
    memInfo.dwLength = sizeof(memInfo);
    if (GlobalMemoryStatusEx(&memInfo)) {
        total = (uint64_t)(memInfo.ullTotalPhys / (1024 * 1024));
        available = (uint64_t)(memInfo.ullAvailPhys / (1024 * 1024));
    }
}
#endif

#if defined(__APPLE__)
void SystemResourceMonitor::getMemoryInfoMacOS(uint64_t& total, uint64_t& available) {
    int64_t hw_memsize = 0;
    size_t size = sizeof(hw_memsize);
    if (sysctlbyname("hw.memsize", &hw_memsize, &size, nullptr, 0) == 0) {
        total = (uint64_t)(hw_memsize / (1024 * 1024));
    }

    vm_size_t pagesize = 0;
    vm_statistics64_data_t vmStats;
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vmStats, &count) == KERN_SUCCESS) {
        if (sysctlbyname("hw.pagesize", &pagesize, &size, nullptr, 0) != 0) {
            pagesize = 4096;
        }
        available = (uint64_t)((vmStats.free_count + vmStats.inactive_count) * pagesize / (1024 * 1024));
    }
}
#endif

void SystemResourceMonitor::getMemoryInfoLinux(uint64_t& total, uint64_t& available) {
    std::ifstream memFile("/proc/meminfo");
    if (!memFile.is_open()) return;

    std::string line;
    uint64_t memTotal = 0, memAvailable = 0;
    while (std::getline(memFile, line)) {
        std::istringstream iss(line);
        std::string key;
        uint64_t value;
        std::string unit;
        iss >> key >> value >> unit;
        
        if (key == "MemTotal:") {
            memTotal = value;
        } else if (key == "MemAvailable:") {
            memAvailable = value;
        } else if (key == "MemFree:" && memAvailable == 0) {
            // 如果没有MemAvailable，使用MemFree作为fallback
            memAvailable = value;
        }
    }
    memFile.close();

    total = memTotal / 1024;
    available = memAvailable / 1024;
}

double SystemResourceMonitor::getProcessCPUUsage() {
    if (!m_initialized) return -1.0;
#if defined(_WIN32)
    FILETIME ftCreate, ftExit, ftKernel, ftUser;
    if (GetProcessTimes(GetCurrentProcess(), &ftCreate, &ftExit, &ftKernel, &ftUser) == 0) {
        return -1.0;
    }
    
    ULARGE_INTEGER kernel, user;
    kernel.LowPart = ftKernel.dwLowDateTime;
    kernel.HighPart = ftKernel.dwHighDateTime;
    user.LowPart = ftUser.dwLowDateTime;
    user.HighPart = ftUser.dwHighDateTime;
    
    static ULARGE_INTEGER prevTotal = {0, 0};
    static ULARGE_INTEGER prevSys = {0, 0};
    
    FILETIME ftSysIdle, ftSysKernel, ftSysUser;
    GetSystemTimes(&ftSysIdle, &ftSysKernel, &ftSysUser);
    ULARGE_INTEGER sysKernel, sysUser, sysIdle;
    sysKernel.LowPart = ftSysKernel.dwLowDateTime;
    sysKernel.HighPart = ftSysKernel.dwHighDateTime;
    sysUser.LowPart = ftSysUser.dwLowDateTime;
    sysUser.HighPart = ftSysUser.dwHighDateTime;
    
    ULARGE_INTEGER sysTotal;
    sysTotal.QuadPart = sysKernel.QuadPart + sysUser.QuadPart;
    
    if (prevTotal.QuadPart == 0) {
        prevTotal.QuadPart = kernel.QuadPart + user.QuadPart;
        prevSys.QuadPart = sysTotal.QuadPart;
        return 0.0;
    }
    
    ULONGLONG procDiff = (kernel.QuadPart + user.QuadPart) - prevTotal.QuadPart;
    ULONGLONG sysDiff = sysTotal.QuadPart - prevSys.QuadPart;
    
    prevTotal.QuadPart = kernel.QuadPart + user.QuadPart;
    prevSys.QuadPart = sysTotal.QuadPart;
    
    if (sysDiff == 0) return 0.0;
    return (double)procDiff / (double)sysDiff * 100.0;
#elif defined(__APPLE__)
    task_basic_info info;
    mach_msg_type_number_t count = TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_BASIC_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) {
        return -1.0;
    }
    return 0.0; // macOS 进程CPU较复杂，此处简化
#else
    static uint64_t prevUtime = 0, prevStime = 0, prevTotal = 0;
    
    std::ifstream statFile("/proc/self/stat");
    if (!statFile.is_open()) return -1.0;
    
    std::string line;
    std::getline(statFile, line);
    statFile.close();
    
    std::istringstream iss(line);
    std::string skip;
    uint64_t utime, stime;
    
    for (int i = 0; i < 11; i++) iss >> skip;
    iss >> utime >> stime;
    
    uint64_t procTime = utime + stime;
    
    if (prevTotal == 0) {
        prevUtime = utime;
        prevStime = stime;
        std::ifstream uptime("/proc/uptime");
        if (uptime.is_open()) {
            double up;
            uptime >> up;
            prevTotal = (uint64_t)(up * sysconf(_SC_CLK_TCK));
            uptime.close();
        }
        return 0.0;
    }
    
    uint64_t procDiff = procTime - (prevUtime + prevStime);
    uint64_t totalDiff = prevTotal == 0 ? 1 : 1; // 简化计算
    
    prevUtime = utime;
    prevStime = stime;
    
    if (procDiff == 0) return 0.0;
    return (double)procDiff * 100.0;
#endif
}

uint64_t SystemResourceMonitor::getProcessMemoryUsage() const {
#if defined(_WIN32)
    PROCESS_MEMORY_COUNTERS pmc;
    if (GetProcessMemoryInfo(GetCurrentProcess(), &pmc, sizeof(pmc))) {
        return (uint64_t)(pmc.WorkingSetSize / (1024 * 1024));
    }
    return 0;
#elif defined(__APPLE__)
    task_basic_info info;
    mach_msg_type_number_t count = TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_BASIC_INFO, (task_info_t)&info, &count) == KERN_SUCCESS) {
        return (uint64_t)(info.resident_size / (1024 * 1024));
    }
    return 0;
#else
    std::ifstream statm("/proc/self/statm");
    if (!statm.is_open()) return 0;
    
    uint64_t size = 0, resident = 0;
    statm >> size >> resident;
    statm.close();
    
    long pageSize = sysconf(_SC_PAGESIZE);
    return (uint64_t)(resident * pageSize / (1024 * 1024));
#endif
}

std::string getOSVersion() {
#if defined(_WIN32)
    return "Windows";
#elif defined(__APPLE__)
    return "macOS";
#elif defined(__linux__)
    return "Linux";
#else
    return "Unknown";
#endif
}

#include <iostream>
#include <iomanip>
#include <ctime>

void printUsage(SystemResourceMonitor& monitor) {
    time_t now = time(0);
    char* dt = ctime(&now);
    dt[strlen(dt) - 1] = '\0';
    
    std::cout << "\n[" << dt << "] " << getOSVersion() << " System Monitor" << std::endl;
    std::cout << "========================================" << std::endl;
    std::cout << std::fixed << std::setprecision(1);
    
    double cpu = monitor.getCPUUsage();
    if (cpu >= 0) {
        std::cout << "CPU Usage:   " << std::setw(6) << cpu << "%" << std::endl;
    } else {
        std::cout << "CPU Usage:   N/A" << std::endl;
    }
    
    double mem = monitor.getMemoryUsage();
    if (mem >= 0) {
        std::cout << "Memory Usage:" << std::setw(6) << mem << "%" << std::endl;
        std::cout << "Total:       " << std::setw(6) << monitor.getTotalMemory() << " MB" << std::endl;
        std::cout << "Used:        " << std::setw(6) << monitor.getUsedMemory() << " MB" << std::endl;
        std::cout << "Available:   " << std::setw(6) << monitor.getAvailableMemory() << " MB" << std::endl;
    } else {
        std::cout << "Memory Usage: N/A" << std::endl;
    }
    
    double procMem = monitor.getProcessMemoryUsage();
    if (procMem >= 0) {
        std::cout << "Process Mem: " << std::setw(6) << procMem << " MB" << std::endl;
    }
    
    std::cout << "========================================" << std::endl;
}

int main() {
    std::cout << "System Resource Monitor" << std::endl;
    std::cout << "Press Ctrl+C to exit" << std::endl;
    
    SystemResourceMonitor monitor;
    
    if (!monitor.getError().empty()) {
        std::cerr << "Initialization error: " << monitor.getError() << std::endl;
        return 1;
    }
    
    while (true) {
        printUsage(monitor);
        std::this_thread::sleep_for(std::chrono::seconds(2));
    }
    
    return 0;
}