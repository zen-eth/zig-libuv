const std = @import("std");

/// Directories with our includes.
const root = thisDir() ++ "/vendor/libuv/";
const include_path = root ++ "include";

pub const pkg = .{
    .name = "libuv",
    .source = .{ .path = thisDir() ++ "/src/main.zig" },
};

fn thisDir() []const u8 {
    return std.fs.path.dirname(@src().file) orelse ".";
}

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create module
    const module = b.addModule("libuv", .{
        .link_libc = true,
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.addIncludePath(.{ .cwd_relative = include_path });

    const tests = b.addTest(.{
        .name = "pixman-test",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const lib = try link(b, tests);
    b.installArtifact(lib);
    b.installArtifact(tests);

    const test_step = b.step("test", "Run tests");
    const tests_run = b.addRunArtifact(tests);
    test_step.dependOn(&tests_run.step);
}

pub fn link(b: *std.Build, step: *std.Build.Step.Compile) !*std.Build.Step.Compile {
    const libuv = try buildLibuv(b, step);
    step.linkLibrary(libuv);
    step.addIncludePath(.{ .cwd_relative = include_path });
    return libuv;
}

pub fn buildLibuv(
    b: *std.Build,
    step: *std.Build.Step.Compile,
) !*std.Build.Step.Compile {
    const target = step.root_module.resolved_target.?;
    const lib = b.addStaticLibrary(.{
        .name = "uv",
        .target = target,
        .optimize = step.root_module.optimize.?,
    });

    // Include dirs
    lib.addIncludePath(.{ .cwd_relative = include_path });
    lib.addIncludePath(.{ .cwd_relative = root ++ "src" });

    // Links
    if (target.result.os.tag == .windows) {
        lib.linkSystemLibrary("psapi");
        lib.linkSystemLibrary("user32");
        lib.linkSystemLibrary("advapi32");
        lib.linkSystemLibrary("iphlpapi");
        lib.linkSystemLibrary("userenv");
        lib.linkSystemLibrary("ws2_32");
    }
    if (target.result.os.tag == .linux) {
        lib.linkSystemLibrary("pthread");
    }
    lib.linkLibC();

    // Compilation
    var flags = std.ArrayList([]const u8).init(b.allocator);
    defer flags.deinit();
    // try flags.appendSlice(&.{});

    if (target.result.os.tag != .windows) {
        try flags.appendSlice(&.{
            "-D_FILE_OFFSET_BITS=64",
            "-D_LARGEFILE_SOURCE",
        });
    }

    if (target.result.os.tag == .linux) {
        try flags.appendSlice(&.{
            "-D_GNU_SOURCE",
            "-D_POSIX_C_SOURCE=200112",
        });
    }

    if (target.result.os.tag == .macos) {
        try flags.appendSlice(&.{
            "-D_DARWIN_UNLIMITED_SELECT=1",
            "-D_DARWIN_USE_64_BIT_INODE=1",
        });
    }

    // C files common to all platforms
    lib.addCSourceFiles(.{
        .files = &.{
            root ++ "src/fs-poll.c",
            root ++ "src/idna.c",
            root ++ "src/inet.c",
            root ++ "src/random.c",
            root ++ "src/strscpy.c",
            root ++ "src/strtok.c",
            root ++ "src/threadpool.c",
            root ++ "src/timer.c",
            root ++ "src/uv-common.c",
            root ++ "src/uv-data-getter-setters.c",
            root ++ "src/version.c",
        },
        .flags = flags.items,
    });

    if (target.result.os.tag != .windows) {
        lib.addCSourceFiles(.{
            .files = &.{
                root ++ "src/unix/async.c",
                root ++ "src/unix/core.c",
                root ++ "src/unix/dl.c",
                root ++ "src/unix/fs.c",
                root ++ "src/unix/getaddrinfo.c",
                root ++ "src/unix/getnameinfo.c",
                root ++ "src/unix/loop-watcher.c",
                root ++ "src/unix/loop.c",
                root ++ "src/unix/pipe.c",
                root ++ "src/unix/poll.c",
                root ++ "src/unix/process.c",
                root ++ "src/unix/random-devurandom.c",
                root ++ "src/unix/signal.c",
                root ++ "src/unix/stream.c",
                root ++ "src/unix/tcp.c",
                root ++ "src/unix/thread.c",
                root ++ "src/unix/tty.c",
                root ++ "src/unix/udp.c",
            },
            .flags = flags.items,
        });
    }

    if (target.result.os.tag == .linux or target.result.os.tag == .macos) {
        lib.addCSourceFiles(.{
            .files = &.{
                root ++ "src/unix/proctitle.c",
            },
            .flags = flags.items,
        });
    }

    if (target.result.os.tag == .linux) {
        lib.addCSourceFiles(.{
            .files = &.{
                root ++ "src/unix/linux.c",
                root ++ "src/unix/procfs-exepath.c",
                root ++ "src/unix/random-getrandom.c",
                root ++ "src/unix/random-sysctl-linux.c",
            },
            .flags = flags.items,
        });
    }

    if (target.result.os.tag == .macos or
        target.result.os.tag == .openbsd or
        target.result.os.tag == .netbsd or
        target.result.os.tag == .freebsd or
        target.result.os.tag == .dragonfly)
    {
        lib.addCSourceFiles(.{
            .files = &.{
                root ++ "src/unix/bsd-ifaddrs.c",
                root ++ "src/unix/kqueue.c",
            },
            .flags = flags.items,
        });
    }

    if (target.result.os.tag == .macos or target.result.os.tag == .openbsd) {
        lib.addCSourceFiles(.{
            .files = &.{
                root ++ "src/unix/random-getentropy.c",
            },
            .flags = flags.items,
        });
    }

    if (target.result.os.tag == .macos) {
        lib.addCSourceFiles(.{
            .files = &.{
                root ++ "src/unix/darwin-proctitle.c",
                root ++ "src/unix/darwin.c",
                root ++ "src/unix/fsevents.c",
            },
            .flags = flags.items,
        });
    }

    return lib;
}
