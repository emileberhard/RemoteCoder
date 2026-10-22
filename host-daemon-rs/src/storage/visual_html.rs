use std::cell::{Cell, RefCell};

use cssparser::{ParseError, Parser, Token as CssToken};
use html5ever::tokenizer::states::RawKind;
use html5ever::tokenizer::{BufferQueue, TagKind, Token, TokenSink, TokenSinkResult, Tokenizer};

const HOST_FILE_ERROR: &str = "Host files cannot load in a visual: inline them as content or data: URLs, or load https: resources. Local images work only as paths in <img src>, <video poster> and SVG <image href>.";
const CSS_RESOURCE_ERROR: &str = "Host files cannot load in visual CSS: replace local url(), image-set() and @import sources with data: or https: URLs; show a local image with <img src> and its path instead.";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct Rejection {
    pub(super) message: &'static str,
    pub(super) category: &'static str,
}

impl std::fmt::Display for Rejection {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(self.message)
    }
}

impl std::error::Error for Rejection {}

#[derive(Default)]
struct HtmlValidation {
    error: RefCell<Option<Rejection>>,
    has_element: Cell<bool>,
    in_style: Cell<bool>,
    style: RefCell<String>,
}

impl HtmlValidation {
    fn fail(&self, message: &'static str, category: &'static str) {
        self.error
            .borrow_mut()
            .get_or_insert(Rejection { message, category });
    }

    fn fail_css(&self, css: &str) {
        if let Err(local) = validate_css(css) {
            if local {
                self.fail(CSS_RESOURCE_ERROR, "css_local_reference");
            } else {
                self.fail(
                    "Visual CSS cannot nest blocks more than 128 levels deep.",
                    "css_nesting",
                );
            }
        }
    }

    fn finish_style(&self) {
        self.fail_css(&self.style.borrow());
        self.style.borrow_mut().clear();
        self.in_style.set(false);
    }
}

impl TokenSink for HtmlValidation {
    type Handle = ();

    fn process_token(&self, token: Token, _: u64) -> TokenSinkResult<()> {
        match token {
            Token::TagToken(tag) => {
                let name = tag.name.as_ref();
                if tag.kind == TagKind::EndTag {
                    if name == "style" && self.in_style.get() {
                        self.finish_style();
                    }
                    return TokenSinkResult::Continue;
                }
                for attr in &tag.attrs {
                    let attribute = attr.name.local.as_ref();
                    let value = attr.value.as_ref();
                    if attribute == "style" {
                        self.fail_css(value);
                    }
                    let resource = matches!(attribute, "src" | "poster" | "background")
                        || attribute == "data" && name == "object"
                        || matches!(attribute, "href" | "xlink:href")
                            && matches!(name, "link" | "use" | "image" | "feimage" | "base");
                    let source_set = matches!(attribute, "srcset" | "imagesrcset")
                        && source_set_urls(value).into_iter().any(host_file);
                    if (resource && host_file(value)) || source_set {
                        self.fail(HOST_FILE_ERROR, "local_resource");
                    }
                }
                self.has_element.set(true);
                match name {
                    "script" => return TokenSinkResult::RawData(RawKind::ScriptData),
                    "style" => {
                        self.in_style.set(true);
                        return TokenSinkResult::RawData(RawKind::Rawtext);
                    }
                    "title" | "textarea" => return TokenSinkResult::RawData(RawKind::Rcdata),
                    "xmp" | "iframe" | "noembed" | "noframes" => {
                        return TokenSinkResult::RawData(RawKind::Rawtext);
                    }
                    "plaintext" => return TokenSinkResult::Plaintext,
                    _ => {}
                }
            }
            Token::CharacterTokens(text) if self.in_style.get() => {
                self.style.borrow_mut().push_str(&text)
            }
            Token::EOFToken if self.in_style.get() => self.finish_style(),
            _ => {}
        }
        TokenSinkResult::Continue
    }
}

