use std::path::Path;

use serde_json::json;

use super::*;
use crate::config::HostPaths;

fn alert_token(seed: u8) -> String {
    format!("a1{seed:02x}").repeat(16)
}

fn registration(seed: u8) -> DeviceRegistration {
    fixture_registration(seed)
}

fn registration_with(seed: u8, edit: impl FnOnce(&mut serde_json::Value)) -> DeviceRegistration {
    let mut value = fixture_registration_json(seed);
    edit(&mut value);
    serde_json::from_value(value).expect("edited fixture registration")
}

fn legacy_registry(directory: &Path) -> (DeviceRegistry, HostPaths) {
    let paths = HostPaths::from_home(directory.to_path_buf()).expect("host paths");
    let registry = DeviceRegistry {
        bundle_id: DEFAULT_BUNDLE_ID.to_owned(),
        path: paths.state("devices.json"),
        legacy: Some(Arc::new(
            legacy::Sources::under(directory).expect("legacy sources"),
        )),
        _directory: None,
    };
    (registry, paths)
}

fn write_legacy_alert(paths: &HostPaths, token: &str, host: Option<&str>, fingerprint: &str) {
    std::fs::write(paths.state("apns_device_token"), token).expect("legacy token");
    std::fs::write(paths.state("apns_environment"), "development").expect("legacy environment");
    if let Some(host) = host {
        std::fs::write(
            paths.state("apns_notification_identity.json"),
            json!({"hostID": host, "tokenFingerprint": fingerprint}).to_string(),
        )
        .expect("legacy identity");
    }
}

#[tokio::test]
async fn concurrent_registrations_through_separate_handles_are_all_kept() {
    let first = DeviceRegistry::temporary();
    let second = first.clone();
    let mut tasks = Vec::new();
    for seed in 1..=16u8 {
        let registry = if seed % 2 == 0 {
            first.clone()
        } else {
            second.clone()
        };
        tasks.push(tokio::spawn(async move {
            registry
                .register(registration(seed))
                .await
                .expect("register");
        }));
    }
    for task in tasks {
        task.await.expect("registration task");
    }
    assert_eq!(first.alert_targets().await.unwrap().len(), 16);
}

#[tokio::test]
async fn legacy_sources_serve_only_while_the_registry_was_never_written() {
    let directory = tempfile::tempdir().unwrap();
    let (registry, paths) = legacy_registry(directory.path());
    let token = Token::try_from(alert_token(9)).unwrap();
    let host = "BBBBBBBB-0000-0000-0000-000000000002";
    write_legacy_alert(&paths, token.as_str(), Some(host), &token.fingerprint());

    let legacy_targets = registry.alert_targets().await.unwrap();
    assert_eq!(legacy_targets.len(), 1);
    assert_eq!(legacy_targets[0].destination.token, token);
    assert_eq!(legacy_targets[0].host_id.as_deref(), Some(host));
    assert_eq!(legacy_targets[0].host_binding, "bound");

    registry.register(registration(1)).await.unwrap();
    let registered = registry.alert_targets().await.unwrap();
    assert_eq!(registered.len(), 1);
    assert_eq!(registered[0].destination.token.as_str(), alert_token(1));

    assert!(
        registry
            .unregister(&registration(1).device_id)
            .await
            .unwrap()
    );
    assert!(registry.alert_targets().await.unwrap().is_empty());
}

#[tokio::test]
async fn legacy_alert_with_a_rotated_token_carries_no_host() {
    let directory = tempfile::tempdir().unwrap();
    let (registry, paths) = legacy_registry(directory.path());
    let token = Token::try_from(alert_token(9)).unwrap();
    write_legacy_alert(
        &paths,
        token.as_str(),
        Some("BBBBBBBB-0000-0000-0000-000000000002"),
        "rotated",
    );
    let targets = registry.alert_targets().await.unwrap();
    assert_eq!(targets[0].host_id, None);
    assert_eq!(targets[0].host_binding, "mismatch");
}

