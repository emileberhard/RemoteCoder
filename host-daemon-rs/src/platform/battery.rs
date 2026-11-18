#[cfg(target_os = "macos")]
pub(crate) fn internal_battery() -> Option<bool> {
    macos::internal_battery()
}

#[cfg(target_os = "linux")]
pub(crate) fn internal_battery() -> Option<bool> {
    system_battery_in(std::path::Path::new("/sys/class/power_supply"))
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
pub(crate) fn internal_battery() -> Option<bool> {
    None
}

#[cfg(any(target_os = "linux", test))]
fn system_battery_in(root: &std::path::Path) -> Option<bool> {
    use std::io::ErrorKind;
    let attribute = |supply: &std::path::Path, name: &str| -> Result<Option<String>, ()> {
        match std::fs::read_to_string(supply.join(name)) {
            Ok(value) => Ok(Some(value.trim().to_owned())),
            Err(error) if error.kind() == ErrorKind::NotFound => Ok(None),
            Err(_) => Err(()),
        }
    };
    for entry in std::fs::read_dir(root).ok()? {
        let supply = entry.ok()?.path();
        if attribute(&supply, "type").ok()?.as_deref() != Some("Battery") {
            continue;
        }
        if attribute(&supply, "scope").ok()?.as_deref() == Some("Device") {
            continue;
        }
        if attribute(&supply, "present").ok()?.as_deref() == Some("0") {
            continue;
        }
        return Some(true);
    }
    Some(false)
}

#[cfg(target_os = "macos")]
mod macos {
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
            Self::adopt(unsafe {
                CFStringCreateWithCString(std::ptr::null(), value.as_ptr(), UTF8)
            })
        }
    }

    impl Drop for Owned {
        fn drop(&mut self) {
            unsafe { CFRelease(self.0) }
        }
    }

    pub(super) fn internal_battery() -> Option<bool> {
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
}

#[cfg(test)]
mod tests {
    use super::system_battery_in;

    fn supply(root: &std::path::Path, name: &str, attributes: &[(&str, &str)]) {
        let path = root.join(name);
        std::fs::create_dir(&path).unwrap();
        for (attribute, value) in attributes {
            std::fs::write(path.join(attribute), format!("{value}\n")).unwrap();
        }
    }

    #[test]
    fn linux_counts_only_present_system_batteries() {
        let root = tempfile::tempdir().unwrap();
        assert_eq!(system_battery_in(root.path()), Some(false));

        supply(root.path(), "AC", &[("type", "Mains")]);
        supply(
            root.path(),
            "hid-mouse-battery",
            &[("type", "Battery"), ("scope", "Device")],
        );
        supply(
            root.path(),
            "BAT1",
            &[("type", "Battery"), ("present", "0")],
        );
        assert_eq!(system_battery_in(root.path()), Some(false));

        supply(root.path(), "BAT0", &[("type", "Battery")]);
        assert_eq!(system_battery_in(root.path()), Some(true));
    }

    #[test]
    fn linux_reports_a_system_scoped_battery() {
        let root = tempfile::tempdir().unwrap();
        supply(
            root.path(),
            "BAT0",
            &[("type", "Battery"), ("scope", "System"), ("present", "1")],
        );
        assert_eq!(system_battery_in(root.path()), Some(true));
    }

    #[test]
    fn linux_unreadable_power_supplies_stay_unknown() {
        let root = tempfile::tempdir().unwrap();
        assert_eq!(system_battery_in(&root.path().join("missing")), None);
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn macos_reads_the_power_source_list() {
        assert!(super::internal_battery().is_some());
    }
}
