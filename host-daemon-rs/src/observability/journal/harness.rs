use std::path::{Path, PathBuf};

use serde_json::Value;

pub(super) fn temp_dir(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("rc-journal-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    dir
}

pub(super) async fn read_lines(path: &Path, expected: usize) -> Vec<Value> {
    for _ in 0..200 {
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        let content = std::fs::read_to_string(path).unwrap_or_default();
        let lines: Vec<&str> = content.lines().filter(|line| !line.is_empty()).collect();
        if lines.len() >= expected {
            return lines
                .into_iter()
                .map(|line| serde_json::from_str(line).expect("valid json"))
                .collect();
        }
    }
    panic!(
        "journal never reached {expected} lines at {}",
        path.display()
    );
}
