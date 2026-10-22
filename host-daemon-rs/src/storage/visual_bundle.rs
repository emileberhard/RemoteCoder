use std::cell::RefCell;
use std::collections::HashMap;
use std::ops::Range;
use std::path::{Path, PathBuf};

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use lol_html::{HtmlRewriter, MemorySettings, Settings, element};
use url::Url;

use super::visual_images::EmbeddedImage;
use super::visuals::MAX_HTML_BYTES;

pub(super) const MAX_IMAGES: usize = 16;
const PARSER_MEMORY_BYTES: usize = 8 * 1024 * 1024;

pub(super) struct LocalImages {
    paths: Vec<PathBuf>,
    occurrences: Vec<Occurrence>,
}

struct Occurrence {
    range: Range<usize>,
    image: usize,
}

impl LocalImages {
    pub(super) fn find(html: &str, source: Option<&Path>) -> Result<Self, String> {
        let base = source
            .map(|source| {
                Url::from_file_path(source)
                    .map_err(|()| format!("{} is not an absolute file path", source.display()))
            })
            .transpose()?;
        let mut paths = Vec::new();
        let mut indices = HashMap::new();
        let mut occurrences = Vec::new();
        let mut errors = Vec::new();
        for range in image_values(html)? {
            let value = html
                .get(range.clone())
                .ok_or("an image reference is not on a character boundary")?;
            let Some(resolved) = local_reference(base.as_ref(), value) else {
                continue;
            };
            let path = match resolved {
                Ok(path) => path,
                Err(reason) => {
                    errors.push(format!("- {}: {reason}", value.trim()));
                    continue;
                }
            };
            let image = match indices.get(&path) {
                Some(&image) => image,
                None if paths.len() == MAX_IMAGES => {
                    errors.push(format!(
                        "- more than {MAX_IMAGES} distinct local images; a visual can embed at most {MAX_IMAGES}"
                    ));
                    break;
                }
                None => {
                    indices.insert(path.clone(), paths.len());
                    paths.push(path);
                    paths.len() - 1
                }
            };
            occurrences.push(Occurrence { range, image });
        }
        if !errors.is_empty() {
            return Err(format!(
                "Local image references could not be embedded:\n{}",
                errors.join("\n")
            ));
        }
        occurrences.sort_by_key(|occurrence| occurrence.range.start);
        if occurrences
            .windows(2)
            .any(|pair| pair[0].range.end > pair[1].range.start)
        {
            return Err("image references overlap".into());
        }
        Ok(Self { paths, occurrences })
    }

    pub(super) fn paths(&self) -> &[PathBuf] {
        &self.paths
    }

    pub(super) fn occurrences(&self) -> usize {
        self.occurrences.len()
    }

    pub(super) fn embed(&self, html: &str, images: &[EmbeddedImage]) -> Result<Vec<u8>, String> {
        if images.len() != self.paths.len() {
            return Err("prepared images do not match their references".into());
        }
        let counts = self.paths.iter().enumerate().map(|(image, _)| {
            self.occurrences
                .iter()
                .filter(|occurrence| occurrence.image == image)
                .count()
        });
        let mut total = html.len();
        let mut itemized = Vec::with_capacity(images.len());
        for ((path, image), count) in self.paths.iter().zip(images).zip(counts) {
            let embedded = image.data_url_len().ok_or("embedded image size overflow")?;
            itemized.push((path, embedded, count));
            let added = embedded
                .checked_mul(count)
                .ok_or("embedded image size overflow")?;
            total = total
                .checked_add(added)
                .ok_or("embedded image size overflow")?;
        }
        for occurrence in &self.occurrences {
            total -= occurrence.range.len();
        }
        if total > MAX_HTML_BYTES {
            let lines = itemized
                .iter()
                .map(|(path, embedded, count)| {
                    format!("- {}: {embedded} bytes × {count}", path.display())
                })
                .collect::<Vec<_>>()
                .join("\n");
            return Err(format!(
                "The visual would be {total} bytes with its images embedded, over the {MAX_HTML_BYTES}-byte limit:\n- HTML: {} bytes\n{lines}\nUse fewer, smaller or cropped images.",
                html.len()
            ));
        }
        let urls = images
            .iter()
            .map(EmbeddedImage::data_url)
            .collect::<Vec<_>>();
        let mut output = Vec::with_capacity(total);
        let mut copied = 0;
        for occurrence in &self.occurrences {
            output.extend_from_slice(&html.as_bytes()[copied..occurrence.range.start]);
            output.extend_from_slice(urls[occurrence.image].as_bytes());
            copied = occurrence.range.end;
        }
        output.extend_from_slice(&html.as_bytes()[copied..]);
        debug_assert_eq!(output.len(), total);
        Ok(output)
    }
}

