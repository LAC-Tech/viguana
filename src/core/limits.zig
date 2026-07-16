//! Hard limits to prevent re-allocation
//! In a bold, daring example of counter-YAGNIism, this is a struct.
//! All members have a default value, but one day it will be a zon file

pub const File = struct {
    /// I think this is neovim's `updatecount`
    // TODO: ludicrously small because I want to trigger bad behaviour ASAP
    new_chars_until_swap_write: usize = 8,

    /// I think this is neovim's `undolevels`
    // TODO: ludicrously small because I want to trigger bad behaviour ASAP
    inserts_and_undos_until_swap_write: usize = 8,
};

file: File = File{},
