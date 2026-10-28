use super::*;

impl Gateway {
    pub(super) async fn native_conversation_operation(
        &self,
        request: Value,
        caller: Caller,
    ) -> Result<Value> {
        let thread = request["threadId"]
            .as_str()
            .context("threadId is required")?;
        let conversation = self.agent_conversation(thread)?;
        let origin = self.resolve_job_caller(&caller).await?;
        ensure!(
            !matches!(origin, Origin::Unknown { .. }),
            "caller is unproven"
        );
        let action = request["action"].as_str().context("action is required")?;
        if matches!(action, "message" | "stop" | "continue") {
            self.authorize_conversation(&caller, &conversation).await?;
        }
        match action {
            "read"=> {
                let mut result=if conversation.provider==crate::agents::jobs::model::Provider::Claude {self.claude_thread_response(&json!({"threadId":thread})).await?}else{self.job_native_call("thread/read",json!({"threadId":thread,"includeTurns":false})).await?};
                self.apply_parent_tags(&mut result).await?;
                Ok(result)
            }
            "items"=>self.cluster_history_page("thread/items/list",json!({"threadId":thread,"limit":100,"sortDirection":"asc"})).await,
            "message"=> {
                let delivery_id=request["input"]["deliveryId"].as_str().context("deliveryId is required")?.to_owned();
                let text=request["input"]["text"].as_str().context("text is required")?.to_owned();
                self.job_message(agent_jobs::MessageParams {target:agent_jobs::MessageTarget::Conversation {conversation},caller,delivery_id,text}).await.map_err(Into::into)
            }
            "stop"=> {
                if conversation.provider==crate::agents::jobs::model::Provider::Claude {
                    let turn=self.claude_active_turn_id(thread).await.context("conversation has no known active turn")?;
                    self.stop_claude_turn(thread,&turn).await?;
                    Ok(json!({"stopped":true,"threadId":thread,"turnId":turn}))
                } else {
                    let turn=self.latest_codex_turn(thread,Some(std::time::Duration::from_secs(3))).await?.context("conversation has no known active turn")?;
                    let turn=turn["id"].as_str().context("active turn has no identity")?;
                    self.interrupt_codex_turn(json!({"threadId":thread,"turnId":turn})).await.map_err(Into::into)
                }
            }
            "continue"=>Err(cluster_error(ErrorClass::Unsupported,"native conversation permission evidence is unavailable; continue through its owning native client").into()),
            _=>Err(cluster_error(ErrorClass::Usage,"unsupported native conversation action").into()),
        }
    }

    pub(in crate::gateway) async fn cluster_history_page(
        &self,
        method: &str,
        params: Value,
    ) -> Result<Value> {
        let thread = params["threadId"]
            .as_str()
            .context("threadId is required")?
            .to_owned();
        if self.agent_conversation(&thread)?.provider == crate::agents::jobs::model::Provider::Codex
        {
            return self.job_native_call(method, params).await;
        }
        let request = if method == "thread/items/list" {
            crate::rpc::HistoryPageRequest::Items(decode(params)?)
        } else {
            crate::rpc::HistoryPageRequest::Turns(decode(params)?)
        };
        let active = self.claude_active_turn_id(&thread).await;
        let (page, _) = self
            .claude_history
            .read_projection(&thread, active, move |projection, file, _| match &request {
                crate::rpc::HistoryPageRequest::Items(params) => {
                    projection.items_page(file, params)
                }
                crate::rpc::HistoryPageRequest::Turns(params) => {
                    projection.turns_page(file, params)
                }
            })
            .await?;
        Ok(page)
    }
}
