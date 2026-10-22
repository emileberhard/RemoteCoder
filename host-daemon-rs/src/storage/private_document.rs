use std::marker::PhantomData;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use anyhow::{Context, Result, anyhow};
use serde::Serialize;
use serde::de::DeserializeOwned;
use tokio::sync::Semaphore;

use super::private_state::{self, ReadError};

pub(crate) trait PrivateDocument: Serialize + DeserializeOwned + Send + 'static {
    const NAME: &'static str;
    const MAXIMUM_BYTES: u64;

    fn empty() -> Self;
    fn validate(&self) -> Result<()>;
}

pub(crate) struct PrivateDocumentStore<D> {
    path: PathBuf,
    admission: Arc<Semaphore>,
    document: PhantomData<fn() -> D>,
}

impl<D> Clone for PrivateDocumentStore<D> {
    fn clone(&self) -> Self {
        Self {
            path: self.path.clone(),
            admission: Arc::clone(&self.admission),
            document: PhantomData,
        }
    }
}

impl<D: PrivateDocument> PrivateDocumentStore<D> {
    pub(crate) fn new(path: PathBuf) -> Self {
        Self {
            path,
            admission: Arc::new(Semaphore::new(1)),
            document: PhantomData,
        }
    }

    pub(crate) async fn transaction<T: Send + 'static>(
        &self,
        operation: impl FnOnce(&mut D) -> Result<(T, bool)> + Send + 'static,
    ) -> Result<T> {
        let path = self.path.clone();
        let permit = Arc::clone(&self.admission).acquire_owned().await?;
        tokio::task::spawn_blocking(move || {
            let _permit = permit;
            private_state::transaction(
                &path,
                "private document path has no parent",
                load::<D>,
                operation,
                private_state::write_json,
            )
        })
        .await
        .with_context(|| format!("{} worker failed", D::NAME))?
    }
}

fn load<D: PrivateDocument>(path: &Path) -> Result<D> {
    let bytes =
        private_state::read_bounded(path, D::MAXIMUM_BYTES).map_err(|error| match error {
            ReadError::Io(error) => anyhow::Error::from(error),
            ReadError::NotRegular => anyhow!("{} must be a regular file", D::NAME),
            ReadError::TooLargeBeforeRead | ReadError::TooLargeAfterRead => {
                anyhow!("{} file exceeds its size limit", D::NAME)
            }
        })?;
    let Some(bytes) = bytes else {
        return Ok(D::empty());
    };
    let document = serde_json::from_slice::<D>(&bytes)
        .with_context(|| format!("unreadable {}; original preserved", D::NAME))?;
    document.validate()?;
    Ok(document)
}
