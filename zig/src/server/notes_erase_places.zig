//! Where an erased note may still be outside the store and its journal, as the erase reply names them.
const std = @import("std");
const Server = @import("server.zig").Server;

/// A place outside the store and the journal that can hold a note's text or tokens.
pub const Place = enum {
    prompt_cache,
    learn_files,
    responses,
    cortheon,
    compaction_memory,
    request_log,
    promotion,
    requests,

    /// What may still hold the note there, said to the client.
    pub fn why(p: Place) []const u8 {
        return switch (p) {
            .prompt_cache => "the engine's prompt cache may still hold prompt states (and their tokens) of requests that carried this note's block; serve with --prompt-cache-gib 0 for an erase that reaches every cache",
            .learn_files => "--learn keeps shared prompt states on disk, and the notes block lies inside a shared system block, so a learned state file may hold this note's tokens",
            .responses => "stored Responses (/v1/responses with store) keep their conversations in memory, and one may quote this note",
            .cortheon => "Cortheon keeps the hidden rounds of its replies in memory, and one may quote this note",
            .compaction_memory => "--compact-memory keeps compacted conversations' memory notes on disk, and one may quote this note",
            .request_log => "TENSORFOLD_REQUEST_LOG appends every chat body to the operator's file, the statement that taught this note among them",
            .promotion => "Sliding Weights (--slide or its fact graph) keeps taught facts' text in its fact graph and their recall in the served weights, and one may be this note",
            .requests => "the engine is running or queueing requests now, and one may carry this note in its prompt or its reply; they are not cancelled",
        };
    }
};

/// How a place stands for this erase: it may hold the note, or the server can show it does not. Only a place
/// shown off or empty counts as clear; anything the server cannot show stays may_hold.
pub const Status = enum { may_hold, off, empty };

/// Each place's status, by the server's own flags and stores now.
pub fn check(srv: *Server) std.EnumArray(Place, Status) {
    var out: std.EnumArray(Place, Status) = .initFill(.off);
    out.set(.prompt_cache, if (srv.info.prompt_cache) .may_hold else .off);
    out.set(.learn_files, if (srv.config.learn) .may_hold else .off);
    out.set(.responses, if (srv.store.count(srv.io) > 0) .may_hold else .empty); // always on: empty is what shows it holds nothing
    out.set(.cortheon, if (srv.cortheon) |c| (if (c.memory.count() > 0) .may_hold else .empty) else .off);
    out.set(.compaction_memory, if (srv.config.compact_memory != null) .may_hold else .off);
    out.set(.request_log, if (srv.config.request_log != null) .may_hold else .off);
    out.set(.promotion, if (srv.config.slide) .may_hold else if (srv.slide.count() > 0) .may_hold else .off);
    var engine: @import("engine_api").Status = .{};
    srv.engine.status(&engine, &.{});
    out.set(.requests, if (engine.running + engine.waiting > 0) .may_hold else .empty);
    return out;
}
