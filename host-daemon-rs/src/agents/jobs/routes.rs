mod native;
mod scoped;

pub(crate) use native::{NativeDeliveryState, NativeMessage, NativeRoutes};
pub(crate) use scoped::{
    ScopedEndpointLease, ScopedEndpoints, ScopedHandler, is_legacy_socket, legacy_socket,
    scoped_socket,
};

#[cfg(all(test, target_os = "macos"))]
mod tests;
