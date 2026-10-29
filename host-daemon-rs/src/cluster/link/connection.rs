use std::sync::Weak;

use tokio::sync::{mpsc, oneshot};
use tokio_util::task::AbortOnDropHandle;

use super::*;

struct Request {
    id: u64,
    text: String,
    receipt: oneshot::Sender<Result<Value>>,
}

pub(super) struct Connection {
    requests: mpsc::Sender<Request>,
    alive: Arc<AtomicBool>,
    _reader: AbortOnDropHandle<()>,
    pub(super) hello: HelloReceipt,
}

impl Connection {
    pub(super) fn new(
        socket: Socket,
        hello: HelloReceipt,
        slot: Weak<Mutex<Option<Self>>>,
    ) -> Self {
        let (requests, receiver) = mpsc::channel(1);
        let alive = Arc::new(AtomicBool::new(true));
        let reader = AbortOnDropHandle::new(tokio::spawn(read_socket(
            socket,
            receiver,
            alive.clone(),
            slot,
        )));
        Self {
            requests,
            alive,
            _reader: reader,
            hello,
        }
    }

    pub(super) fn is_alive(&self) -> bool {
        self.alive.load(Ordering::Acquire)
    }

    pub(super) async fn request(
        &self,
        id: u64,
        text: String,
        transmitted: Arc<AtomicBool>,
    ) -> Result<Value> {
        let (receipt, response) = oneshot::channel();
        let permit = self
            .requests
            .reserve()
            .await
            .map_err(|_| anyhow::anyhow!("member connection closed before transmission"))?;
        transmitted.store(true, Ordering::Release);
        permit.send(Request { id, text, receipt });
        response.await.context("member connection reader ended")?
    }
}

async fn read_socket(
    mut socket: Socket,
    mut requests: mpsc::Receiver<Request>,
    alive: Arc<AtomicBool>,
    slot: Weak<Mutex<Option<Connection>>>,
) {
    let mut pending: Option<Request> = None;
    let result: Result<()> = async {
        loop {
            tokio::select! {
                request = requests.recv(), if pending.is_none() => {
                    let request = request.context("member connection owner ended")?;
                    pending = Some(request);
                    let request = pending.as_mut().context("member request is pending")?;
                    socket.send(Message::Text(std::mem::take(&mut request.text))).await?;
                }
                message = socket.next() => {
                    match message.context("member closed before its receipt")?? {
                        Message::Text(text) => {
                            let response: Value = serde_json::from_str(&text)?;
                            if pending.as_ref().is_some_and(|request| response["id"].as_u64() == Some(request.id)) {
                                let request = pending.take().context("member request is pending")?;
                                let _ = request.receipt.send(receipt(response));
                            }
                        }
                        Message::Ping(value) => socket.send(Message::Pong(value)).await?,
                        Message::Close(_) => anyhow::bail!("member closed before its receipt"),
                        _ => {}
                    }
                }
            }
        }
    }.await;
    alive.store(false, Ordering::Release);
    let message = result.unwrap_err().to_string();
    if let Some(request) = pending {
        let _ = request.receipt.send(Err(anyhow::anyhow!(message.clone())));
    }
    requests.close();
    while let Ok(request) = requests.try_recv() {
        let _ = request.receipt.send(Err(anyhow::anyhow!(message.clone())));
    }
    if let Some(slot) = slot.upgrade() {
        let mut cached = slot.lock().await;
        if cached
            .as_ref()
            .is_some_and(|connection| Arc::ptr_eq(&connection.alive, &alive))
        {
            cached.take();
        }
    }
}
