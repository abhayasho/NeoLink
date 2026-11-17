//! Platform-independent logic shared by every NeoLink front end.
//!
//! Nothing here touches a window, a GPU or a clock: times are passed in as seconds on one
//! monotonic timeline, so every rule can be tested exactly.

pub mod analysis;
pub mod pacer;
pub mod profile;
pub mod scroll;
pub mod stats;
pub mod tree;
