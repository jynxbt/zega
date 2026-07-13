//! Longer sample for connection routing (multiple call edges).
const std = @import("std");

pub fn main() !void {
    const cfg = loadConfig();
    var app = App.init(cfg);
    defer app.deinit();
    try app.run();
    try reportSummary(app.stats());
}

fn loadConfig() Config {
    return .{
        .verbose = true,
        .max_iters = 128,
        .label = "zega-demo",
    };
}

pub const Config = struct {
    verbose: bool = false,
    max_iters: u32 = 64,
    label: []const u8 = "default",
};

pub const Stats = struct {
    steps: u32 = 0,
    errors: u32 = 0,

    pub fn ok(self: Stats) bool {
        return self.errors == 0;
    }
};

pub const App = struct {
    cfg: Config,
    steps: u32 = 0,
    errors: u32 = 0,

    pub fn init(cfg: Config) App {
        return .{ .cfg = cfg };
    }

    pub fn deinit(self: *App) void {
        _ = self;
    }

    pub fn run(self: *App) !void {
        var i: u32 = 0;
        while (i < self.cfg.max_iters) : (i += 1) {
            try self.stepOnce(i);
        }
        if (self.cfg.verbose) {
            logStep("run complete", self.steps);
        }
    }

    pub fn stepOnce(self: *App, idx: u32) !void {
        self.steps += 1;
        if (idx % 17 == 0) {
            try self.handleOdd(idx);
        } else {
            self.handleEven(idx);
        }
    }

    fn handleOdd(self: *App, idx: u32) !void {
        if (idx == 0) return error.BadIndex;
        self.errors += 0;
        logStep("odd", idx);
    }

    fn handleEven(self: *App, idx: u32) void {
        _ = self;
        logStep("even", idx);
    }

    pub fn stats(self: *const App) Stats {
        return .{ .steps = self.steps, .errors = self.errors };
    }
};

fn reportSummary(s: Stats) !void {
    if (!s.ok()) return error.HadErrors;
    logStep("summary steps", s.steps);
}

fn logStep(tag: []const u8, n: u32) void {
    std.debug.print("{s}: {d}\n", .{ tag, n });
}
