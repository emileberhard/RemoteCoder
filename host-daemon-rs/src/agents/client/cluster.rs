use super::*;
use crate::wire::cluster::{AgentAddress, PROTOCOL};

#[derive(Clone, Debug, Subcommand)]
pub(crate) enum ClusterCommand {
    List {
        #[arg(long)]
        json: bool,
    },
    Issue {
        #[arg(long)]
        host: String,
        #[arg(long)]
        name: String,
        #[arg(long)]
        membership: String,
    },
    Accept {
        input: String,
    },
    Remove {
        host: String,
    },
    Add {
        host: String,
    },
    ResetIdentity,
}

fn target_host(target: &mut String) -> Option<String> {
    let (host, id) = target.split_once(':')?;
    if matches!(host, "automation" | "codex" | "claude") {
        return None;
    }
    let (host, id) = (host.to_owned(), id.to_owned());
    *target = id;
    Some(host)
}

pub(super) fn command_host(command: &mut AgentCommand) -> Result<Option<String>> {
    let (explicit, target) = match command {
        AgentCommand::Spawn(args) => (args.caller.host.clone(), args.resume.as_mut()),
        AgentCommand::Message(args) => (args.caller.host.clone(), Some(&mut args.target)),
        AgentCommand::Read { target, caller, .. } => (caller.host.clone(), Some(target)),
        AgentCommand::List(args) => (args.host.clone(), args.target.as_mut()),
        AgentCommand::Stop { target, host, .. } | AgentCommand::Items { target, host, .. } => {
            (host.clone(), Some(target))
        }
        AgentCommand::SetParent { agent, caller, .. } => (caller.host.clone(), Some(agent)),
        _ => (None, None),
    };
    let addressed = target.and_then(target_host);
    ensure!(
        explicit.is_none() || addressed.is_none() || explicit == addressed,
        "--host differs from the addressed host"
    );
    Ok(explicit.or(addressed))
}

pub(super) async fn resolve_command(
    endpoint: &mut Endpoint,
    command: &mut AgentCommand,
) -> Result<Option<String>> {
    let target = match command {
        AgentCommand::Spawn(args) => args.resume.as_mut(),
        AgentCommand::Message(args) if args.target != "parent" => Some(&mut args.target),
        AgentCommand::Read { target, .. } if target != "self" => Some(target),
        AgentCommand::List(args) => args.target.as_mut(),
        AgentCommand::Stop { target, .. } | AgentCommand::Items { target, .. } => Some(target),
        AgentCommand::SetParent { agent, .. } => Some(agent),
        _ => None,
    };
    let Some(target) = target else {
        return Ok(None);
    };
    let local = Endpoint {
        local: endpoint.local.clone(),
        host: None,
    };
    let resolved: Value = if endpoint.host.is_some() {
        rpc(
            endpoint,
            "agent/cluster/resolve",
            json!({"target":target,"local":true}),
        )
        .await?
    } else {
        rpc(&local, "agent/cluster/resolve", json!({"target":target})).await?
    };
    if endpoint.host.is_none() && resolved["local"] != true {
        endpoint.host = resolved["ownerHostId"].as_str().map(str::to_owned);
    }
    if resolved["kind"] == "native" {
        let thread = resolved["threadId"]
            .as_str()
            .context("native resolution has no thread")?
            .to_owned();
        *target = thread.clone();
        return Ok(Some(thread));
    }
    if JobId::try_from(target.clone()).is_err() {
        *target = resolved["jobId"]
            .as_str()
            .context("job resolution has no job")?
            .to_owned();
    }
    Ok(None)
}

pub(super) fn error_exit(error: &Value) -> i32 {
    crate::wire::cluster::ErrorClass::from_rpc(error).exit_code()
}

