use std::ffi::{CStr, c_char, c_void};

type CFTypeRef = *const c_void;
const UTF8: u32 = 0x0800_0100;

#[link(name = "IOKit", kind = "framework")]
unsafe extern "C" {
    fn IOPSCopyPowerSourcesInfo() -> CFTypeRef;
    fn IOPSCopyPowerSourcesList(blob: CFTypeRef) -> CFTypeRef;
    fn IOPSGetPowerSourceDescription(blob: CFTypeRef, source: CFTypeRef) -> CFTypeRef;
}

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    static kCFBooleanFalse: CFTypeRef;
    fn CFRelease(object: CFTypeRef);
    fn CFEqual(first: CFTypeRef, second: CFTypeRef) -> u8;
    fn CFArrayGetCount(array: CFTypeRef) -> isize;
    fn CFArrayGetValueAtIndex(array: CFTypeRef, index: isize) -> CFTypeRef;
    fn CFDictionaryGetValue(dictionary: CFTypeRef, key: CFTypeRef) -> CFTypeRef;
    fn CFStringCreateWithCString(
        allocator: CFTypeRef,
        string: *const c_char,
        encoding: u32,
    ) -> CFTypeRef;
}

struct Owned(CFTypeRef);

impl Owned {
    fn adopt(object: CFTypeRef) -> Option<Self> {
        (!object.is_null()).then_some(Self(object))
    }

    fn string(value: &CStr) -> Option<Self> {
        Self::adopt(unsafe { CFStringCreateWithCString(std::ptr::null(), value.as_ptr(), UTF8) })
    }
}

impl Drop for Owned {
    fn drop(&mut self) {
        unsafe { CFRelease(self.0) }
    }
}

pub(crate) fn internal_battery() -> Option<bool> {
    let blob = Owned::adopt(unsafe { IOPSCopyPowerSourcesInfo() })?;
    let sources = Owned::adopt(unsafe { IOPSCopyPowerSourcesList(blob.0) })?;
    let type_key = Owned::string(c"Type")?;
    let internal_battery = Owned::string(c"InternalBattery")?;
    let present_key = Owned::string(c"Is Present")?;
    for index in 0..unsafe { CFArrayGetCount(sources.0) } {
        let source = unsafe { CFArrayGetValueAtIndex(sources.0, index) };
        let description = unsafe { IOPSGetPowerSourceDescription(blob.0, source) };
        if description.is_null() {
            return None;
        }
        let kind = unsafe { CFDictionaryGetValue(description, type_key.0) };
        if kind.is_null() || unsafe { CFEqual(kind, internal_battery.0) } == 0 {
            continue;
        }
        let present = unsafe { CFDictionaryGetValue(description, present_key.0) };
        if present.is_null() || unsafe { CFEqual(present, kCFBooleanFalse) } == 0 {
            return Some(true);
        }
    }
    Some(false)
}

#[cfg(test)]
mod tests {
    #[test]
    fn reads_the_power_source_list() {
        assert!(super::internal_battery().is_some());
    }
}