impl EmbeddedImage {
    fn data_url_len(&self) -> Option<usize> {
        let encoded = self.bytes.len().div_ceil(3).checked_mul(4)?;
        "data:;base64,"
            .len()
            .checked_add(self.mime.len())?
            .checked_add(encoded)
    }

    fn data_url(&self) -> String {
        let mut url = format!("data:{};base64,", self.mime);
        STANDARD.encode_string(&self.bytes, &mut url);
        url
    }
}

fn image_values(html: &str) -> Result<Vec<Range<usize>>, String> {
    let ranges = RefCell::new(Vec::new());
    let mut rewriter = HtmlRewriter::new(
        Settings::new()
            .with_strict(true)
            .with_memory_settings(
                MemorySettings::new().with_max_allowed_memory_usage(PARSER_MEMORY_BYTES),
            )
            .append_element_content_handler(element!("img, video, image", |element| {
                let tag = element.tag_name();
                for attribute in element.attributes() {
                    let name = attribute.name();
                    let bundled = match tag.as_str() {
                        "img" => name == "src",
                        "video" => name == "poster",
                        "image" => name == "href" || name == "xlink:href",
                        _ => false,
                    };
                    if bundled && let Some(location) = attribute.value_source_location() {
                        ranges.borrow_mut().push(location.bytes());
                    }
                }
                Ok(())
            })),
        |_: &[u8]| {},
    );
    rewriter
        .write(html.as_bytes())
        .and_then(|()| rewriter.end())
        .map_err(|error| format!("Could not find image references in the HTML: {error}"))?;
    Ok(ranges.into_inner())
}