fn host_file(value: &str) -> bool {
    let value = value.trim();
    if value.is_empty() || value.starts_with('#') || value.starts_with("//") {
        return false;
    }
    match value
        .find(':')
        .filter(|colon| !value[..*colon].contains(['/', '?', '#']))
    {
        Some(colon) => value[..colon].eq_ignore_ascii_case("file"),
        None => true,
    }
}

fn source_set_urls(value: &str) -> Vec<&str> {
    let mut urls = Vec::new();
    let mut rest = value;
    loop {
        rest = rest.trim_start_matches(|c: char| c.is_ascii_whitespace() || c == ',');
        if rest.is_empty() {
            return urls;
        }
        let end = rest
            .find(|c: char| c.is_ascii_whitespace())
            .unwrap_or(rest.len());
        let url = &rest[..end];
        rest = &rest[end..];
        if let Some(url) = url.strip_suffix(',') {
            urls.push(url.trim_end_matches(','));
            continue;
        }
        urls.push(url);
        let mut parenthesized = false;
        let descriptors = rest
            .find(|c: char| {
                match c {
                    '(' => parenthesized = true,
                    ')' => parenthesized = false,
                    _ => {}
                }
                c == ',' && !parenthesized
            })
            .unwrap_or(rest.len());
        rest = &rest[descriptors..];
    }
}

pub(super) fn validate_html(html: &str) -> Result<(), Rejection> {
    if html.contains('\0') {
        return Err(Rejection {
            message: "HTML cannot contain NUL bytes",
            category: "invalid_html",
        });
    }
    let input = BufferQueue::default();
    input.push_back(html.into());
    let tokenizer = Tokenizer::new(HtmlValidation::default(), Default::default());
    let _ = tokenizer.feed(&input);
    tokenizer.end();
    if let Some(error) = *tokenizer.sink.error.borrow() {
        return Err(error);
    }
    if !tokenizer.sink.has_element.get() {
        return Err(Rejection {
            message: "source must contain an HTML element start tag",
            category: "invalid_html",
        });
    }
    Ok(())
}

fn validate_css(css: &str) -> Result<(), bool> {
    let mut parser = Parser::new(css);
    css_tokens(&mut parser, 0, false).map_err(|error| match error.kind {
        cssparser::ParseErrorKind::Custom(local) => local,
        cssparser::ParseErrorKind::Basic(_) => false,
    })
}

