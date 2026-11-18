#[cfg(target_os = "macos")]
pub(crate) fn internal_battery() -> Option<bool> {
    super::macos::power_sources::internal_battery()
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
}
