//! Neovim as the editor engine. `rpc` frames messages and `grid` turns `redraw` notifications into a
//! screen (pure, tested exactly on every system); `client` runs `nvim --embed` and attaches as its UI.

pub mod client;
pub mod grid;
pub mod rpc;
