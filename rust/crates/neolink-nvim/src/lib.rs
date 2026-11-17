//! Neovim as the editor engine. Nothing here opens a window or a process: `rpc` frames messages and
//! `grid` turns `redraw` notifications into a screen, so both can be tested exactly on every system.

pub mod grid;
pub mod rpc;
