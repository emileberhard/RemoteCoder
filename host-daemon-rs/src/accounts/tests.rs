use super::*;
use crate::accounts::types::{DEFAULT_CLAUDE, DEFAULT_CODEX};
use serde_json::json;
use std::time::{Duration, Instant};

#[tokio::test]
async fn directory_and_resets_have_only_host_defaults() {
    let home = tempfile::tempdir().unwrap();
    let claude = ClaudeSettings::isolated_for_test();
    let host = crate::test_support::TestGateway::new();
    let owner = Accounts::open_in(
        home.path().to_path_buf(),
        Arc::clone(&host),
        claude.settings.clone(),
    )
    .await
    .unwrap();
    let directory = owner.directory().await;
    assert_eq!(
        directory
            .accounts
            .iter()
            .map(|a| a.id.as_str())
            .collect::<Vec<_>>(),
        [DEFAULT_CODEX, DEFAULT_CLAUDE]
    );
    assert!(
        owner
            .router_account_for_reset(DEFAULT_CODEX, 1)
            .await
            .is_ok()
    );
    assert!(
        owner
            .router_account_for_reset(DEFAULT_CODEX, 2)
            .await
            .err()
            .unwrap()
            .is::<resets::ResetAccountChanged>()
    );
    let id: AccountId = "e1741c43-3d9a-4448-9f4a-3c7e5906e852"
        .to_owned()
        .try_into()
        .unwrap();
    assert!(owner.gateway_for_account(&id, None).await.is_err());
    assert!(
        owner
            .router_account_for_reset(id.as_str(), 1)
            .await
            .err()
            .unwrap()
            .is::<resets::ResetAccountNotFound>()
    );
    owner.stop().await;
}

#[tokio::test]
async fn retired_accounts_redirect_at_any_generation() {
    let home = tempfile::tempdir().unwrap();
    let claude = ClaudeSettings::isolated_for_test();
    let host = crate::test_support::TestGateway::new();
    let mut owner = Accounts::open_in(
        home.path().to_path_buf(),
        Arc::clone(&host),
        claude.settings.clone(),
    )
    .await
    .unwrap();
    let codex: AccountId = "e1741c43-3d9a-4448-9f4a-3c7e5906e852"
        .to_owned()
        .try_into()
        .unwrap();
    let claude: AccountId = "e1741c43-3d9a-4448-9f4a-3c7e5906e853"
        .to_owned()
        .try_into()
        .unwrap();
    let unique = Arc::get_mut(&mut owner).unwrap();
    unique.retired_codex_ids.insert(codex.clone());
    unique.retired_claude_ids.insert(claude.clone());
    for id in [&codex, &claude] {
        for generation in [None, Some(0), Some(1), Some(u64::MAX)] {
            assert!(Arc::ptr_eq(
                &owner.gateway_for_account(id, generation).await.unwrap(),
                &host
            ));
        }
    }
    let directory = owner.directory().await;
    assert_eq!(directory.accounts.len(), 2);
    assert_eq!(directory.retired_codex_account_ids, [codex]);
    assert_eq!(directory.retired_claude_account_ids, [claude]);
    owner.stop().await;
}

async fn open_accounts(
    directory: &tempfile::TempDir,
    claude_test: &crate::providers::claude::settings::ClaudeTestSettings,
) -> Arc<Accounts> {
    let host = crate::gateway::Gateway::with_turn_state(
        Arc::new(
            crate::providers::codex::daemon::CodexAppServer::new_for_test_socket(
                directory.path().join("codex"),
            ),
        ),
        claude_test.settings.clone(),
        crate::observability::journal::Journal::disabled(),
        None,
    );
    Accounts::open_in(
        directory.path().to_path_buf(),
        host,
        claude_test.settings.clone(),
    )
    .await
    .unwrap()
}