fn css_tokens(
    parser: &mut Parser<'_>,
    depth: usize,
    image_strings: bool,
) -> Result<(), ParseError<bool>> {
    if depth > 128 {
        return Err(ParseError::custom(false));
    }
    while let Ok(token) = parser.next().cloned() {
        match token {
            CssToken::AtKeyword(name) if name.eq_ignore_ascii_case("import") => {
                if let Ok(url) = parser.try_parse(|import| import.expect_string().cloned())
                    && host_file(&url)
                {
                    return Err(ParseError::custom(true));
                }
            }
            CssToken::UnquotedUrl(url) if host_file(&url) => return Err(ParseError::custom(true)),
            CssToken::QuotedString(url) if image_strings && host_file(&url) => {
                return Err(ParseError::custom(true));
            }
            CssToken::Function(name) if name.eq_ignore_ascii_case("url") => {
                parser.parse_nested_block(|nested| match nested.expect_string() {
                    Ok(url) if host_file(url) => Err(ParseError::custom(true)),
                    _ => Ok(()),
                })?;
            }
            CssToken::Function(name) => {
                let image_strings = name.eq_ignore_ascii_case("image-set")
                    || name.eq_ignore_ascii_case("-webkit-image-set")
                    || name.eq_ignore_ascii_case("src")
                    || name.eq_ignore_ascii_case("image");
                parser.parse_nested_block(|nested| css_tokens(nested, depth + 1, image_strings))?;
            }
            CssToken::ParenthesisBlock
            | CssToken::SquareBracketBlock
            | CssToken::CurlyBracketBlock => {
                parser.parse_nested_block(|nested| css_tokens(nested, depth + 1, image_strings))?;
            }
            _ => {}
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn network_resources_publish_and_host_files_are_rejected_after_decoding() {
        let nested = format!(
            "<style>{}{}</style><div>x</div>",
            "a{".repeat(130),
            "}".repeat(130)
        );
        for html in [
            r#"<div><script src="https://example.com/chart.js"></script></div>"#,
            r#"<div><link rel="stylesheet" href="//example.com/chart.css"></div>"#,
            r#"<img src="https&#58;//example.com/a.png" srcset="https://example.com/a2.png 2x">"#,
            r#"<iframe src="https://example.com/embed" srcdoc="<p>x</p>"></iframe>"#,
            r#"<style>@import 'https://example.com/chart.css';</style><div>visual</div>"#,
            r#"<style>@import url(https://example.com/a.css);</style><div>visual</div>"#,
            r#"<style>@import; div {background:url()}</style><div>visual</div>"#,
            r#"<img srcset="data:image/png;base64,AA== 1x, https://example.com/a,b.png 2x">"#,
            r#"<style>div {background:image-set('https://example.com/a.png' 1x)}</style><div>visual</div>"#,
        ] {
            validate_html(html).unwrap();
        }
        for (html, category) in [
            (r#"<img src="/tmp/a.png">"#, "local_resource"),
            (r#"<img src="shots/a.png">"#, "local_resource"),
            (
                r#"<iframe src="/host-file.html"></iframe>"#,
                "local_resource",
            ),
            (
                r#"<img src="data:image/png;base64,AA==" srcset="https://example.com/a.png 1x, /tmp/a@2x.png 2x">"#,
                "local_resource",
            ),
            (
                r#"<img srcset="https://example.com/a.png 1x,/tmp/a@2x.png 2x">"#,
                "local_resource",
            ),
            (
                r#"<script src="FILE:///tmp/a.js"></script>"#,
                "local_resource",
            ),
            (
                r#"<div style="background:url(/tmp/a.png)">x</div>"#,
                "css_local_reference",
            ),
            (
                r#"<style>div {background: u\72l(a.png)}</style><div>x</div>"#,
                "css_local_reference",
            ),
            (
                r#"<style>div {background:image-set('shots/a.png' 1x)}</style><div>x</div>"#,
                "css_local_reference",
            ),
            (
                r#"<style>@media (width > 300px) { div {background:url(file:///tmp/a.png)}} </style><div>x</div>"#,
                "css_local_reference",
            ),
            (
                r#"<style>@import 'a.css';</style><div>x</div>"#,
                "css_local_reference",
            ),
            (nested.as_str(), "css_nesting"),
            ("plain text", "invalid_html"),
        ] {
            let error = validate_html(html).unwrap_err();
            assert_eq!(error.category, category, "{html}");
        }
    }

    #[test]
    fn element_start_tags_admit_fragments_without_a_content_tag_allowlist() {
        for html in [
            "<h4>Heading</h4>",
            "<pre>Code</pre>",
            "<dl><dt>Name</dt><dd>Value</dd></dl>",
            "<nav>Navigation</nav>",
            "<header>Header</header>",
            "<label>Label</label>",
            "<custom-chart></custom-chart>",
            "<div>Unclosed fragment",
            "<script>document.body.append('Content');</script>",
        ] {
            validate_html(html).unwrap();
        }
        for html in [
            "plain text",
            "{\"title\":\"Report\"}",
            "# Markdown heading",
            "<!-- <h4>Comment</h4> -->",
            "</h4>",
            "&lt;h4&gt;Escaped text&lt;/h4&gt;",
        ] {
            assert!(validate_html(html).is_err(), "{html}");
        }
    }

    #[test]
    fn comments_javascript_strings_and_inline_resources_are_preserved() {
        let html = r##"<!doctype html><html><head>
<style>/* @import '/tmp/not-real.css' */
div::after {content:'url(/tmp/not-real.png)';}
div {background:url('data:image/png;base64,AA=='); filter:url(#filter);}
</style></head><body>
<!-- <img src='/tmp/not-real.png'> -->
<script>const example = "<img src='/tmp/not-real.png'>";</script>
<img src='data:image/png;base64,AA=='><div style='color:var(--rc-text)'>visual</div>
</body></html>"##;
        validate_html(html).unwrap();
    }
}
