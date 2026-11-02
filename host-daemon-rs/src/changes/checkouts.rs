use std::collections::{BTreeSet, HashMap};
use std::path::{Path, PathBuf};

use serde::Serialize;

const MAXIMUM_WORKED_IN: usize = 16;
const MAXIMUM_IN_FOLDER: usize = 64;

#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq, PartialOrd, Ord)]
#[serde(rename_all = "camelCase")]
pub(crate) enum Evidence {
    Edited,
    Command,
    WorkingFolder,
}

#[derive(Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Checkout {
    pub root: String,
    pub evidence: BTreeSet<Evidence>,
}

#[derive(Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Discovery {
    pub worked_in: Vec<Checkout>,
    pub in_folder: Vec<String>,
    pub complete: bool,
}

#[derive(Debug, Default, PartialEq, Eq)]
pub(crate) struct Observations(HashMap<PathBuf, (BTreeSet<Evidence>, Option<i64>)>);

impl Observations {
    pub(crate) fn record(&mut self, directory: PathBuf, evidence: Evidence, at_ms: Option<i64>) {
        let (kinds, latest) = self.0.entry(directory).or_default();
        kinds.insert(evidence);
        *latest = (*latest).max(at_ms);
    }
}

#[derive(Default)]
pub(crate) struct Roots(HashMap<PathBuf, Option<PathBuf>>);

impl Roots {
    pub(crate) fn of(&mut self, directory: &Path) -> Option<PathBuf> {
        let mut visited = Vec::new();
        let mut root = None;
        for ancestor in directory.ancestors() {
            if let Some(known) = self.0.get(ancestor) {
                root = known.clone();
                break;
            }
            visited.push(ancestor.to_path_buf());
            if std::fs::symlink_metadata(ancestor.join(".git")).is_ok() {
                root = Some(
                    std::fs::canonicalize(ancestor).unwrap_or_else(|_| ancestor.to_path_buf()),
                );
                break;
            }
        }
        for directory in visited {
            self.0.insert(directory, root.clone());
        }
        root
    }
}

pub(crate) fn discover(
    observations: Observations,
    working_folder: Option<&Path>,
    mut complete: bool,
) -> Discovery {
    let mut roots = Roots::default();
    let mut found: HashMap<PathBuf, (BTreeSet<Evidence>, Option<i64>)> = HashMap::new();
    for (directory, (kinds, latest)) in observations.0 {
        if !directory.is_dir() {
            continue;
        }
        if let Some(root) = roots.of(&directory) {
            let (evidence, observed) = found.entry(root).or_default();
            evidence.extend(kinds);
            *observed = (*observed).max(latest);
        }
    }
    let mut in_folder = Vec::new();
    if let Some(folder) = working_folder.filter(|folder| folder.is_dir()) {
        match roots.of(folder) {
            Some(root) => {
                found
                    .entry(root)
                    .or_default()
                    .0
                    .insert(Evidence::WorkingFolder);
            }
            None => match child_checkouts(folder, &found) {
                Some(children) => {
                    complete &= children.len() <= MAXIMUM_IN_FOLDER;
                    in_folder = children;
                    in_folder.truncate(MAXIMUM_IN_FOLDER);
                }
                None => complete = false,
            },
        }
    }
    let mut found: Vec<_> = found.into_iter().collect();
    found.sort_by(|(left, (_, left_seen)), (right, (_, right_seen))| {
        right_seen.cmp(left_seen).then_with(|| left.cmp(right))
    });
    complete &= found.len() <= MAXIMUM_WORKED_IN;
    let worked_in = found
        .into_iter()
        .take(MAXIMUM_WORKED_IN)
        .map(|(root, (evidence, _))| Checkout {
            root: root.to_string_lossy().into_owned(),
            evidence,
        })
        .collect();
    Discovery {
        worked_in,
        in_folder,
        complete,
    }
}

