mod native;
mod scoped;

pub(crate) use native::{NativeDeliveryState, NativeMessage, NativeRoutes};
pub(crate) use scoped::{ScopedEndpointLease, ScopedEndpoints, ScopedHandler};

#[cfg(all(test, target_os = "macos"))]
mod tests;