#[tokio::test]
async fn a_draining_gateway_refuses_account_work_as_restarting() {
    let claude_test = crate::providers::claude::settings::ClaudeSettings::isolated_for_test();
    let directory = tempfile::tempdir().unwrap();
    let accounts = open_accounts(&directory, &claude_test).await;
    accounts.drain().await;

    let lookup = accounts
        .gateway_for_account(
            &"e1741c43-3d9a-4448-9f4a-3c7e5906e852"
                .to_owned()
                .try_into()
                .unwrap(),
            None,
        )
        .await;
    assert!(lookup.is_err_and(|error| error.is::<GatewayStopping>()));
}

#[tokio::test]
async fn a_failed_default_refresh_keeps_the_full_default_label() {
    let claude_test = crate::providers::claude::settings::ClaudeSettings::isolated_for_test();
    let directory = tempfile::tempdir().unwrap();
    let accounts = open_accounts(&directory, &claude_test).await;
    assert!(!accounts.refresh_one(super::types::DEFAULT_CODEX).await);
    let snapshots = accounts.snapshots.read().await;
    assert_eq!(
        snapshots[super::types::DEFAULT_CODEX].label,
        "Host default · ChatGPT"
    );
}

#[tokio::test]
async fn accounts_directory_wait_returns_when_the_in_flight_round_ends() {
    let claude_test = crate::providers::claude::settings::ClaudeSettings::isolated_for_test();
    let directory = tempfile::tempdir().unwrap();
    let accounts = open_accounts(&directory, &claude_test).await;
    tokio::time::timeout(
        Duration::from_secs(5),
        accounts.refresh_settled(Duration::from_secs(30)),
    )
    .await
    .expect("no refresh in flight returns at once");

    accounts.refreshing.send_modify(|owners| {
        owners.insert("round".to_owned());
    });
    let waiting = {
        let accounts = Arc::clone(&accounts);
        tokio::spawn(async move { accounts.refresh_settled(Duration::from_secs(30)).await })
    };
    tokio::time::sleep(Duration::from_millis(50)).await;
    assert!(!waiting.is_finished());
    assert!(accounts.directory().await.refreshing);
    accounts
        .refreshing
        .send_if_modified(|owners| owners.remove("round"));
    tokio::time::timeout(Duration::from_secs(5), waiting)
        .await
        .expect("the settled round releases the waiter")
        .unwrap();
    assert!(!accounts.directory().await.refreshing);
}

#[tokio::test]
async fn accounts_directory_wait_stops_at_its_bound() {
    let claude_test = crate::providers::claude::settings::ClaudeSettings::isolated_for_test();
    let directory = tempfile::tempdir().unwrap();
    let accounts = open_accounts(&directory, &claude_test).await;
    accounts.refreshing.send_modify(|owners| {
        owners.insert("round".to_owned());
    });
    let started = Instant::now();
    accounts.refresh_settled(Duration::from_millis(100)).await;
    assert!(started.elapsed() >= Duration::from_millis(100));
    assert!(accounts.directory().await.refreshing);
}

#[tokio::test]
async fn reset_refresh_coalesces_and_hides_observations_from_an_older_in_flight_read() {
    let claude_test = crate::providers::claude::settings::ClaudeSettings::isolated_for_test();
    let directory = tempfile::tempdir().unwrap();
    let accounts = open_accounts(&directory, &claude_test).await;
    let key = super::types::DEFAULT_CODEX;
    let mut snapshot = accounts.directory().await.accounts.remove(0);
    snapshot.stale = false;
    snapshot.resets = super::resets::from_router(Some(
        json!({"state":"known","available":1,"observed_at":"2026-10-17T07:00:00Z","offers":null,"error":null}),
    ));
    accounts
        .snapshots
        .write()
        .await
        .insert(key.into(), snapshot);
    accounts.refreshing.send_modify(|owners| {
        owners.insert(key.into());
    });
    accounts.refresh_reset_account(key.into());
    accounts.refresh_reset_account(key.into());
    let directory = accounts.directory().await;
    assert!(directory.accounts[0].resets.is_none());
    assert!(directory.accounts[0].stale);
    assert!(directory.refreshing);
    assert_eq!(accounts.refreshing.borrow().len(), 1);
    accounts.refreshing.send_modify(|owners| {
        owners.remove(key);
    });
    accounts.stop().await;
    assert!(accounts.refreshing.borrow().is_empty());
}