fn child_checkouts(
    folder: &Path,
    worked_in: &HashMap<PathBuf, (BTreeSet<Evidence>, Option<i64>)>,
) -> Option<Vec<String>> {
    let mut roots: Vec<String> = std::fs::read_dir(folder)
        .ok()?
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| std::fs::symlink_metadata(path.join(".git")).is_ok())
        .filter_map(|path| std::fs::canonicalize(path).ok())
        .filter(|root| !worked_in.contains_key(root))
        .map(|root| root.to_string_lossy().into_owned())
        .collect();
    roots.sort();
    Some(roots)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn repository(path: &Path) {
        std::fs::create_dir_all(path.join(".git")).unwrap();
    }

    #[test]
    fn finds_the_nearest_checkout_and_keeps_worktrees_separate() {
        let temporary = tempfile::tempdir().unwrap();
        let home = std::fs::canonicalize(temporary.path()).unwrap();
        let main = home.join("care.ai");
        let worktree = home.join("care.ai.worktrees/codeact");
        repository(&main);
        std::fs::create_dir_all(worktree.join("src")).unwrap();
        std::fs::write(
            worktree.join(".git"),
            "gitdir: ../../care.ai/.git/worktrees/codeact\n",
        )
        .unwrap();
        std::fs::create_dir_all(main.join("docs")).unwrap();
        let mut observations = Observations::default();
        observations.record(worktree.join("src"), Evidence::Edited, Some(20));
        observations.record(worktree.clone(), Evidence::Command, Some(30));
        observations.record(main.join("docs"), Evidence::Edited, Some(10));
        observations.record(home.join("gone/src"), Evidence::Edited, Some(40));
        observations.record(home.clone(), Evidence::Command, Some(50));

        let discovery = discover(observations, Some(&home), true);

        assert_eq!(
            discovery.worked_in,
            vec![
                Checkout {
                    root: worktree.to_string_lossy().into_owned(),
                    evidence: BTreeSet::from([Evidence::Edited, Evidence::Command]),
                },
                Checkout {
                    root: main.to_string_lossy().into_owned(),
                    evidence: BTreeSet::from([Evidence::Edited]),
                },
            ]
        );
        assert!(discovery.in_folder.is_empty());
        assert!(discovery.complete);
    }

    #[test]
    fn lists_unworked_checkouts_in_a_plain_working_folder() {
        let temporary = tempfile::tempdir().unwrap();
        let home = std::fs::canonicalize(temporary.path()).unwrap();
        for name in ["kartan", "care", "notes"] {
            std::fs::create_dir_all(home.join(name)).unwrap();
        }
        repository(&home.join("kartan"));
        repository(&home.join("care"));
        let mut observations = Observations::default();
        observations.record(home.join("care"), Evidence::Edited, None);

        let discovery = discover(observations, Some(&home), true);

        assert_eq!(discovery.worked_in.len(), 1);
        assert_eq!(
            discovery.in_folder,
            vec![home.join("kartan").to_string_lossy().into_owned()]
        );
    }

    #[test]
    fn discovery_serializes_like_the_shared_fixture() {
        let discovery = Discovery {
            worked_in: vec![
                Checkout {
                    root: "/Users/agent/stretch/care.ai.worktrees/codeact".into(),
                    evidence: BTreeSet::from([Evidence::Command, Evidence::Edited]),
                },
                Checkout {
                    root: "/Users/agent/stretch/care.ai".into(),
                    evidence: BTreeSet::from([Evidence::Command]),
                },
            ],
            in_folder: vec!["/Users/agent/stretch/kartan".into()],
            complete: true,
        };
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../../protocol-fixtures/changes/checkouts.json"
        ))
        .unwrap();
        assert_eq!(serde_json::to_value(discovery).unwrap(), fixture);
    }

    #[test]
    fn a_working_folder_inside_a_checkout_counts_as_worked_in() {
        let temporary = tempfile::tempdir().unwrap();
        let root = std::fs::canonicalize(temporary.path()).unwrap();
        repository(&root);
        std::fs::create_dir_all(root.join("app")).unwrap();

        let discovery = discover(Observations::default(), Some(&root.join("app")), true);

        assert_eq!(discovery.worked_in.len(), 1);
        assert_eq!(
            discovery.worked_in[0].evidence,
            BTreeSet::from([Evidence::WorkingFolder])
        );
    }
}
