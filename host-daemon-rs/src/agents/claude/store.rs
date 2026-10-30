use super::Projection;
use crate::agents::State;
use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};
use std::{
    fs::File,
    path::{Path, PathBuf},
};

pub(crate) fn state_path(home: &Path, root: &str) -> Result<PathBuf> {
    let uuid = crate::providers::claude::session_uuid_from_thread_id(root)
        .context("Invalid Claude parent")?;
    crate::providers::claude::timeline::session_file_name(uuid)?;
    Ok(home.join("remotecoder-agents").join(format!("{uuid}.json")))
}

pub(crate) fn load(home: &Path, root: &str) -> Result<Projection> {
    let path = state_path(home, root)?;
    if !path.exists() {
        return Ok(Projection::default());
    }
    Ok(read_saved(&path)?.projection)
}

#[derive(Default, Serialize, Deserialize)]
struct Saved {
    generation: u128,
    projection: Projection,
}

fn read_saved(path: &Path) -> Result<Saved> {
    if !path.exists() {
        return Ok(Saved::default());
    }
    let file = File::open(path)?;
    ensure!(
        file.metadata()?.len() <= 4 * 1024 * 1024,
        "Claude agent index exceeds limit"
    );
    serde_json::from_reader(file).context("Claude agent index is unreadable")
}

pub(crate) fn save(home: &Path, root: &str, generation: u128, snapshot: Projection) -> Result<()> {
    let path = state_path(home, root)?;
    std::fs::create_dir_all(path.parent().context("Missing index directory")?)?;
    let lock = crate::storage::lock_file::open(&path.with_extension("lock"))?;
    lock.lock()?;
    let mut current = read_saved(&path)?;
    if current.generation > generation {
        return Ok(());
    }
    if current.generation != generation {
        for child in current.projection.children.values_mut() {
            if child.state.is_running() {
                child.state = State::Unknown;
            }
        }
    }
    current.generation = generation;
    current.projection.overlay(snapshot);
    while serde_json::to_vec(&current)?.len() > 4 * 1024 * 1024 {
        let key = current
            .projection
            .children
            .iter()
            .find(|(_, child)| {
                matches!(
                    child.state,
                    State::Completed | State::Failed | State::Interrupted
                )
            })
            .or_else(|| current.projection.children.iter().next())
            .map(|(id, _)| id.clone())
            .context("Claude agent index cannot fit its storage bound")?;
        current.projection.children.remove(&key);
        current.projection.limited = true;
    }
    crate::storage::private_state::write_json(&path, &current)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agents::claude::tests::tool;

    #[test]
    fn persistence_fences_stale_runtime_and_preserves_prior_children() {
        let directory = tempfile::tempdir().unwrap();
        let root = "claude_11111111-1111-4111-8111-111111111111";
        let mut old = Projection::default();
        old.ingest(&tool("old", None));
        save(directory.path(), root, 1, old.clone()).unwrap();
        let mut new = Projection::default();
        new.ingest(&tool("new", None));
        save(directory.path(), root, 2, new).unwrap();
        old.stopped();
        save(directory.path(), root, 1, old).unwrap();
        let loaded = load(directory.path(), root).unwrap();
        assert_eq!(loaded.children["old"].state, State::Unknown);
        assert_eq!(loaded.children["new"].state, State::Working);
    }
}
