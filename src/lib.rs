//! lbx: the llm-in-a-box launcher, ported from bash.
//!
//! The library holds everything that returns plain data (argument parsing,
//! config resolution, docker argument vectors, status lines); the `lbx`
//! binary is a thin shell over it.

pub mod assets;
pub mod cli;
pub mod config;
pub mod docker;
pub mod migrate;
pub mod netpolicy;
pub mod run;
pub mod session;
pub mod status;
pub mod util;
pub mod vm;