pub(super) async fn execute(endpoint: &Endpoint, command: ClusterCommand) -> Result<Value> {
    let local = Endpoint {
        local: endpoint.local.clone(),
        host: None,
    };
    match command {
        ClusterCommand::List { .. } => rpc(&local, "cluster/list", json!({})).await,
        ClusterCommand::Issue {
            host,
            name,
            membership,
        } => {
            rpc(
                &local,
                "cluster/issue",
                json!({"protocol":PROTOCOL,"for":host,"name":name,"membership":membership}),
            )
            .await
        }
        ClusterCommand::Accept { input } => {
            rpc(
                &local,
                "cluster/accept",
                serde_json::from_str::<Value>(&text(&input)?)?,
            )
            .await
        }
        ClusterCommand::Remove { host } => {
            let list: Value = rpc(&local, "cluster/list", json!({})).await?;
            let member = list["members"]
                .as_array()
                .context("cluster member list is unavailable")?
                .iter()
                .find(|row| row["hostId"] == host || row["name"] == host)
                .context("unknown member")?;
            rpc(&local,"cluster/remove",json!({"protocol":PROTOCOL,"host":member["hostId"],"membership":member["membership"]})).await
        }
        ClusterCommand::Add { host } => join(&local, &host).await,
        ClusterCommand::ResetIdentity => {
            rpc(
                &local,
                "cluster/reset-identity",
                json!({"protocol":PROTOCOL}),
            )
            .await
        }
    }
}

async fn ssh(host: &str, args: &[&str], input: Option<Value>) -> Result<Value> {
    ensure!(
        !host.is_empty()
            && !host.starts_with('-')
            && host.bytes().all(|byte| byte.is_ascii_alphanumeric()
                || matches!(byte, b'-' | b'_' | b'.' | b'@' | b':')),
        "invalid SSH host"
    );
    fn quote(value: &str) -> String {
        format!("'{}'", value.replace('\'', "'\\''"))
    }
    let remote = format!(
        "\"$HOME/localbin/remote-coder-gateway/remote-coder-codex-gateway\" agent cluster {}",
        args.iter()
            .map(|value| quote(value))
            .collect::<Vec<_>>()
            .join(" ")
    );
    let mut child = tokio::process::Command::new("ssh")
        .args([
            "-o",
            "BatchMode=yes",
            "-o",
            "ConnectTimeout=3",
            host,
            &remote,
        ])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true)
        .spawn()?;
    if let Some(value) = input {
        use tokio::io::AsyncWriteExt;
        child
            .stdin
            .take()
            .context("SSH stdin unavailable")?
            .write_all(&serde_json::to_vec(&value)?)
            .await?;
    } else {
        drop(child.stdin.take());
    }
    let output = tokio::time::timeout(std::time::Duration::from_secs(30), child.wait_with_output())
        .await??;
    ensure!(
        output.status.success(),
        "remote cluster command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    ensure!(
        output.stdout.len() <= 1024 * 1024,
        "remote cluster reply exceeds its capacity"
    );
    Ok(serde_json::from_slice(&output.stdout)?)
}

async fn cluster_at(
    endpoint: &Endpoint,
    remote: Option<&str>,
    args: &[&str],
    input: Option<Value>,
) -> Result<Value> {
    if let Some(host) = remote {
        return ssh(host, args, input).await;
    }
    match args[0] {
        "list" => rpc(endpoint, "cluster/list", json!({})).await,
        "issue" => {
            rpc(
                endpoint,
                "cluster/issue",
                json!({"protocol":PROTOCOL,"for":args[2],"name":args[4],"membership":args[6]}),
            )
            .await
        }
        "accept" => {
            rpc(
                endpoint,
                "cluster/accept",
                input.context("acceptance is required")?,
            )
            .await
        }
        _ => bail!("unsupported membership command"),
    }
}