#[tokio::test]
async fn legacy_token_is_removed_only_when_it_is_still_the_rejected_one() {
    let directory = tempfile::tempdir().unwrap();
    let (registry, paths) = legacy_registry(directory.path());
    write_legacy_alert(&paths, &alert_token(9), None, "");
    let rejected = registry
        .alert_targets()
        .await
        .unwrap()
        .remove(0)
        .destination;
    let file = paths.state("apns_device_token");

    std::fs::write(&file, alert_token(10)).unwrap();
    registry.invalidate(&rejected, TokenKind::Alert).await;
    assert!(file.exists());

    let current = registry
        .alert_targets()
        .await
        .unwrap()
        .remove(0)
        .destination;
    registry.invalidate(&current, TokenKind::Alert).await;
    assert!(!file.exists());
}

#[tokio::test]
async fn registering_replaces_the_devices_whole_token_set() {
    let registry = DeviceRegistry::temporary();
    registry.register(registration(1)).await.unwrap();
    registry
        .register(registration_with(1, |value| {
            value["tokens"] = json!({"alert": alert_token(7)});
        }))
        .await
        .unwrap();

    let targets = registry.alert_targets().await.unwrap();
    assert_eq!(targets.len(), 1);
    assert_eq!(targets[0].destination.token.as_str(), alert_token(7));
    assert!(
        registry
            .live_activity_destinations()
            .await
            .unwrap()
            .is_empty()
    );
    assert!(registry.voip_destination().await.unwrap().is_none());
    assert!(registry.location_target().await.unwrap().is_none());
}

#[tokio::test]
async fn a_token_belongs_to_the_device_that_registered_it_last() {
    let registry = DeviceRegistry::temporary();
    registry
        .register(registration_with(1, |value| {
            value["tokens"] = json!({"alert": alert_token(5)});
        }))
        .await
        .unwrap();
    registry
        .register(registration_with(2, |value| {
            value["tokens"] = json!({"alert": alert_token(5)});
        }))
        .await
        .unwrap();

    let targets = registry.alert_targets().await.unwrap();
    assert_eq!(targets.len(), 1);
    assert_eq!(
        targets[0].destination.device_id(),
        Some(registration(2).device_id.as_str())
    );
}

#[tokio::test]
async fn invalidation_only_removes_the_token_that_was_rejected() {
    let registry = DeviceRegistry::temporary();
    registry.register(registration(1)).await.unwrap();
    let rejected = registry
        .alert_targets()
        .await
        .unwrap()
        .remove(0)
        .destination;
    registry
        .register(registration_with(1, |value| {
            value["tokens"]["alert"] = json!(alert_token(8));
        }))
        .await
        .unwrap();

    registry.invalidate(&rejected, TokenKind::Alert).await;
    let targets = registry.alert_targets().await.unwrap();
    assert_eq!(targets.len(), 1);
    assert_eq!(targets[0].destination.token.as_str(), alert_token(8));

    let current = targets[0].destination.clone();
    registry.invalidate(&current, TokenKind::Alert).await;
    assert!(registry.alert_targets().await.unwrap().is_empty());
    assert!(registry.voip_destination().await.unwrap().is_some());
}

#[tokio::test]
async fn unregistering_an_unknown_device_changes_nothing() {
    let registry = DeviceRegistry::temporary();
    registry.register(registration(1)).await.unwrap();
    assert!(
        !registry
            .unregister(&registration(2).device_id)
            .await
            .unwrap()
    );
    assert_eq!(registry.alert_targets().await.unwrap().len(), 1);
    assert!(registry.unregister("not-a-uuid").await.is_err());
}

#[tokio::test]
async fn the_registry_holds_at_most_thirty_two_devices() {
    let registry = DeviceRegistry::temporary();
    for seed in 1..=32u8 {
        registry.register(registration(seed)).await.unwrap();
    }
    assert!(matches!(
        registry.register(registration(33)).await,
        Err(RegisterError::Full(_))
    ));
    registry.register(registration(32)).await.unwrap();
    assert_eq!(registry.alert_targets().await.unwrap().len(), 32);
}

