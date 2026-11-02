use serde::Serialize;

#[derive(Debug, Clone, Copy)]
pub(crate) struct Budgets {
    pub file_patch_bytes: usize,
    pub hunk_bytes: usize,
    pub response_bytes: usize,
    pub files: usize,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ChangedFile {
    pub patch: String,
    pub additions: u64,
    pub deletions: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub omitted: Option<Omission>,
    pub replaced_invalid_utf8: bool,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Omission {
    pub reason: OmissionReason,
    pub patch_bytes: u64,
}

#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) enum OmissionReason {
    FileTooLarge,
    ResponseBudget,
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct SplitPatch {
    pub files: Vec<ChangedFile>,
    pub unlisted_files: u64,
}

pub(crate) struct PatchSplitter {
    budgets: Budgets,
    files: Vec<ChangedFile>,
    unlisted_files: u64,
    response_bytes: usize,
    section: Option<Section>,
    line_start: Vec<u8>,
    line_target: Option<LineTarget>,
}

const BOUNDARY_PREFIXES: [&[u8]; 4] = [
    b"diff --git ",
    b"diff --cc ",
    b"diff --combined ",
    b"* Unmerged path ",
];
const CLASSIFIED_PREFIX_BYTES: usize = 16;

struct Section {
    header: Vec<u8>,
    hunks: Vec<u8>,
    hunk_bytes: u64,
    in_hunks: bool,
    parents: usize,
    additions: u64,
    deletions: u64,
    omitted: Option<OmissionReason>,
    listed: bool,
}

#[derive(Clone, Copy)]
enum LineTarget {
    Header,
    Hunks,
    Discard,
}

impl PatchSplitter {
    pub(crate) fn new(budgets: Budgets) -> Self {
        Self {
            budgets,
            files: Vec::new(),
            unlisted_files: 0,
            response_bytes: 0,
            section: None,
            line_start: Vec::with_capacity(CLASSIFIED_PREFIX_BYTES),
            line_target: None,
        }
    }

    pub(crate) fn push(&mut self, mut bytes: &[u8]) {
        while !bytes.is_empty() {
            let line_end = bytes.iter().position(|byte| *byte == b'\n');
            let (chunk, rest) = match line_end {
                Some(index) => bytes.split_at(index + 1),
                None => (bytes, &[][..]),
            };
            self.consume(chunk, line_end.is_some());
            bytes = rest;
        }
    }

    pub(crate) fn finish(mut self) -> SplitPatch {
        if self.line_target.is_none() && !self.line_start.is_empty() {
            self.classify();
        }
        self.close_section();
        SplitPatch {
            files: self.files,
            unlisted_files: self.unlisted_files,
        }
    }

    fn consume(&mut self, chunk: &[u8], ends_line: bool) {
        let mut chunk = chunk;
        if self.line_target.is_none() {
            let wanted = CLASSIFIED_PREFIX_BYTES - self.line_start.len();
            let taken = wanted.min(chunk.len());
            self.line_start.extend_from_slice(&chunk[..taken]);
            chunk = &chunk[taken..];
            if self.line_start.len() < CLASSIFIED_PREFIX_BYTES && !ends_line {
                return;
            }
            self.classify();
        }
        self.write(chunk);
        if ends_line {
            self.line_target = None;
        }
    }

    fn classify(&mut self) {
        let start = std::mem::take(&mut self.line_start);
        if BOUNDARY_PREFIXES
            .iter()
            .any(|prefix| start.starts_with(prefix))
        {
            self.close_section();
            self.open_section();
        }
        let target = match self.section.as_mut() {
            None => LineTarget::Discard,
            Some(section) if !section.listed => LineTarget::Discard,
            Some(section) if start.starts_with(b"@@") => {
                section.in_hunks = true;
                section.parents = start.iter().take_while(|byte| **byte == b'@').count() - 1;
                LineTarget::Hunks
            }
            Some(section) if section.in_hunks => {
                section.count(&start);
                LineTarget::Hunks
            }
            Some(_) => LineTarget::Header,
        };
        self.line_target = Some(target);
        self.write(&start);
        self.line_start = start;
        self.line_start.clear();
    }

    fn write(&mut self, bytes: &[u8]) {
        if bytes.is_empty() {
            return;
        }
        let Some(section) = self.section.as_mut() else {
            return;
        };
        if !section.listed {
            return;
        }
        match self.line_target {
            Some(LineTarget::Header) => {
                if self.response_bytes + bytes.len() > self.budgets.response_bytes {
                    self.response_bytes -= section.header.len() + section.hunks.len();
                    section.listed = false;
                    self.unlisted_files += 1;
                    return;
                }
                section.header.extend_from_slice(bytes);
                self.response_bytes += bytes.len();
            }
            Some(LineTarget::Hunks) => {
                section.hunk_bytes += bytes.len() as u64;
                if section.omitted.is_some() {
                    return;
                }
                let file_bytes = section.header.len() + section.hunks.len() + bytes.len();
                if file_bytes > self.budgets.file_patch_bytes {
                    section.omit(OmissionReason::FileTooLarge, &mut self.response_bytes);
                } else if self.response_bytes + bytes.len() > self.budgets.hunk_bytes {
                    section.omit(OmissionReason::ResponseBudget, &mut self.response_bytes);
                } else {
                    section.hunks.extend_from_slice(bytes);
                    self.response_bytes += bytes.len();
                }
            }
            Some(LineTarget::Discard) | None => {}
        }
    }

    fn open_section(&mut self) {
        let listed = self.files.len() < self.budgets.files;
        if !listed {
            self.unlisted_files += 1;
        }
        self.section = Some(Section {
            header: Vec::new(),
            hunks: Vec::new(),
            hunk_bytes: 0,
            in_hunks: false,
            parents: 1,
            additions: 0,
            deletions: 0,
            omitted: None,
            listed,
        });
    }

    fn close_section(&mut self) {
        let Some(section) = self.section.take() else {
            return;
        };
        if !section.listed {
            return;
        }
        let raw_bytes = section.header.len() + section.hunks.len();
        let (header, header_replaced) = text(section.header);
        let (mut hunks, hunks_replaced) = text(section.hunks);
        let mut omitted = section.omitted;
        if header.len() + hunks.len() > raw_bytes {
            self.response_bytes += header.len() + hunks.len() - raw_bytes;
            let reason = if header.len() + hunks.len() > self.budgets.file_patch_bytes {
                Some(OmissionReason::FileTooLarge)
            } else if self.response_bytes > self.budgets.hunk_bytes {
                Some(OmissionReason::ResponseBudget)
            } else {
                None
            };
            if let Some(reason) = reason.filter(|_| !hunks.is_empty()) {
                self.response_bytes -= hunks.len();
                hunks.clear();
                omitted = Some(reason);
            }
            if self.response_bytes > self.budgets.response_bytes {
                self.response_bytes -= header.len() + hunks.len();
                self.unlisted_files += 1;
                return;
            }
        }
        self.files.push(ChangedFile {
            replaced_invalid_utf8: header_replaced || (hunks_replaced && !hunks.is_empty()),
            patch: header + &hunks,
            additions: section.additions,
            deletions: section.deletions,
            omitted: omitted.map(|reason| Omission {
                reason,
                patch_bytes: section.hunk_bytes,
            }),
        });
    }
}

fn text(bytes: Vec<u8>) -> (String, bool) {
    match String::from_utf8(bytes) {
        Ok(text) => (text, false),
        Err(error) => (String::from_utf8_lossy(error.as_bytes()).into_owned(), true),
    }
}

impl Section {
    fn count(&mut self, start: &[u8]) {
        let Some(columns) = start.get(..self.parents) else {
            return;
        };
        if !columns.iter().all(|column| b" +-".contains(column)) {
            return;
        }
        if columns.contains(&b'-') {
            self.deletions += 1;
        } else if columns.contains(&b'+') {
            self.additions += 1;
        }
    }

    fn omit(&mut self, reason: OmissionReason, response_bytes: &mut usize) {
        *response_bytes -= self.hunks.len();
        self.hunks = Vec::new();
        self.omitted = Some(reason);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const GENEROUS: Budgets = Budgets {
        file_patch_bytes: 1 << 20,
        hunk_bytes: 1 << 20,
        response_bytes: 1 << 20,
        files: 100,
    };

    fn split(patch: &str, budgets: Budgets, chunk: usize) -> SplitPatch {
        let mut splitter = PatchSplitter::new(budgets);
        for piece in patch.as_bytes().chunks(chunk) {
            splitter.push(piece);
        }
        splitter.finish()
    }

    const TWO_FILES: &str = "\
diff --git a/a.txt b/a.txt
index 4cb29ea..6addb9b 100644
--- a/a.txt
+++ b/a.txt
@@ -1,3 +1,4 @@
 one
-two
+TWO
 three
+--- not a header
diff --git a/bin.dat b/bin.dat
index 88768ef..f68ed80 100644
Binary files a/bin.dat and b/bin.dat differ
";

    #[test]
    fn sections_split_at_file_boundaries_and_count_only_hunk_lines() {
        for chunk in [1, 3, 16, 17, 4096] {
            let result = split(TWO_FILES, GENEROUS, chunk);
            assert_eq!(result.unlisted_files, 0);
            assert_eq!(result.files.len(), 2, "chunk {chunk}");
            let first = &result.files[0];
            assert!(first.patch.starts_with("diff --git a/a.txt b/a.txt\n"));
            assert!(first.patch.ends_with("+--- not a header\n"));
            assert_eq!((first.additions, first.deletions), (2, 1), "chunk {chunk}");
            let second = &result.files[1];
            assert!(second.patch.starts_with("diff --git a/bin.dat"));
            assert_eq!((second.additions, second.deletions), (0, 0));
            assert_eq!(second.omitted, None);
        }
    }

    #[test]
    fn unmerged_paths_are_their_own_files() {
        let result = split(
            &format!("* Unmerged path sp ace.txt\n{TWO_FILES}"),
            GENEROUS,
            3,
        );
        assert_eq!(result.files.len(), 3);
        assert_eq!(result.files[0].patch, "* Unmerged path sp ace.txt\n");
        assert_eq!(
            (result.files[1].additions, result.files[1].deletions),
            (2, 1)
        );
    }

    #[test]
    fn combined_lines_count_like_the_app_parses_them() {
        let result = split(
            "diff --cc c.txt\n--- a/c.txt\n+++ b/c.txt\n@@@ -1,1 -1,1 +1,3 @@@\n++<<<<<<< ours\n +kept\n- gone\n",
            GENEROUS,
            2,
        );
        assert_eq!(
            (result.files[0].additions, result.files[0].deletions),
            (2, 1)
        );
    }

    #[test]
    fn replacement_characters_count_against_the_file_budget() {
        let mut bytes = b"diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n+".to_vec();
        bytes.extend_from_slice(&[0xff; 10]);
        bytes.push(b'\n');
        let budgets = Budgets {
            file_patch_bytes: bytes.len(),
            ..GENEROUS
        };
        let mut splitter = PatchSplitter::new(budgets);
        splitter.push(&bytes);
        let file = &splitter.finish().files[0];
        assert!(
            file.patch.len() <= budgets.file_patch_bytes,
            "{}",
            file.patch.len()
        );
        assert_eq!(
            file.omitted.as_ref().map(|omission| omission.reason),
            Some(OmissionReason::FileTooLarge)
        );
        assert!(!file.replaced_invalid_utf8);
    }

    #[test]
    fn a_file_over_its_budget_keeps_its_header_and_counts() {
        let budgets = Budgets {
            file_patch_bytes: 120,
            ..GENEROUS
        };
        let result = split(TWO_FILES, budgets, 7);
        let first = &result.files[0];
        assert_eq!(
            first.patch,
            "diff --git a/a.txt b/a.txt\nindex 4cb29ea..6addb9b 100644\n--- a/a.txt\n+++ b/a.txt\n"
        );
        assert_eq!((first.additions, first.deletions), (2, 1));
        assert_eq!(
            first.omitted,
            Some(Omission {
                reason: OmissionReason::FileTooLarge,
                patch_bytes: 56
            })
        );
        assert_eq!(result.files[1].omitted, None);
    }

    #[test]
    fn the_hunk_budget_omits_later_hunks_but_lists_every_file() {
        let patch = TWO_FILES.repeat(3);
        let budgets = Budgets {
            hunk_bytes: 300,
            ..GENEROUS
        };
        let result = split(&patch, budgets, 4096);
        assert_eq!(result.files.len(), 6);
        assert_eq!(result.files[0].omitted, None);
        let omitted = result.files[4].omitted.as_ref();
        assert_eq!(
            omitted.map(|omission| omission.reason),
            Some(OmissionReason::ResponseBudget)
        );
        assert_eq!(
            (result.files[4].additions, result.files[4].deletions),
            (2, 1)
        );
        assert!(result.files[5].patch.starts_with("diff --git a/bin.dat"));
    }

    #[test]
    fn headers_past_the_response_cap_are_counted_not_listed() {
        let patch = TWO_FILES.repeat(3);
        let budgets = Budgets {
            hunk_bytes: 0,
            response_bytes: 200,
            ..GENEROUS
        };
        let result = split(&patch, budgets, 5);
        let total: usize = result.files.iter().map(|file| file.patch.len()).sum();
        assert!(total <= 200, "{total}");
        assert_eq!(result.files.len() as u64 + result.unlisted_files, 6);
        assert!(result.unlisted_files > 0);
    }

    #[test]
    fn files_past_the_count_budget_are_counted_not_listed() {
        let budgets = Budgets {
            files: 1,
            ..GENEROUS
        };
        let result = split(TWO_FILES, budgets, 4096);
        assert_eq!(result.files.len(), 1);
        assert_eq!(result.unlisted_files, 1);
    }

    #[test]
    fn invalid_utf8_is_replaced_and_reported() {
        let mut bytes = b"diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-".to_vec();
        bytes.push(0xff);
        bytes.extend_from_slice(b"\n+ok\n");
        let mut splitter = PatchSplitter::new(GENEROUS);
        splitter.push(&bytes);
        let result = splitter.finish();
        assert!(result.files[0].replaced_invalid_utf8);
        assert!(result.files[0].patch.contains('\u{fffd}'));
    }

    #[test]
    fn a_final_line_without_newline_is_kept() {
        let result = split(
            "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b",
            GENEROUS,
            5,
        );
        assert!(result.files[0].patch.ends_with("\n+b"));
        assert_eq!(
            (result.files[0].additions, result.files[0].deletions),
            (1, 1)
        );
    }
}
