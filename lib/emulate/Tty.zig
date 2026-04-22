const Tty = @This();

const std = @import("std");
const posix = std.posix;
const assert = std.debug.assert;

const HANDLE = posix.STDIN_FILENO;

state: union(enum) {
    uninit,
    not_a_tty,
    /// Original `termios` state.
    modified: posix.termios,
    /// Original (and current) `termios` state.
    unmodified: posix.termios,
},

pub const uninit: Tty = .{ .state = .uninit };

pub fn init(tty: *Tty) error{TermiosFailed}!void {
    assert(tty.state == .uninit);
    const termios = posix.tcgetattr(HANDLE) catch |err| switch (err) {
        error.NotATerminal => {
            tty.state = .not_a_tty;
            return;
        },
        error.Unexpected => return error.TermiosFailed,
    };
    tty.state = .{ .unmodified = termios };
}

pub fn enableRawMode(tty: *Tty) error{TermiosFailed}!void {
    if (tty.state == .uninit)
        try tty.init();
    const termios = switch (tty.state) {
        .not_a_tty => return,
        .uninit, .modified => unreachable,
        .unmodified => |termios| termios,
    };
    try setTermios(applyRawMode(termios));
    tty.state = .{ .modified = termios };
}

pub fn disableRawMode(tty: *Tty) error{TermiosFailed}!void {
    const termios = switch (tty.state) {
        .not_a_tty => return,
        .uninit, .unmodified => unreachable,
        .modified => |termios| termios,
    };
    try setTermios(termios);
    tty.state = .{ .unmodified = termios };
}

fn applyRawMode(termios: posix.termios) posix.termios {
    var termios_raw = termios;
    termios_raw.lflag.ICANON = false;
    termios_raw.lflag.ECHO = false;
    return termios_raw;
}

fn setTermios(termios: posix.termios) error{TermiosFailed}!void {
    posix.tcsetattr(HANDLE, .NOW, termios) catch |err| switch (err) {
        // If stdin is not a terminal, we wouldn't have the termios value.
        error.NotATerminal => unreachable,
        error.Unexpected,
        error.ProcessOrphaned,
        => return error.TermiosFailed,
    };
}
