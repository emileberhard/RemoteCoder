use crate::sessions::query;
use anyhow::{Context, Result, ensure};
use clap::{Args, Subcommand};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, Args)]
pub(crate) struct Command {
    #[arg(long, global = true)]
    database: Option<PathBuf>,
    #[arg(long, global = true)]
    local: bool,
    #[arg(long, global = true)]
    json: bool,
    #[command(subcommand)]
    operation: Operation,
}

#[derive(Clone, Debug, Subcommand)]
enum Operation {
    Conversations {
        query: String,
        #[arg(long, default_value_t = 30)]
        limit: usize,
    },
    Meaning {
        query: String,
        #[arg(long, default_value_t = 20)]
        limit: usize,
    },
    Locate {
        item_key: String,
    },
    Search {
        query: String,
        #[arg(long)]
        since: Option<String>,
        #[arg(long)]
        limit: Option<usize>,
        #[arg(long)]
        cursor: Option<String>,
    },
    Read {
        target: String,
        #[arg(long, default_value = "0:65536")]
        range: String,
        #[arg(long)]
        dependency: Option<String>,
    },
    Sql {
        sql: String,
    },
    Mirror {
        #[command(subcommand)]
        action: Mirror,
    },
}

#[derive(Clone, Debug, Subcommand)]
enum Mirror {
    Status,
}

fn since(value: Option<String>) -> Result<Option<String>> {
    value
        .map(|value| {
            if let Some(days) = value.strip_suffix('d') {
                let days: i64 = days.parse()?;
                ensure!(
                    (0..=36500).contains(&days),
                    "--since days must be 0..=36500"
                );
                Ok(
                    (::time::OffsetDateTime::now_utc() - ::time::Duration::days(days))
                        .format(&::time::format_description::well_known::Rfc3339)?,
                )
            } else {
                crate::sessions::timestamp(&value)
            }
        })
        .transpose()
}

fn request(command: &Command) -> Result<(&'static str, Value)> {
    Ok(match &command.operation {
        Operation::Conversations { query, limit } => (
            "sessions/conversations/search",
            serde_json::to_value(crate::sessions::conversations::Request {
                query: query.clone(),
                limit: *limit,
            })?,
        ),
        Operation::Meaning { query, limit } => (
            "sessions/conversations/searchByMeaning",
            json!({"query":query,"limit":limit}),
        ),
        Operation::Locate { item_key } => ("sessions/locate", json!({"itemKey":item_key})),
        Operation::Search {
            query,
            since: date,
            limit,
            cursor,
        } => (
            "sessions/search",
            serde_json::to_value(query::Search {
                query: query.clone(),
                since: since(date.clone())?,
                limit: *limit,
                cursor: cursor.clone(),
                local: command.local || command.database.is_some(),
            })?,
        ),
        Operation::Read {
            target,
            range,
            dependency,
        } => {
            let (offset, end) = range
                .split_once(':')
                .context("--range uses byte offsets START:END")?;
            let offset: u64 = offset.parse()?;
            let end: u64 = end.parse()?;
            ensure!(end > offset, "Range end must exceed its start");
            (
                "sessions/read",
                serde_json::to_value(query::ReadRequest {
                    target: target.clone(),
                    offset,
                    length: Some(usize::try_from(end - offset)?),
                    dependency: dependency.clone(),
                    local: command.local || command.database.is_some(),
                })?,
            )
        }
        Operation::Sql { sql } => ("sessions/sql", json!({"sql":sql})),
        Operation::Mirror { action } => match action {
            Mirror::Status => ("sessions/mirror/status", json!({})),
        },
    })
}

async fn execute(command: &Command, env_file: Option<&Path>) -> Result<Value> {
    let (method, params) = request(command)?;
    if command.local || command.database.is_some() {
        let path = command
            .database
            .clone()
            .map(Ok)
            .unwrap_or_else(crate::sessions::default_database)?;
        let mut db = crate::sessions::store::reader(&path)?;
        return match method {
            "sessions/conversations/search" => {
                let control = crate::sessions::store::ReadControl::new(
                    std::time::Instant::now() + crate::sessions::conversations::DEADLINE,
                );
                db.interrupt_on(control.clone())?;
                Ok(serde_json::to_value(
                    crate::sessions::conversations::search(
                        &db,
                        &serde_json::from_value(params)?,
                        &control,
                        &Default::default(),
                    )?,
                )?)
            }
            "sessions/search" => query::search(&db, &serde_json::from_value(params)?),
            "sessions/read" => query::read(&db, serde_json::from_value(params)?),
            "sessions/sql" => query::sql(&db, params["sql"].as_str().context("SQL missing")?),
            _ => anyhow::bail!(
                "Mirror control requires the local gateway; omit --local and --database"
            ),
        };
    }
    let paths = crate::config::HostPaths::from_env()?;
    let default_file = paths.state("codex-gateway.env");
    let sources = crate::config::ConfigSources::load(
        env_file.or_else(|| default_file.exists().then_some(default_file.as_path())),
    )?;
    let endpoint = crate::config::GatewayEndpoint::load(&sources)?;
    let response = super::transport::call(&endpoint, method, params).await?;
    if let Some(error) = response.get("error") {
        return Err(super::RpcFailure(error.clone()).into());
    }
    response
        .get("result")
        .cloned()
        .context("Gateway returned no session result")
}

pub(crate) async fn run(command: Command, env_file: Option<&Path>) -> Result<i32> {
    match execute(&command, env_file).await {
        Ok(value) => {
            println!(
                "{}",
                if command.json {
                    serde_json::to_string(&value)?
                } else {
                    serde_json::to_string_pretty(&value)?
                }
            );
            Ok(0)
        }
        Err(error) => {
            let (code, payload) = if let Some(failure) = error.downcast_ref::<super::RpcFailure>() {
                (
                    crate::sessions::exit_code(&failure.0["data"]),
                    failure.0.clone(),
                )
            } else {
                let data = crate::sessions::error_data(&error);
                (crate::sessions::exit_code(&data), data)
            };
            eprintln!(
                "{}",
                serde_json::to_string(&json!({"ok":false,"error":payload}))?
            );
            Ok(code)
        }
    }
}
