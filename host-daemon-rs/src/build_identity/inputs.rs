pub(crate) struct IdentityInputs<'a> {
    pub(crate) version: &'a str,
    pub(crate) commit: Option<&'a str>,
    pub(crate) modified: Option<bool>,
}

pub(crate) fn parse<'a>(
    release: Option<&'a str>,
    commit: Option<&'a str>,
    modified: Option<&str>,
) -> Result<IdentityInputs<'a>, &'static str> {
    if let Some(commit) = commit
        && (commit.len() != 40 || !commit.bytes().all(|byte| byte.is_ascii_hexdigit()))
    {
        return Err("RC_SOURCE_COMMIT must be a full 40-hex SHA");
    }
    let modified = match modified {
        None => None,
        Some("true") => Some(true),
        Some("false") => Some(false),
        Some(_) => return Err("RC_SOURCE_MODIFIED must be true or false"),
    };
    if let Some(version) = release {
        let parts: Vec<_> = version.split('.').collect();
        if parts.len() != 3
            || parts.iter().enumerate().any(|(index, part)| {
                part.is_empty()
                    || !part.bytes().all(|byte| byte.is_ascii_digit())
                    || (part.len() > 1 && part.starts_with('0'))
                    || (index > 0 && part.parse::<u16>().map_or(true, |value| value > 999))
            })
        {
            return Err("RC_RELEASE_VERSION must be X.Y.Z with minor and patch <= 999");
        }
        if commit.is_none() || modified != Some(false) {
            return Err("release builds require RC_SOURCE_COMMIT and RC_SOURCE_MODIFIED=false");
        }
    }
    Ok(IdentityInputs {
        version: release.unwrap_or("dev"),
        commit,
        modified,
    })
}

#[cfg(test)]
mod tests {
    use super::parse;

    const COMMIT: &str = "0123456789abcdef0123456789abcdef01234567";

    #[test]
    fn build_identity_preserves_unknown_and_development_provenance() {
        let unknown = parse(None, None, None).unwrap();
        assert_eq!(unknown.version, "dev");
        assert_eq!(unknown.commit, None);
        assert_eq!(unknown.modified, None);
        for (input, expected) in [("true", true), ("false", false)] {
            let dev = parse(None, Some(COMMIT), Some(input)).unwrap();
            assert_eq!(dev.version, "dev");
            assert_eq!(dev.commit, Some(COMMIT));
            assert_eq!(dev.modified, Some(expected));
        }
    }

    #[test]
    fn build_identity_requires_clean_release_provenance_and_stable_numeric_semver() {
        for version in ["3.20.0", "0.0.0", "3.999.999"] {
            let release = parse(Some(version), Some(COMMIT), Some("false")).unwrap();
            assert_eq!(release.version, version);
            assert_eq!(release.commit, Some(COMMIT));
            assert_eq!(release.modified, Some(false));
        }
        for version in [
            "",
            "dev",
            "3.20",
            "3.20.0.1",
            "03.20.0",
            "3.020.0",
            "3.20.00",
            "3.1000.0",
            "3.0.1000",
            "3.20.0-beta",
            "3.20.0+build",
            " 3.20.0",
        ] {
            assert!(
                parse(Some(version), Some(COMMIT), Some("false")).is_err(),
                "{version}"
            );
        }
        for (commit, modified) in [
            (None, Some("false")),
            (Some(COMMIT), None),
            (Some(COMMIT), Some("true")),
        ] {
            assert!(parse(Some("3.20.0"), commit, modified).is_err());
        }
    }

    #[test]
    fn build_identity_rejects_malformed_recorded_provenance() {
        for commit in [
            "",
            "01234567",
            "g123456789abcdef0123456789abcdef01234567",
            "0123456789abcdef0123456789abcdef012345678",
        ] {
            assert!(parse(None, Some(commit), None).is_err(), "{commit}");
        }
        for modified in ["", "0", "1", "False", " true"] {
            assert!(
                parse(None, Some(COMMIT), Some(modified)).is_err(),
                "{modified}"
            );
        }
    }
}
