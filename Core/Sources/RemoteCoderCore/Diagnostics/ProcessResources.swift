import Darwin
import Foundation

struct ProcessResources: Sendable, Equatable {
    var cpuUserNanoseconds: UInt64
    var cpuSystemNanoseconds: UInt64
    var gpuNanoseconds: UInt64
    var interruptWakeups: UInt64
    var idleWakeups: UInt64
    var timerWakeups: UInt64
    var footprintBytes: UInt64

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
            gpuNanoseconds: power.gpu_energy.task_gpu_utilisation,
            interruptWakeups: cpu.task_interrupt_wakeups,
            idleWakeups: cpu.task_platform_idle_wakeups,
            timerWakeups: cpu.task_timer_wakeups_bin_1 &+ cpu.task_timer_wakeups_bin_2,
            footprintBytes: UInt64(memory.phys_footprint)
        )
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
