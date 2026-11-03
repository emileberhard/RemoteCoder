import Darwin
import Foundation

struct ProcessResources: Sendable, Equatable {
    var cpuUserNanoseconds: UInt64
    var cpuSystemNanoseconds: UInt64
    var interruptWakeups: UInt64
    var idleWakeups: UInt64
    var timerWakeups: UInt64
    var footprintBytes: UInt64
    var mainThreadCPUNanoseconds: UInt64?

    var cpuNanoseconds: UInt64 { cpuUserNanoseconds &+ cpuSystemNanoseconds }

    static func current() -> ProcessResources? {
        var power = task_power_info_v2()
        var powerCount = mach_msg_type_number_t(MemoryLayout<task_power_info_v2>.size / MemoryLayout<natural_t>.size)
        let powerResult = withUnsafeMutablePointer(to: &power) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(powerCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_POWER_INFO_V2), $0, &powerCount)
            }
        }
        var memory = task_vm_info_data_t()
        var memoryCount = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let memoryResult = withUnsafeMutablePointer(to: &memory) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(memoryCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &memoryCount)
            }
        }
        guard powerResult == KERN_SUCCESS, memoryResult == KERN_SUCCESS else { return nil }
        let cpu = power.cpu_energy
        return ProcessResources(
            cpuUserNanoseconds: MachTime.nanoseconds(cpu.total_user),
            cpuSystemNanoseconds: MachTime.nanoseconds(cpu.total_system),
            interruptWakeups: cpu.task_interrupt_wakeups,
            idleWakeups: cpu.task_platform_idle_wakeups,
            timerWakeups: cpu.task_timer_wakeups_bin_1 &+ cpu.task_timer_wakeups_bin_2,
            footprintBytes: UInt64(memory.phys_footprint),
            mainThreadCPUNanoseconds: mainThreadCPUNanoseconds()
        )
    }

    static func mainThreadCPUNanoseconds() -> UInt64? {
        guard pthread_main_np() != 0 else { return nil }
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(pthread_mach_thread_np(pthread_self()), thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let seconds = UInt64(info.user_time.seconds) + UInt64(info.system_time.seconds)
        let microseconds = UInt64(info.user_time.microseconds) + UInt64(info.system_time.microseconds)
        return seconds * 1_000_000_000 + microseconds * 1_000
    }
}

enum MachTime {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func nanoseconds(_ ticks: UInt64) -> UInt64 {
        let product = ticks.multipliedFullWidth(by: UInt64(timebase.numer))
        return UInt64(timebase.denom).dividingFullWidth(product).quotient
    }

    static func continuousNanoseconds() -> UInt64 {
        nanoseconds(mach_continuous_time())
    }
}