async fn join(endpoint: &Endpoint, host: &str) -> Result<Value> {
    let local = cluster_at(endpoint, None, &["list"], None).await?;
    let remote = cluster_at(endpoint, Some(host), &["list"], None).await.map_err(|error| RpcFailure(json!({"class":"unavailable","message":error.to_string(),"pairs":[{"right":host,"state":"unavailable"}]})))?;
    let local_id = local["self"]["hostId"]
        .as_str()
        .context("local identity missing")?
        .to_owned();
    let remote_id = remote["self"]["hostId"]
        .as_str()
        .context("remote identity missing")?
        .to_owned();
    let mut participants = std::collections::BTreeMap::<String, (String, Option<String>)>::new();
    for list in [&local, &remote] {
        for member in list["members"]
            .as_array()
            .context("member list missing")?
            .iter()
            .filter(|member| member["state"] == "active")
        {
            let id = member["hostId"]
                .as_str()
                .context("member identity missing")?
                .to_owned();
            let name = member["name"]
                .as_str()
                .context("member SSH route missing")?
                .to_owned();
            participants.insert(id, (name.clone(), Some(name)));
        }
    }
    participants.insert(
        local_id,
        (
            local["self"]["name"]
                .as_str()
                .context("local name missing")?
                .into(),
            None,
        ),
    );
    participants.insert(
        remote_id,
        (
            remote["self"]["name"]
                .as_str()
                .context("remote name missing")?
                .into(),
            Some(host.into()),
        ),
    );
    let participants = participants.into_iter().collect::<Vec<_>>();
    let mut pairs = Vec::new();
    let mut incomplete = false;
    for (index, (left_id, (left_name, left_route))) in participants.iter().enumerate() {
        for (right_id, (right_name, right_route)) in &participants[index + 1..] {
            let result=async {
                let left=cluster_at(endpoint,left_route.as_deref(),&["list"],None).await?;
                let right=cluster_at(endpoint,right_route.as_deref(),&["list"],None).await?;
                let find=|list:&Value,id:&str|list["members"].as_array().and_then(|rows|rows.iter().find(|row|row["hostId"]==id && row["state"]=="active")).cloned();
                let previous_left=find(&left,right_id);
                let previous_right=find(&right,left_id);
                if previous_left.as_ref().is_some_and(|row|row["routes"].as_array().is_some_and(|routes|!routes.is_empty())) && previous_right.as_ref().is_some_and(|row|row["routes"].as_array().is_some_and(|routes|!routes.is_empty())) {return Ok::<_,anyhow::Error>(json!({"state":"already_joined"}));}
                let membership=previous_left.as_ref().or(previous_right.as_ref()).and_then(|row|row["membership"].as_str()).map(str::to_owned).unwrap_or_else(crate::ids::new_session_uuid);
                ensure!(previous_right.as_ref().and_then(|row|row["membership"].as_str()).is_none_or(|id|id==membership),"pair has conflicting memberships");
                let issued=cluster_at(endpoint,left_route.as_deref(),&["issue","--host",right_id,"--name",right_name,"--membership",&membership],None).await?;
                let received=cluster_at(endpoint,right_route.as_deref(),&["issue","--host",left_id,"--name",left_name,"--membership",&membership],None).await?;
                let acceptance=|receipt:&Value,name:&str|json!({"protocol":PROTOCOL,"host":receipt["host"],"name":name,"membership":membership,"pin":receipt["pin"],"routes":receipt["routes"],"credential":receipt["credential"]});
                cluster_at(endpoint,left_route.as_deref(),&["accept","-"],Some(acceptance(&received,right_name))).await?;
                cluster_at(endpoint,right_route.as_deref(),&["accept","-"],Some(acceptance(&issued,left_name))).await?;
                Ok(json!({"state":"joined","membership":membership}))
            }.await;
            match result {
                Ok(result) => pairs.push(json!({"left":left_id,"right":right_id,"result":result})),
                Err(error) => {
                    incomplete = true;
                    pairs.push(json!({"left":left_id,"right":right_id,"state":"unavailable","error":error.to_string()}));
                }
            }
        }
    }
    if incomplete {
        return Err(RpcFailure(json!({"class":"unavailable","message":"cluster Join has unfinished pairs; rerun to finish","pairs":pairs})).into());
    }
    Ok(json!({"pairs":pairs}))
}

