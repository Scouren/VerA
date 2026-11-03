//! The Verilog-AMS frontend shared by the compiler, the LSP and the runtime
//! readers: Zig's `lib/std/zig` for VAMS (docs/rewrite/README.md). Source
//! text in; tokens, a preprocessed unit, a syntax tree out. Imports only
//! std. Re-exports only.
//!
//! Contents:
//! - `pub const tokenizer`, `pub const Token`, `pub const Tokenizer`
//! - `pub const Ast`
//! - `pub const Preprocessor`

pub const tokenizer = @import("vams/tokenizer.zig");
pub const Ast = @import("vams/Ast.zig");
pub const Preprocessor = @import("vams/Preprocessor.zig");
pub const Token = tokenizer.Token;
pub const Tokenizer = tokenizer.Tokenizer;

test {
    _ = tokenizer;
    _ = Ast;
    _ = Preprocessor;
}
