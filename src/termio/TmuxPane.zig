//! TmuxPane implements a termio backend for a tmux control mode pane.
//!
//! Unlike the Exec backend, this backend does not spawn a subprocess or
//! allocate a PTY. Instead, it reads terminal output from a pipe that is
//! fed by the tmux Viewer (running in another Surface's stream handler),
//! and forwards user input back to tmux via a write-back pipe so the
//! originating Surface can send `send-keys` commands.
const TmuxPane = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const xev = @import("../global.zig").xev;
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");
const internal_os = @import("../os/main.zig");
const crash = @import("../crash/main.zig");

const log = std.log.scoped(.io_tmux_pane);

/// The pipe fd used to receive tmux pane output.
/// The Viewer writes to the other end of this pipe.
output_read_fd: posix.fd_t,

/// The pipe fd the Viewer writes pane output to.
/// Stored here so we can close it on deinit.
output_write_fd: posix.fd_t,

/// The tmux pane ID this backend is associated with.
pane_id: u32,

pub fn init(
    _: Allocator,
    cfg: Config,
) !TmuxPane {
    return .{
        .output_read_fd = cfg.output_read_fd,
        .output_write_fd = cfg.output_write_fd,
        .pane_id = cfg.pane_id,
    };
}

pub fn deinit(self: *TmuxPane) void {
    // Close our end of the output pipe. The write end is owned
    // by whoever created us (the stream_handler).
    posix.close(self.output_read_fd);
    self.* = undefined;
}

pub fn initTerminal(self: *TmuxPane, term: *terminal.Terminal) void {
    _ = self;
    _ = term;
}

pub fn threadEnter(
    self: *TmuxPane,
    _: Allocator,
    io: *termio.Termio,
    td: *termio.Termio.ThreadData,
) !void {
    // Create a pipe for signaling the read thread to quit.
    const pipe = try internal_os.pipe();
    errdefer posix.close(pipe[0]);
    errdefer posix.close(pipe[1]);

    // Start the read thread that reads tmux pane output from
    // the pipe and feeds it to processOutput.
    const read_thread = try std.Thread.spawn(
        .{},
        ReadThread.threadMainPosix,
        .{ self.output_read_fd, io, pipe[0] },
    );
    read_thread.setName("tmux-pane-reader") catch {};

    td.backend = .{ .tmux_pane = .{
        .read_thread = read_thread,
        .read_thread_pipe = pipe[1],
    } };
}

pub fn threadExit(self: *TmuxPane, td: *termio.Termio.ThreadData) void {
    _ = self;
    const data = &td.backend.tmux_pane;

    // Signal the read thread to quit.
    _ = posix.write(data.read_thread_pipe, "x") catch |err| switch (err) {
        error.BrokenPipe => {},
        else => log.warn("error writing to read thread quit pipe err={}", .{err}),
    };
    data.read_thread.join();
}

pub fn focusGained(
    self: *TmuxPane,
    td: *termio.Termio.ThreadData,
    focused: bool,
) !void {
    _ = self;
    _ = td;
    _ = focused;
}

pub fn resize(
    self: *TmuxPane,
    grid_size: renderer.GridSize,
    screen_size: renderer.ScreenSize,
) !void {
    _ = self;
    _ = grid_size;
    _ = screen_size;
    // TODO: send tmux resize-pane command
}

pub fn queueWrite(
    self: *TmuxPane,
    alloc: Allocator,
    td: *termio.Termio.ThreadData,
    data: []const u8,
    linefeed: bool,
) !void {
    _ = self;
    _ = alloc;
    _ = td;
    _ = data;
    _ = linefeed;
    // TODO: forward as tmux send-keys to the originating surface
}

pub fn childExitedAbnormally(
    self: *TmuxPane,
    gpa: Allocator,
    t: *terminal.Terminal,
    exit_code: u32,
    runtime_ms: u64,
) !void {
    _ = self;
    _ = gpa;
    _ = t;
    _ = exit_code;
    _ = runtime_ms;
}

pub const Config = struct {
    /// The read end of the pipe for receiving tmux pane output.
    output_read_fd: posix.fd_t,

    /// The write end of the pipe (kept for lifecycle management).
    output_write_fd: posix.fd_t,

    /// The tmux pane ID.
    pane_id: u32,
};

pub const ThreadData = struct {
    read_thread: std.Thread,
    read_thread_pipe: posix.fd_t,

    pub fn deinit(self: *ThreadData, _: Allocator) void {
        posix.close(self.read_thread_pipe);
    }

    pub fn changeConfig(self: *ThreadData, config: *termio.DerivedConfig) void {
        _ = self;
        _ = config;
    }
};

/// The read thread reads from the pipe fd and feeds data to the terminal.
/// This is nearly identical to Exec.ReadThread but simplified (no Windows,
/// no termios polling).
const ReadThread = struct {
    fn threadMainPosix(fd: posix.fd_t, io: *termio.Termio, quit: posix.fd_t) void {
        defer posix.close(quit);

        crash.sentry.thread_state = .{
            .type = .io,
            .surface = io.surface_mailbox.surface,
        };
        defer crash.sentry.thread_state = null;

        // Set non-blocking so we can poll.
        if (posix.fcntl(fd, posix.F.GETFL, 0)) |flags| {
            _ = posix.fcntl(
                fd,
                posix.F.SETFL,
                flags | @as(u32, @bitCast(posix.O{ .NONBLOCK = true })),
            ) catch {};
        } else |_| {}

        var pollfds: [2]posix.pollfd = .{
            .{ .fd = fd, .events = posix.POLL.IN, .revents = undefined },
            .{ .fd = quit, .events = posix.POLL.IN, .revents = undefined },
        };

        var buf: [1024]u8 = undefined;
        while (true) {
            while (true) {
                const n = posix.read(fd, &buf) catch |err| {
                    switch (err) {
                        error.NotOpenForReading,
                        error.InputOutput,
                        => {
                            log.info("tmux pane reader exiting", .{});
                            return;
                        },
                        error.WouldBlock => break,
                        else => {
                            log.err("tmux pane reader error err={}", .{err});
                            return;
                        },
                    }
                };
                if (n == 0) break;

                @call(.always_inline, termio.Termio.processOutput, .{ io, buf[0..n] });
            }

            _ = posix.poll(&pollfds, -1) catch |err| {
                log.warn("poll failed on tmux pane read thread err={}", .{err});
                return;
            };

            if (pollfds[1].revents & posix.POLL.IN != 0) {
                log.info("tmux pane read thread got quit signal", .{});
                return;
            }
            if (pollfds[0].revents & posix.POLL.HUP != 0) {
                log.info("tmux pane pipe closed, read thread exiting", .{});
                return;
            }
        }
    }
};