#[tokio::test]
async fn an_unreadable_registry_is_reported_and_never_overwritten() {
    for contents in ["{not json", r#"{"version":2,"devices":[]}"#] {
        let registry = DeviceRegistry::temporary();
        std::fs::write(&registry.path, contents).unwrap();
        assert!(registry.alert_targets().await.is_err());
        assert!(matches!(
            registry.register(registration(1)).await,
            Err(RegisterError::Unavailable(_))
        ));
        assert_eq!(std::fs::read_to_string(&registry.path).unwrap(), contents);
    }
}

#[tokio::test]
async fn voip_and_location_go_to_the_most_recently_registered_device() {
    let registry = DeviceRegistry::temporary();
    registry.register(registration(1)).await.unwrap();
    registry
        .register(registration_with(2, |value| {
            value["tokens"]["location"]["navigation"]["eventBaseUrl"] =
                json!("https://second.example");
        }))
        .await
        .unwrap();
    let voip = registry.voip_destination().await.unwrap().unwrap();
    assert_eq!(voip.device_id(), Some(registration(2).device_id.as_str()));
    let location = registry.location_target().await.unwrap().unwrap();
    assert_eq!(location.navigation.event_base_url, "https://second.example");

    registry.register(registration(1)).await.unwrap();
    let voip = registry.voip_destination().await.unwrap().unwrap();
    assert_eq!(voip.device_id(), Some(registration(1).device_id.as_str()));
}

#[tokio::test]
async fn a_registration_for_another_bundle_is_rejected() {
    let registry = DeviceRegistry::temporary();
    let result = registry
        .register(registration_with(1, |value| {
            value["bundleId"] = json!("someone.else");
        }))
        .await;
    assert!(matches!(result, Err(RegisterError::Invalid(_))));
    assert!(registry.alert_targets().await.unwrap().is_empty());
}

#[tokio::test]
async fn tokens_never_appear_in_debug_output_or_the_journaled_entry() {
    let registry = DeviceRegistry::temporary();
    let recorded = registry.register(registration(1)).await.unwrap();
    let recorded = recorded.to_string();
    let debug = format!("{:?}", registration(1));
    let target = format!("{:?}", registry.alert_targets().await.unwrap());
    for text in [recorded, debug, target] {
        for kind in [0xa1u8, 0xa2, 0xa3, 0xa4] {
            assert!(
                !text.contains(&format!("{kind:02x}01").repeat(16)),
                "{text}"
            );
        }
    }
}

#[test]
fn a_token_must_be_hexadecimal_of_plausible_length() {
    assert!(Token::try_from("ab".repeat(16)).is_ok());
    assert!(Token::try_from("ab".repeat(15)).is_err());
    assert!(Token::try_from("ab".repeat(129)).is_err());
    assert!(Token::try_from("zz".repeat(16)).is_err());
    assert_eq!(
        Token::try_from(format!(" {} ", "AB".repeat(16)))
            .unwrap()
            .as_str(),
        "ab".repeat(16)
    );
}

#[test]
fn event_base_url_must_be_a_plain_http_or_https_origin() {
    let inputs = |url: &str| NavigationStartInputs {
        event_base_url: url.to_string(),
        setup_ready: true,
        authorization: "authorizedAlways".to_string(),
        full_accuracy: true,
        google_terms_accepted: true,
    };
    assert_eq!(
        inputs(" https://gateway.example:8443/ ")
            .normalized_event_base_url()
            .unwrap(),
        "https://gateway.example:8443"
    );
    for rejected in [
        "https://",
        "ftp://gateway.example",
        "gateway.example",
        "https://user:secret@gateway.example",
        "https://gateway.example?next=1",
        "https://gateway.example#frag",
    ] {
        assert!(inputs(rejected).validate().is_err(), "{rejected}");
    }
}

#[tokio::test]
async fn the_shared_fixture_registration_is_accepted() {
    let fixture: DeviceRegistration = serde_json::from_str(include_str!(
        "../../../protocol-fixtures/devices/register.json"
    ))
    .expect("fixture registration");
    let registry = DeviceRegistry::temporary();
    registry.register(fixture).await.unwrap();
    assert_eq!(registry.alert_targets().await.unwrap().len(), 1);
    assert!(registry.location_target().await.unwrap().is_some());
}