pub(super) async fn set_parent(
    endpoint: &Endpoint,
    agent: &str,
    parent: &str,
    args: CallerArgs,
) -> Result<Value> {
    let thread = if JobId::try_from(agent.to_owned()).is_ok() {
        let view = read(endpoint, agent).await?;
        let ConversationBinding::Known { conversation } = view
            .agent
            .context("agent has no conversation")?
            .conversation
        else {
            bail!("agent conversation is unresolved")
        };
        conversation.thread_id
    } else {
        agent.to_owned()
    };
    let local = Endpoint {
        local: endpoint.local.clone(),
        host: None,
    };
    let cluster: Value = rpc(&local, "cluster/list", json!({})).await?;
    let local_id = cluster["self"]["hostId"]
        .as_str()
        .context("host identity unavailable")?;
    let host_id = match &endpoint.host {
        None => local_id.to_owned(),
        Some(host) => cluster["members"]
            .as_array()
            .context("members unavailable")?
            .iter()
            .find(|row| row["hostId"] == *host || row["name"] == *host)
            .context("unknown member")?["hostId"]
            .as_str()
            .context("member identity unavailable")?
            .to_owned(),
    };
    let caller = caller(&local, &args).await?;
    let parent = if parent == "none" {
        None
    } else if parent == "current" {
        let context: ContextView = rpc(
            &local,
            "agent/context/read",
            ContextReadParams {
                caller: caller.clone(),
            },
        )
        .await?;
        Some(AgentAddress {
            host_id: local_id.to_owned(),
            thread_id: context.conversation.thread_id,
        })
    } else {
        let mut target = parent.to_owned();
        let alias = target_host(&mut target);
        let target_endpoint = Endpoint {
            local: endpoint.local.clone(),
            host: alias,
        };
        let resolved: Value = rpc(
            &target_endpoint,
            "agent/cluster/resolve",
            json!({"target":target,"local":target_endpoint.host.is_some()}),
        )
        .await?;
        let address: AgentAddress =
            serde_json::from_value(resolved["address"].clone()).or_else(|_| {
                let conversation = &resolved["conversation"]["conversation"];
                Ok::<_, serde_json::Error>(AgentAddress {
                    host_id: resolved["ownerHostId"].as_str().unwrap_or_default().into(),
                    thread_id: resolved["threadId"]
                        .as_str()
                        .or_else(|| conversation["threadId"].as_str())
                        .unwrap_or_default()
                        .into(),
                })
            })?;
        ensure!(
            !address.host_id.is_empty() && !address.thread_id.is_empty(),
            "parent has no bound provider conversation"
        );
        Some(address)
    };
    rpc(
        endpoint,
        "agent/parent/set",
        json!({"agent":{"hostId":host_id,"threadId":thread},"parent":parent,"caller":caller}),
    )
    .await
}

pub(super) async fn native_operation(
    endpoint: &Endpoint,
    thread: &str,
    command: AgentCommand,
    message: Option<String>,
) -> Result<Value> {
    let (action, args, extra) = match command {
        AgentCommand::Read { caller, .. } => ("read", Some(caller), json!({})),
        AgentCommand::Items { .. } => ("items", None, json!({})),
        AgentCommand::Stop { mutation_id, .. } => (
            "stop",
            None,
            json!({"mutationId":mutation_id.unwrap_or_else(crate::ids::new_session_uuid)}),
        ),
        AgentCommand::Message(args) => (
            "message",
            Some(args.caller),
            json!({"text":message.context("message body unavailable")?,"deliveryId":args.delivery_id.unwrap_or_else(crate::ids::new_session_uuid)}),
        ),
        AgentCommand::Spawn(args) => (
            "continue",
            Some(args.caller),
            json!({"text":text(&args.provider_or_prompt)?}),
        ),
        AgentCommand::List(_) => ("read", None, json!({})),
        _ => bail!("unsupported native conversation operation"),
    };
    let caller = match args {
        Some(args) => caller(endpoint, &args).await?,
        None => Caller::Operator,
    };
    rpc(
        endpoint,
        "agent/conversation/operate",
        json!({"threadId":thread,"action":action,"caller":caller,"input":extra}),
    )
    .await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn claude_sidecars_keep_their_provider_namespace() {
        let id = "claude:11111111-2222-4333-8444-555555555555:a123456";
        let mut target = id.to_owned();
        assert_eq!(target_host(&mut target), None);
        assert_eq!(target, id);
        let mut addressed = format!("host-a:{id}");
        assert_eq!(target_host(&mut addressed), Some("host-a".into()));
        assert_eq!(addressed, id);
    }
}
