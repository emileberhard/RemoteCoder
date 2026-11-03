#if RC_PERF_HARNESS
import Darwin

enum ProcessMetrics {
    static func processCPUSeconds() -> Double? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    @MainActor static func mainThreadCPUSeconds() -> Double? {
        ProcessResources.mainThreadCPUNanoseconds().map { Double($0) / 1e9 }
    }

    static func footprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }

    static func cpuMilliseconds(from start: Double?, to end: Double?) -> Double? {
        guard let start, let end else { return nil }
        return (end - start) * 1_000
    }

    static func megabytes(_ bytes: UInt64?) -> Double? {
        bytes.map { Double($0) / 1_048_576 }
    }

    #if os(macOS)
    static func logicalWrites() -> UInt64? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? info.ri_logical_writes : nil
    }
    #endif

    private static func seconds(_ value: timeval) -> Double {
        Double(value.tv_sec) + Double(value.tv_usec) / 1e6
    }
}
#endif
