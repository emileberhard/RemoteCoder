use std::collections::HashMap;
use std::fmt::Write as _;
use std::path::{Path, PathBuf};

use anyhow::Result;
use serde::Serialize;
use serde_json::Value;
use tokio::process::Command;

use super::checkouts::Roots;
use super::patch::{Budgets, ChangedFile, PatchSplitter};
use super::{Admission, BUDGETS, collect};

const MAXIMUM_RECONSTRUCTED_BYTES: u64 = 8 * 1024 * 1024;
const MAXIMUM_NET_DIFF_BYTES: usize = 32 * 1024 * 1024;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Edit {
    pub path: String,
    pub change: Option<Change>,
}

impl Edit {
    pub(crate) fn recorded_bytes(&self) -> usize {
        self.path.len()
            + match &self.change {
                Some(Change::Add(content) | Change::Delete(content)) => content.len(),
                Some(Change::Update { hunks, moved_to }) => {
                    hunks.len() + moved_to.as_ref().map_or(0, String::len)
                }
                None => 0,
            }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Change {
    Add(String),
    Delete(String),
    Update {
        hunks: String,
        moved_to: Option<String>,
    },
}

#[derive(Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct TurnFile {
    pub root: String,
    #[serde(flatten)]
    pub file: ChangedFile,
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct TurnFiles {
    pub files: Vec<TurnFile>,
    pub unlisted_files: u64,
}

pub(crate) fn recorded_edits(item: &Value) -> Vec<Edit> {
    if item["type"] != "fileChange" || item["status"] != "completed" {
        return Vec::new();
    }
    item["changes"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|change| {
            let path = change["path"]
                .as_str()
                .filter(|path| path.starts_with('/'))?;
            let diff = change["diff"].as_str().map(str::to_owned);
            let kind = &change["kind"];
            let change = match kind["type"].as_str()? {
                "add" => diff.map(Change::Add),
                "delete" => diff.map(Change::Delete),
                "update" => {
                    let moved_to = kind["movePath"]
                        .as_str()
                        .or_else(|| kind["move_path"].as_str());
                    diff.map(|mut hunks| {
                        if let Some(target) = moved_to
                            && let Some(kept) = hunks
                                .strip_suffix(&format!("\n\nMoved to: {target}"))
                                .map(str::len)
                        {
                            hunks.truncate(kept);
                        }
                        Change::Update {
                            hunks,
                            moved_to: moved_to.map(str::to_owned),
                        }
                    })
                }
                _ => return None,
            };
            Some(Edit {
                path: path.to_owned(),
                change,
            })
        })
        .collect()
}

struct TouchedFile {
    path: String,
    relative: String,
    changes: Option<Vec<Change>>,
}

pub(crate) async fn turn_files(edits: Vec<Edit>, admission: &Admission) -> Result<TurnFiles> {
    let groups = admission.blocking(move || grouped(edits)).await?;
    let mut turn = TurnFiles {
        files: Vec::new(),
        unlisted_files: 0,
    };
    let mut used_bytes = 0;
    for (root, files) in groups {
        let mut splitter = PatchSplitter::new(Budgets {
            file_patch_bytes: BUDGETS.file_patch_bytes,
            hunk_bytes: BUDGETS.hunk_bytes.saturating_sub(used_bytes),
            response_bytes: BUDGETS.response_bytes.saturating_sub(used_bytes),
            files: BUDGETS.files.saturating_sub(turn.files.len()),
        });
        for file in &files {
            let Some(changes) = &file.changes else {
                turn.unlisted_files += 1;
                continue;
            };
            for patch in patches_of(&root, file, changes).await {
                splitter.push(patch.as_bytes());
            }
        }
        let split = splitter.finish();
        turn.unlisted_files += split.unlisted_files;
        for file in split.files {
            used_bytes += file.patch.len();
            turn.files.push(TurnFile {
                root: root.clone(),
                file,
            });
        }
    }
    Ok(turn)
}

fn grouped(edits: Vec<Edit>) -> Vec<(String, Vec<TouchedFile>)> {
    let mut roots = Roots::default();
    let mut groups: Vec<(String, Vec<TouchedFile>)> = Vec::new();
    let mut positions: HashMap<String, (usize, usize)> = HashMap::new();
    for Edit { path, change } in edits {
        if let Some(&(group, file)) = positions.get(&path) {
            let touched = &mut groups[group].1[file];
            match (&mut touched.changes, change) {
                (Some(changes), Some(change)) => changes.push(change),
                _ => touched.changes = None,
            }
            continue;
        }
        let (root, relative) = locate(&mut roots, Path::new(&path));
        let group = groups
            .iter()
            .position(|(known, _)| *known == root)
            .unwrap_or_else(|| {
                groups.push((root, Vec::new()));
                groups.len() - 1
            });
        positions.insert(path.clone(), (group, groups[group].1.len()));
        groups[group].1.push(TouchedFile {
            path,
            relative,
            changes: change.map(|change| vec![change]),
        });
    }
    groups
}

fn locate(roots: &mut Roots, path: &Path) -> (String, String) {
    let name = path
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_default();
    let folder = path.parent().unwrap_or(Path::new("/"));
    let folder = std::fs::canonicalize(folder).unwrap_or_else(|_| folder.to_path_buf());
    if let Some(root) = roots.of(&folder)
        && let Ok(relative) = folder.join(&name).strip_prefix(&root)
    {
        return (
            root.to_string_lossy().into_owned(),
            relative.to_string_lossy().into_owned(),
        );
    }
    (folder.to_string_lossy().into_owned(), name)
}

async fn patches_of(root: &str, file: &TouchedFile, changes: &[Change]) -> Vec<String> {
    let recorded = || -> Vec<String> {
        changes
            .iter()
            .map(|change| recorded_patch(root, &file.relative, change))
            .collect()
    };
    let moved = changes.iter().any(|change| {
        matches!(
            change,
            Change::Update {
                moved_to: Some(_),
                ..
            }
        )
    });
    if changes.len() == 1 || moved {
        return recorded();
    }
    let Some((before, after)) = reconstruct(Path::new(&file.path), changes).await else {
        return recorded();
    };
    if before == after {
        return Vec::new();
    }
    match net_patch(&file.relative, before.as_deref(), after.as_deref()).await {
        Some(patch) => vec![patch],
        None => recorded(),
    }
}

fn recorded_patch(root: &str, relative: &str, change: &Change) -> String {
    match change {
        Change::Add(content) => header(None, Some(relative)) + &whole(content, '+'),
        Change::Delete(content) => header(Some(relative), None) + &whole(content, '-'),
        Change::Update { hunks, moved_to } => {
            let target = moved_to.as_deref().map(|target| {
                Path::new(target).strip_prefix(root).map_or_else(
                    |_| target.to_owned(),
                    |inside| inside.to_string_lossy().into_owned(),
                )
            });
            let mut patch = header(Some(relative), Some(target.as_deref().unwrap_or(relative)));
            patch.push_str(hunks);
            if !hunks.is_empty() && !hunks.ends_with('\n') {
                patch.push('\n');
            }
            patch
        }
    }
}

fn header(old: Option<&str>, new: Option<&str>) -> String {
    let a = old.or(new).unwrap_or_default();
    let b = new.or(old).unwrap_or_default();
    let mut text = format!("diff --git {} {}\n", quoted("a/", a), quoted("b/", b));
    match (old, new) {
        (None, Some(_)) => text.push_str("new file mode 100644\n"),
        (Some(_), None) => text.push_str("deleted file mode 100644\n"),
        (Some(old), Some(new)) if old != new => {
            let _ = writeln!(text, "rename from {}", quoted("", old));
            let _ = writeln!(text, "rename to {}", quoted("", new));
        }
        _ => {}
    }
    let _ = writeln!(
        text,
        "--- {}",
        old.map_or("/dev/null".into(), |old| quoted("a/", old))
    );
    let _ = writeln!(
        text,
        "+++ {}",
        new.map_or("/dev/null".into(), |new| quoted("b/", new))
    );
    text
}

fn quoted(prefix: &str, path: &str) -> String {
    if !path
        .chars()
        .any(|character| character.is_ascii_control() || matches!(character, '"' | '\\'))
    {
        return format!("{prefix}{path}");
    }
    let mut text = String::from("\"");
    for character in prefix.chars().chain(path.chars()) {
        match character {
            '\x07' => text.push_str("\\a"),
            '\x08' => text.push_str("\\b"),
            '\t' => text.push_str("\\t"),
            '\n' => text.push_str("\\n"),
            '\x0b' => text.push_str("\\v"),
            '\x0c' => text.push_str("\\f"),
            '\r' => text.push_str("\\r"),
            '"' => text.push_str("\\\""),
            '\\' => text.push_str("\\\\"),
            character if character.is_ascii_control() => {
                let _ = write!(text, "\\{:03o}", character as u32);
            }
            character => text.push(character),
        }
    }
    text.push('"');
    text
}

fn whole(content: &str, sign: char) -> String {
    let lines: Vec<&str> = content.split_inclusive('\n').collect();
    if lines.is_empty() {
        return String::new();
    }
    let range = match lines.len() {
        1 => "1".to_string(),
        count => format!("1,{count}"),
    };
    let mut text = match sign {
        '+' => format!("@@ -0,0 +{range} @@\n"),
        _ => format!("@@ -{range} +0,0 @@\n"),
    };
    for line in lines {
        text.push(sign);
        text.push_str(line);
        if !line.ends_with('\n') {
            text.push_str("\n\\ No newline at end of file\n");
        }
    }
    text
}

async fn reconstruct(path: &Path, changes: &[Change]) -> Option<(Option<String>, Option<String>)> {
    let after = match tokio::fs::metadata(path).await {
        Ok(metadata) if metadata.is_file() && metadata.len() <= MAXIMUM_RECONSTRUCTED_BYTES => {
            Some(String::from_utf8(tokio::fs::read(path).await.ok()?).ok()?)
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
        _ => return None,
    };
    let mut state = after.clone();
    for change in changes.iter().rev() {
        state = match change {
            Change::Add(content) => {
                if state.as_deref() != Some(content.as_str()) {
                    return None;
                }
                None
            }
            Change::Delete(content) => {
                if state.is_some() {
                    return None;
                }
                Some(content.clone())
            }
            Change::Update { hunks, .. } => Some(reverse(state.as_deref()?, hunks)?),
        };
    }
    Some((state, after))
}

struct Hunk {
    old_count: usize,
    new_start: usize,
    new_count: usize,
    old: Vec<String>,
    new: Vec<String>,
}

fn hunks(diff: &str) -> Option<Vec<Hunk>> {
    let mut hunks: Vec<Hunk> = Vec::new();
    let mut previous = b' ';
    for line in diff.strip_suffix('\n').unwrap_or(diff).split('\n') {
        if let Some(rest) = line.strip_prefix("@@ -") {
            let (old_range, rest) = rest.split_once(" +")?;
            let (new_range, _) = rest.split_once(" @@")?;
            let (_, old_count) = range(old_range)?;
            let (new_start, new_count) = range(new_range)?;
            hunks.push(Hunk {
                old_count,
                new_start,
                new_count,
                old: Vec::new(),
                new: Vec::new(),
            });
            continue;
        }
        let hunk = hunks.last_mut()?;
        let kind = line.as_bytes().first().copied().unwrap_or(b' ');
        let text = line.get(1..).unwrap_or_default();
        match kind {
            b' ' => {
                hunk.old.push(format!("{text}\n"));
                hunk.new.push(format!("{text}\n"));
            }
            b'-' => hunk.old.push(format!("{text}\n")),
            b'+' => hunk.new.push(format!("{text}\n")),
            b'\\' => {
                if matches!(previous, b' ' | b'-') {
                    hunk.old.last_mut()?.pop();
                }
                if matches!(previous, b' ' | b'+') {
                    hunk.new.last_mut()?.pop();
                }
            }
            _ => return None,
        }
        previous = kind;
    }
    hunks
        .iter()
        .all(|hunk| hunk.old.len() == hunk.old_count && hunk.new.len() == hunk.new_count)
        .then_some(hunks)
}

fn range(text: &str) -> Option<(usize, usize)> {
    match text.split_once(',') {
        Some((start, count)) => Some((start.parse().ok()?, count.parse().ok()?)),
        None => Some((text.parse().ok()?, 1)),
    }
}

fn reverse(text: &str, diff: &str) -> Option<String> {
    let hunks = hunks(diff)?;
    let mut lines: Vec<&str> = text.split_inclusive('\n').collect();
    for hunk in hunks.iter().rev() {
        let start = match hunk.new_count {
            0 => hunk.new_start,
            _ => hunk.new_start.checked_sub(1)?,
        };
        let current = lines.get(start..start + hunk.new_count)?;
        if !current
            .iter()
            .copied()
            .eq(hunk.new.iter().map(String::as_str))
        {
            return None;
        }
        lines.splice(
            start..start + hunk.new_count,
            hunk.old.iter().map(String::as_str),
        );
    }
    Some(lines.concat())
}

async fn net_patch(relative: &str, before: Option<&str>, after: Option<&str>) -> Option<String> {
    let directory = tempfile::tempdir().ok()?;
    let mut sides = Vec::with_capacity(2);
    for (name, content) in [("before", before), ("after", after)] {
        sides.push(match content {
            Some(content) => {
                let path = directory.path().join(name);
                tokio::fs::write(&path, content).await.ok()?;
                path
            }
            None => PathBuf::from("/dev/null"),
        });
    }
    let mut command = Command::new("git");
    command
        .current_dir(directory.path())
        .args([
            "diff",
            "--no-index",
            "--no-color",
            "--no-ext-diff",
            "--no-textconv",
            "--unified=3",
            "--",
        ])
        .args(&sides)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("LC_ALL", "C")
        .kill_on_drop(true);
    let output = collect(command, &[], MAXIMUM_NET_DIFF_BYTES).await.ok()?;
    if !output.complete || !matches!(output.status.code(), Some(0 | 1)) {
        return None;
    }
    let text = String::from_utf8(output.stdout).ok()?;
    let body = &text[text.find("\n@@")? + 1..];
    Some(header(before.map(|_| relative), after.map(|_| relative)) + body)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::changes::ChangeReader;
    use serde_json::json;

    fn update(hunks: &str) -> Option<Change> {
        Some(Change::Update {
            hunks: hunks.into(),
            moved_to: None,
        })
    }

    async fn files_of(edits: Vec<Edit>) -> TurnFiles {
        ChangeReader::default()
            .admit(|admission| async move { turn_files(edits, &admission).await })
            .await
            .unwrap()
    }

    #[test]
    fn reads_both_providers_move_spellings_and_skips_unapplied_edits() {
        let item = json!({"type":"fileChange","status":"completed","changes":[
            {"path":"/r/a.rs","kind":{"type":"update","move_path":"/r/b.rs"},"diff":"@@ -1 +1 @@\n-a\n+b\n\n\nMoved to: /r/b.rs"},
            {"path":"/r/c.rs","kind":{"type":"update","movePath":null},"diff":""},
            {"path":"/r/notebook.ipynb","kind":{"type":"update","movePath":null},"diff":null},
            {"path":"relative.rs","kind":{"type":"add"},"diff":"x\n"}
        ]});
        assert_eq!(
            recorded_edits(&item),
            vec![
                Edit {
                    path: "/r/a.rs".into(),
                    change: Some(Change::Update {
                        hunks: "@@ -1 +1 @@\n-a\n+b\n".into(),
                        moved_to: Some("/r/b.rs".into())
                    })
                },
                Edit {
                    path: "/r/c.rs".into(),
                    change: update("")
                },
                Edit {
                    path: "/r/notebook.ipynb".into(),
                    change: None
                },
            ]
        );
        let running = json!({"type":"fileChange","status":"inProgress","changes":[
            {"path":"/r/a.rs","kind":{"type":"add"},"diff":"x\n"}
        ]});
        assert!(recorded_edits(&running).is_empty());
    }

    #[test]
    fn reverses_edits_including_insertions_deletions_and_missing_final_newlines() {
        let edits = "@@ -1,2 +1,2 @@\n one\n-two\n+TWO\n@@ -3,2 +3,2 @@\n three\n-4\n\\ No newline at end of file\n+four\n\\ No newline at end of file\n";
        assert_eq!(
            reverse("one\nTWO\nthree\nfour", edits).as_deref(),
            Some("one\ntwo\nthree\n4")
        );
        assert_eq!(
            reverse("a\nc\n", "@@ -1,2 +1 @@\n a\n-b\n").as_deref(),
            Some("a\nb\nc\n")
        );
        assert_eq!(
            reverse("a\nb\n", "@@ -1,0 +2 @@\n+b\n").as_deref(),
            Some("a\n")
        );
        assert_eq!(
            reverse("", "@@ -1,2 +0,0 @@\n-a\n-b\n").as_deref(),
            Some("a\nb\n")
        );
    }

    #[test]
    fn reversing_refuses_edits_the_file_no_longer_shows() {
        assert_eq!(reverse("a\nX\n", "@@ -1,2 +1,2 @@\n a\n-b\n+c\n"), None);
        assert_eq!(reverse("a\n", "@@ -5 +5 @@\n-b\n+c\n"), None);
        assert_eq!(
            reverse("a\n", "@@ -1 +1 @@\n-b\n"),
            None,
            "counts disagree with the hunk body"
        );
    }

    #[tokio::test]
    async fn several_edits_to_one_file_become_one_net_diff_inside_its_checkout() {
        let temporary = tempfile::tempdir().unwrap();
        let root = std::fs::canonicalize(temporary.path()).unwrap();
        std::fs::create_dir_all(root.join(".git")).unwrap();
        std::fs::create_dir_all(root.join("src")).unwrap();
        let file = root.join("src/app.rs");
        std::fs::write(&file, "let a = 1;\nlet b = 3;\nlet c = 4;\n").unwrap();
        let path = file.to_string_lossy().into_owned();
        let edits = vec![
            Edit {
                path: path.clone(),
                change: update("@@ -1,2 +1,2 @@\n let a = 1;\n-let b = 2;\n+let b = 3;\n"),
            },
            Edit {
                path: path.clone(),
                change: update("@@ -2 +2,2 @@\n let b = 3;\n+let c = 4;\n"),
            },
            Edit {
                path: "/nonexistent-folder/notes.md".into(),
                change: Some(Change::Add("# Notes".into())),
            },
            Edit {
                path: "/nonexistent-folder/notebook.ipynb".into(),
                change: None,
            },
        ];

        let turn = files_of(edits).await;

        assert_eq!(
            turn.unlisted_files, 1,
            "the notebook edit recorded no content"
        );
        assert_eq!(turn.files.len(), 2);
        assert_eq!(turn.files[0].root, root.to_string_lossy());
        assert_eq!(
            turn.files[0].file.patch,
            "diff --git a/src/app.rs b/src/app.rs\n--- a/src/app.rs\n+++ b/src/app.rs\n@@ -1,2 +1,3 @@\n let a = 1;\n-let b = 2;\n+let b = 3;\n+let c = 4;\n"
        );
        assert_eq!(
            (turn.files[0].file.additions, turn.files[0].file.deletions),
            (2, 1)
        );
        assert_eq!(turn.files[1].root, "/nonexistent-folder");
        assert_eq!(
            turn.files[1].file.patch,
            "diff --git a/notes.md b/notes.md\nnew file mode 100644\n--- /dev/null\n+++ b/notes.md\n@@ -0,0 +1 @@\n+# Notes\n\\ No newline at end of file\n"
        );
    }

    #[tokio::test]
    async fn edits_that_no_longer_match_the_file_are_shown_one_by_one() {
        let temporary = tempfile::tempdir().unwrap();
        let file = temporary.path().join("a.txt");
        std::fs::write(&file, "changed by someone else\n").unwrap();
        let path = file.to_string_lossy().into_owned();
        let first = update("@@ -1 +1 @@\n-x\n+y\n");
        let second = update("@@ -1 +1 @@\n-y\n+z\n");

        let turn = files_of(vec![
            Edit {
                path: path.clone(),
                change: first,
            },
            Edit {
                path,
                change: second,
            },
        ])
        .await;

        assert_eq!(turn.files.len(), 2);
        assert!(turn.files[0].file.patch.ends_with("-x\n+y\n"));
        assert!(turn.files[1].file.patch.ends_with("-y\n+z\n"));
    }

    #[test]
    fn quotes_paths_like_git() {
        assert_eq!(quoted("a/", "dir/file name.rs"), "a/dir/file name.rs");
        assert_eq!(quoted("b/", "tab\there\"q"), "\"b/tab\\there\\\"q\"");
        assert_eq!(
            quoted("a/", "dokument/återbesök\u{1}.md"),
            "\"a/dokument/återbesök\\001.md\""
        );
    }
}
