//! POSIX PTY: open pair, fork zsh, non-blocking master I/O.
//! macOS / Linux only (v1).

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

// posix used for fd_t / pid_t types.
const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("signal.h");
    @cInclude("sys/ioctl.h");
    @cInclude("sys/wait.h");
    @cInclude("termios.h");
    // openpty lives in util.h on BSD/macOS and pty.h on Linux.
    if (builtin.os.tag == .macos) {
        @cInclude("util.h");
    } else {
        @cInclude("pty.h");
    }
});

pub const PtyError = error{
    OpenPtyFailed,
    ForkFailed,
    ExecFailed,
    IoError,
    NotAlive,
};

pub const Pty = struct {
    master_fd: posix.fd_t = -1,
    child_pid: posix.pid_t = -1,
    alive: bool = false,

    pub fn spawn(cols: u16, rows: u16, cwd: []const u8) PtyError!Pty {
        var master: c_int = -1;
        var slave: c_int = -1;
        var win: c.struct_winsize = .{
            .ws_row = rows,
            .ws_col = cols,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };

        if (c.openpty(&master, &slave, null, null, &win) != 0) {
            return error.OpenPtyFailed;
        }

        const pid = c.fork();
        if (pid < 0) {
            _ = c.close(master);
            _ = c.close(slave);
            return error.ForkFailed;
        }

        if (pid == 0) {
            // ── child ──────────────────────────────────────────────────
            _ = c.close(master);
            // Create new session and take controlling tty.
            _ = c.setsid();
            _ = c.ioctl(slave, c.TIOCSCTTY, @as(c_int, 0));
            _ = c.dup2(slave, c.STDIN_FILENO);
            _ = c.dup2(slave, c.STDOUT_FILENO);
            _ = c.dup2(slave, c.STDERR_FILENO);
            if (slave > 2) _ = c.close(slave);

            // Working directory.
            if (cwd.len > 0) {
                var path_buf: [std.fs.max_path_bytes]u8 = undefined;
                if (cwd.len < path_buf.len) {
                    @memcpy(path_buf[0..cwd.len], cwd);
                    path_buf[cwd.len] = 0;
                    _ = c.chdir(&path_buf);
                }
            }

            // Ensure a usable TERM for color prompts.
            _ = c.setenv("TERM", "xterm-256color", 1);
            // Avoid bracketed-paste surprises on some configs — leave default.

            // Interactive zsh.
            const argv = [_:null]?[*:0]const u8{ "zsh", "-i" };
            _ = c.execvp("zsh", @ptrCast(&argv));
            // Fallback absolute path.
            const argv2 = [_:null]?[*:0]const u8{ "/bin/zsh", "-i" };
            _ = c.execv("/bin/zsh", @ptrCast(&argv2));
            // If exec fails, exit hard (can't use Zig allocator after fork).
            _ = c._exit(127);
        }

        // ── parent ─────────────────────────────────────────────────────
        _ = c.close(slave);

        // Non-blocking master.
        const flags = c.fcntl(master, c.F_GETFL, @as(c_int, 0));
        if (flags >= 0) {
            _ = c.fcntl(master, c.F_SETFL, flags | c.O_NONBLOCK);
        }

        // Reinforce winsize (some platforms need it after fork).
        _ = c.ioctl(master, c.TIOCSWINSZ, &win);

        return .{
            .master_fd = master,
            .child_pid = pid,
            .alive = true,
        };
    }

    pub fn deinit(self: *Pty) void {
        self.kill();
        if (self.master_fd >= 0) {
            _ = c.close(self.master_fd);
            self.master_fd = -1;
        }
        self.* = .{};
    }

    /// Non-blocking read into `buf`. Returns bytes read, 0 if would-block, null on EOF/error.
    pub fn read(self: *Pty, buf: []u8) ?usize {
        if (!self.alive or self.master_fd < 0) return null;
        const n = c.read(self.master_fd, buf.ptr, buf.len);
        if (n > 0) return @intCast(n);
        if (n == 0) {
            // EOF — child closed.
            self.markDead();
            return null;
        }
        // n < 0 — check libc errno (values from errno.h via std.c.E).
        const err = std.posix.errno(@as(isize, -1));
        if (err == .AGAIN) return 0;
        // EIO often means child exited on some platforms.
        self.markDead();
        return null;
    }

    pub fn writeAll(self: *Pty, bytes: []const u8) void {
        if (!self.alive or self.master_fd < 0 or bytes.len == 0) return;
        var off: usize = 0;
        while (off < bytes.len) {
            const n = c.write(self.master_fd, bytes.ptr + off, bytes.len - off);
            if (n > 0) {
                off += @intCast(n);
                continue;
            }
            if (n < 0) {
                const err = std.posix.errno(@as(isize, -1));
                if (err == .AGAIN) {
                    // Drop remaining on full buffer rather than block the UI.
                    return;
                }
                self.markDead();
                return;
            }
            return;
        }
    }

    pub fn kill(self: *Pty) void {
        if (self.child_pid > 0) {
            _ = c.kill(self.child_pid, c.SIGHUP);
            // Brief non-blocking reaps; if still alive, SIGKILL.
            var status: c_int = 0;
            const r = c.waitpid(self.child_pid, &status, c.WNOHANG);
            if (r == 0) {
                _ = c.kill(self.child_pid, c.SIGKILL);
                _ = c.waitpid(self.child_pid, &status, 0);
            }
            self.child_pid = -1;
        }
        self.alive = false;
    }

    pub fn pollChild(self: *Pty) void {
        if (!self.alive or self.child_pid <= 0) return;
        var status: c_int = 0;
        const r = c.waitpid(self.child_pid, &status, c.WNOHANG);
        if (r == self.child_pid) {
            self.child_pid = -1;
            self.alive = false;
        } else if (r < 0) {
            self.alive = false;
            self.child_pid = -1;
        }
    }

    fn markDead(self: *Pty) void {
        self.alive = false;
        self.pollChild();
    }
};
