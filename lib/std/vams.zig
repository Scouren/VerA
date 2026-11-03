//! The Verilog-AMS frontend shared by the compiler, the LSP and the runtime
//! readers: Zig's `lib/std/zig` for VAMS (docs/rewrite/README.md). Source
//! text in; tokens, a preprocessed unit, a syntax tree out. Imports only
//! std. Re-exports only.
//!
//! Contents:
//! - `pub const tokenizer`, `pub const Token`, `pub const Tokenizer`
//! - `pub const Ast`, `pub const number_literal`
//! - `pub const Preprocessor`
//! - `pub const Diag`
//! - `pub const spice`
//! - `pub const Vir`, `pub const AstGen`

pub const tokenizer = @import("vams/tokenizer.zig");
pub const number_literal = @import("vams/number_literal.zig");
pub const Ast = @import("vams/Ast.zig");
pub const Preprocessor = @import("vams/Preprocessor.zig");
pub const Diag = @import("vams/Diag.zig");
pub const spice = @import("vams/spice.zig");
pub const Vir = @import("vams/Vir.zig");
pub const AstGen = @import("vams/AstGen.zig");
pub const Token = tokenizer.Token;
pub const Tokenizer = tokenizer.Tokenizer;

test {
    _ = tokenizer;
    _ = number_literal;
    _ = Ast;
    _ = Preprocessor;
    _ = Diag;
    _ = spice;
    _ = Vir;
    _ = AstGen;
}