fn local_reference(base: Option<&Url>, value: &str) -> Option<Result<PathBuf, &'static str>> {
    let trimmed = value.trim();
    if trimmed.is_empty()
        || trimmed.starts_with('#')
        || trimmed
            .get(..5)
            .is_some_and(|scheme| scheme.eq_ignore_ascii_case("data:"))
    {
        return None;
    }
    let url = match base {
        Some(base) => base.join(trimmed).ok()?,
        None if trimmed.starts_with('/') => Url::parse("file:///").ok()?.join(trimmed).ok()?,
        None => match Url::parse(trimmed) {
            Err(url::ParseError::RelativeUrlWithoutBase) => {
                return Some(Err(
                    "inline HTML has no directory, so give local images an absolute path",
                ));
            }
            parsed => parsed.ok()?,
        },
    };
    if url.scheme() != "file"
        || url.host_str().is_some_and(|host| !host.is_empty())
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return None;
    }
    if trimmed.contains('&') {
        return Some(Err("percent-encode & as %26"));
    }
    Some(url.to_file_path().map_err(|()| "not a local file path"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn image(mime: &'static str, bytes: &[u8]) -> EmbeddedImage {
        EmbeddedImage {
            mime,
            bytes: bytes.to_vec(),
            converted: false,
        }
    }

    fn found(html: &str) -> Vec<(String, PathBuf)> {
        let images = LocalImages::find(html, Some(Path::new("/visuals/page.html"))).unwrap();
        images
            .occurrences
            .iter()
            .map(|occurrence| {
                (
                    html[occurrence.range.clone()].to_owned(),
                    images.paths[occurrence.image].clone(),
                )
            })
            .collect()
    }

    #[test]
    fn local_paths_resolve_against_the_source_and_everything_else_is_left_alone() {
        let html = r##"<img src="/abs/a.png"><img src='file:///abs/b%20c.png'>
<img src=rel/d.png><img src="../up.png"><img src="data:image/png;base64,AA==">
<img src="#frag"><img src=""><img src="https://example.com/x.png"><img src="//host/x.png">
<img src="x.png?q=1"><img src="blob:abc">"##;
        assert_eq!(
            found(html),
            [
                ("/abs/a.png".into(), PathBuf::from("/abs/a.png")),
                (
                    "file:///abs/b%20c.png".into(),
                    PathBuf::from("/abs/b c.png")
                ),
                ("rel/d.png".into(), PathBuf::from("/visuals/rel/d.png")),
                ("../up.png".into(), PathBuf::from("/up.png")),
            ]
        );
    }

    #[test]
    fn only_real_image_positions_are_found_including_template_and_foreign_object() {
        let html = r#"<script>const s = "<img src='/script.png'>";</script>
<style>/* <img src="/style.png"> */</style><!-- <img src="/comment.png"> -->
&lt;img src="/escaped.png"&gt;<textarea><img src="/textarea.png"></textarea>
<template><img src="/template.png"></template>
<svg><image href="/svg.png"/><image xlink:href="/xlink.png"/>
<foreignObject><div><img src="/foreign.png"></div></foreignObject></svg>
<video poster="/poster.png" src="/video.mp4"></video><iframe src="/frame.html"></iframe>
<img alt="/alt.png" data-src="/data.png" src=/last.png>"#;
        let paths = found(html)
            .into_iter()
            .map(|(_, path)| path.to_string_lossy().into_owned())
            .collect::<Vec<_>>();
        assert_eq!(
            paths,
            [
                "/template.png",
                "/svg.png",
                "/xlink.png",
                "/foreign.png",
                "/poster.png",
                "/last.png"
            ]
        );
    }

    #[test]
    fn references_with_ampersands_and_too_many_images_fail_with_every_reason() {
        let error = LocalImages::find(
            r#"<img src="/a&amp;b.png"><img src="/c&d.png"><img src="https://x/?a&b">"#,
            Some(Path::new("/v/page.html")),
        )
        .err()
        .unwrap();
        assert!(
            error.contains("/a&amp;b.png: percent-encode & as %26"),
            "{error}"
        );
        assert!(
            error.contains("/c&d.png: percent-encode & as %26"),
            "{error}"
        );
        assert!(!error.contains("https"), "{error}");
        let many = (0..=MAX_IMAGES)
            .map(|index| format!("<img src=\"/{index}.png\">"))
            .collect::<String>();
        let error = LocalImages::find(&many, Some(Path::new("/v/page.html")))
            .err()
            .unwrap();
        assert!(
            error.contains("more than 16 distinct local images"),
            "{error}"
        );
        let repeated = "<img src=\"/same.png\">".repeat(100);
        let images = LocalImages::find(&repeated, Some(Path::new("/v/page.html"))).unwrap();
        assert_eq!((images.paths().len(), images.occurrences()), (1, 100));
    }

    #[test]
    fn splicing_replaces_exactly_the_values_in_every_quoting_style() {
        let html = "<p>é</p><img src=\"/a.png\"><img src='/b.png' alt=x><img src=/a.png>";
        let images = LocalImages::find(html, Some(Path::new("/v/page.html"))).unwrap();
        let output = images
            .embed(
                html,
                &[image("image/png", b"abc"), image("image/jpeg", b"de")],
            )
            .unwrap();
        assert_eq!(
            String::from_utf8(output).unwrap(),
            "<p>é</p><img src=\"data:image/png;base64,YWJj\"><img src='data:image/jpeg;base64,ZGU=' alt=x><img src=data:image/png;base64,YWJj>"
        );
    }

    #[test]
    fn the_exact_size_counts_every_occurrence_before_allocating() {
        let html = "<img src=\"/same.png\">".repeat(5_000);
        let images = LocalImages::find(&html, Some(Path::new("/v/page.html"))).unwrap();
        let error = images
            .embed(&html, &[image("image/jpeg", &vec![0; 200 * 1024])])
            .unwrap_err();
        assert!(error.contains("/same.png: 273091 bytes × 5000"), "{error}");
        assert!(
            error.contains(&format!("- HTML: {} bytes", html.len())),
            "{error}"
        );
        let fits = "<img src=\"/same.png\">".repeat(3);
        let images = LocalImages::find(&fits, Some(Path::new("/v/page.html"))).unwrap();
        let output = images
            .embed(&fits, &[image("image/gif", &[0; 1000])])
            .unwrap();
        let url_len = "data:image/gif;base64,".len() + 1336;
        assert_eq!(output.len(), fits.len() + 3 * (url_len - "/same.png".len()));
    }
}
