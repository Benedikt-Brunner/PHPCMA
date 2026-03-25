const std = @import("std");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.

    // Here we define an executable. An executable needs to have a root module
    // which needs to expose a `main` function. While we could add a main function
    // to the module defined above, it's sometimes preferable to split business
    // logic and the CLI into two separate modules.
    //
    // If your goal is to create a Zig library for others to use, consider if
    // it might benefit from also exposing a CLI tool. A parser library for a
    // data serialization format could also bundle a CLI syntax checker, for example.
    //
    // If instead your goal is to create an executable, consider if users might
    // be interested in also being able to embed the core functionality of your
    // program in their own executable in order to avoid the overhead involved in
    // subprocessing your CLI tool.
    //
    // If neither case applies to you, feel free to delete the declaration you
    // don't need and to put everything under a single module.
    const exe = b.addExecutable(.{
        .name = "PHPCMA",
        .root_module = b.createModule(.{
            // b.createModule defines a new module just like b.addModule but,
            // unlike b.addModule, it does not expose the module to consumers of
            // this package, which is why in this case we don't have to give it a name.
            .root_source_file = b.path("src/main.zig"),
            // Target and optimization levels must be explicitly wired in when
            // defining an executable or library (in the root module), and you
            // can also hardcode a specific target for an executable or library
            // definition if desireable (e.g. firmware for embedded devices).
            .target = target,
            .optimize = optimize,
            // List of modules available for import in source files part of the
            // root module.
        }),
    });

    // ----------------------------------------------------------------
    // 1. Setup the Zig Bindings (zig-tree-sitter)
    // ----------------------------------------------------------------
    const ts_dep = b.dependency("tree_sitter", .{
        .target = target,
        .optimize = optimize,
    });
    // Import the zig module
    exe.root_module.addImport("tree-sitter", ts_dep.module("tree_sitter"));

    // ----------------------------------------------------------------
    // 2. Setup the PHP Grammar (tree-sitter-php)
    // ----------------------------------------------------------------
    const php_dep = b.dependency("tree_sitter_php", .{});

    // The PHP repo structure is: root -> php -> src -> [parser.c, scanner.c]
    // We need to point specifically to that 'src' folder.
    // Note: We use .path("php/src") relative to the repo root.
    const php_src_root = php_dep.path("php/src");

    exe.addIncludePath(php_src_root);

    // Compile parser.c
    exe.addCSourceFile(.{
        .file = php_src_root.path(b, "parser.c"),
        .flags = &[_][]const u8{ "-std=c99", "-O3", "-fno-sanitize=undefined" },
    });

    // Compile scanner.c (Handles Heredocs etc)
    exe.addCSourceFile(.{
        .file = php_src_root.path(b, "scanner.c"),
        .flags = &[_][]const u8{ "-std=c99", "-O3", "-fno-sanitize=undefined" },
    });

    const cli_dep = b.dependency("cli", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("cli", cli_dep.module("cli"));
    // Link LibC (Required by Tree-sitter)
    exe.linkLibC();
    // This declares intent for the executable to be installed into the
    // install prefix when running `zig build` (i.e. when executing the default
    // step). By default the install prefix is `zig-out/` but can be overridden
    // by passing `--prefix` or `-p`.
    b.installArtifact(exe);

    // This creates a top level step. Top level steps have a name and can be
    // invoked by name when running `zig build` (e.g. `zig build run`).
    // This will evaluate the `run` step rather than the default step.
    // For a top level step to actually do something, it must depend on other
    // steps (e.g. a Run step, as we will see in a moment).
    const run_step = b.step("run", "Run the app");

    // This creates a RunArtifact step in the build graph. A RunArtifact step
    // invokes an executable compiled by Zig. Steps will only be executed by the
    // runner if invoked directly by the user (in the case of top level steps)
    // or if another step depends on it, so it's up to you to define when and
    // how this Run step will be executed. In our case we want to run it when
    // the user runs `zig build run`, so we create a dependency link.
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // By making the run step depend on the default step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // ----------------------------------------------------------------
    // Tests
    // ----------------------------------------------------------------
    const test_step = b.step("test", "Run unit tests");

    const main_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Add tree-sitter module
    main_tests.root_module.addImport("tree-sitter", ts_dep.module("tree_sitter"));

    // Add CLI module
    main_tests.root_module.addImport("cli", cli_dep.module("cli"));

    // Add PHP grammar C sources
    main_tests.addIncludePath(php_src_root);
    main_tests.addCSourceFile(.{
        .file = php_src_root.path(b, "parser.c"),
        .flags = &[_][]const u8{ "-std=c99", "-O3", "-fno-sanitize=undefined" },
    });
    main_tests.addCSourceFile(.{
        .file = php_src_root.path(b, "scanner.c"),
        .flags = &[_][]const u8{ "-std=c99", "-O3", "-fno-sanitize=undefined" },
    });
    main_tests.linkLibC();

    const run_main_tests = b.addRunArtifact(main_tests);
    test_step.dependOn(&run_main_tests.step);

    const report_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/report.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    report_tests.root_module.addImport("tree-sitter", ts_dep.module("tree_sitter"));
    report_tests.root_module.addImport("cli", cli_dep.module("cli"));
    report_tests.addIncludePath(php_src_root);
    report_tests.addCSourceFile(.{
        .file = php_src_root.path(b, "parser.c"),
        .flags = &[_][]const u8{ "-std=c99", "-O3", "-fno-sanitize=undefined" },
    });
    report_tests.addCSourceFile(.{
        .file = php_src_root.path(b, "scanner.c"),
        .flags = &[_][]const u8{ "-std=c99", "-O3", "-fno-sanitize=undefined" },
    });
    report_tests.linkLibC();
    const run_report_tests = b.addRunArtifact(report_tests);
    test_step.dependOn(&run_report_tests.step);

    const phpdoc_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/phpdoc.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_phpdoc_tests = b.addRunArtifact(phpdoc_tests);
    test_step.dependOn(&run_phpdoc_tests.step);

    const cfg_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cfg.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    cfg_tests.root_module.addImport("tree-sitter", ts_dep.module("tree_sitter"));
    cfg_tests.addIncludePath(php_src_root);
    cfg_tests.addCSourceFile(.{
        .file = php_src_root.path(b, "parser.c"),
        .flags = &[_][]const u8{ "-std=c99", "-O3", "-fno-sanitize=undefined" },
    });
    cfg_tests.addCSourceFile(.{
        .file = php_src_root.path(b, "scanner.c"),
        .flags = &[_][]const u8{ "-std=c99", "-O3", "-fno-sanitize=undefined" },
    });
    cfg_tests.linkLibC();

    const run_cfg_tests = b.addRunArtifact(cfg_tests);
    test_step.dependOn(&run_cfg_tests.step);

    const null_safety_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/null_safety.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    null_safety_tests.root_module.addImport("tree-sitter", ts_dep.module("tree_sitter"));
    null_safety_tests.root_module.addImport("cli", cli_dep.module("cli"));
    null_safety_tests.addIncludePath(php_src_root);
    null_safety_tests.addCSourceFile(.{
        .file = php_src_root.path(b, "parser.c"),
        .flags = &[_][]const u8{ "-std=c99", "-O3", "-fno-sanitize=undefined" },
    });
    null_safety_tests.addCSourceFile(.{
        .file = php_src_root.path(b, "scanner.c"),
        .flags = &[_][]const u8{ "-std=c99", "-O3", "-fno-sanitize=undefined" },
    });
    null_safety_tests.linkLibC();

    const run_null_safety_tests = b.addRunArtifact(null_safety_tests);
    test_step.dependOn(&run_null_safety_tests.step);

    const generics_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/generics.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_generics_tests = b.addRunArtifact(generics_tests);
    test_step.dependOn(&run_generics_tests.step);

    const return_type_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/return_type_checker.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    return_type_tests.root_module.addImport("tree-sitter", ts_dep.module("tree_sitter"));
    return_type_tests.root_module.addImport("cli", cli_dep.module("cli"));
    return_type_tests.addIncludePath(php_src_root);
    return_type_tests.addCSourceFile(.{
        .file = php_src_root.path(b, "parser.c"),
        .flags = &[_][]const u8{ "-std=c99", "-O3", "-fno-sanitize=undefined" },
    });
    return_type_tests.addCSourceFile(.{
        .file = php_src_root.path(b, "scanner.c"),
        .flags = &[_][]const u8{ "-std=c99", "-O3", "-fno-sanitize=undefined" },
    });
    return_type_tests.linkLibC();

    const run_return_type_tests = b.addRunArtifact(return_type_tests);
    test_step.dependOn(&run_return_type_tests.step);

    const dead_code_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/dead_code.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    dead_code_tests.root_module.addImport("tree-sitter", ts_dep.module("tree_sitter"));
    dead_code_tests.root_module.addImport("cli", cli_dep.module("cli"));
    dead_code_tests.addIncludePath(php_src_root);
    dead_code_tests.addCSourceFile(.{
        .file = php_src_root.path(b, "parser.c"),
        .flags = &[_][]const u8{ "-std=c99", "-O3", "-fno-sanitize=undefined" },
    });
    dead_code_tests.addCSourceFile(.{
        .file = php_src_root.path(b, "scanner.c"),
        .flags = &[_][]const u8{ "-std=c99", "-O3", "-fno-sanitize=undefined" },
    });
    dead_code_tests.linkLibC();

    const run_dead_code_tests = b.addRunArtifact(dead_code_tests);
    test_step.dependOn(&run_dead_code_tests.step);

    const test_gen_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_gen.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_test_gen_tests = b.addRunArtifact(test_gen_tests);
    test_step.dependOn(&run_test_gen_tests.step);

    // ----------------------------------------------------------------
    // Fuzz Testing
    // ----------------------------------------------------------------
    const fuzz_step = b.step("fuzz", "Run fuzz tests against the PHP analysis pipeline");

    const fuzz_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/fuzz_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    fuzz_tests.root_module.addImport("tree-sitter", ts_dep.module("tree_sitter"));
    fuzz_tests.root_module.addImport("cli", cli_dep.module("cli"));
    fuzz_tests.addIncludePath(php_src_root);
    fuzz_tests.addCSourceFile(.{
        .file = php_src_root.path(b, "parser.c"),
        .flags = &[_][]const u8{ "-std=c99", "-O3", "-fno-sanitize=undefined" },
    });
    fuzz_tests.addCSourceFile(.{
        .file = php_src_root.path(b, "scanner.c"),
        .flags = &[_][]const u8{ "-std=c99", "-O3", "-fno-sanitize=undefined" },
    });
    fuzz_tests.linkLibC();

    const run_fuzz_tests = b.addRunArtifact(fuzz_tests);
    fuzz_step.dependOn(&run_fuzz_tests.step);

    // ----------------------------------------------------------------
    // Distribution: Cross-compilation for all major platforms
    // ----------------------------------------------------------------
    const dist_step = b.step("dist", "Build ReleaseFast binaries for all major platforms");

    const dist_targets: []const std.Target.Query = &.{
        .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
        .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu },
        .{ .cpu_arch = .x86_64, .os_tag = .macos },
        .{ .cpu_arch = .aarch64, .os_tag = .macos },
        .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu },
    };

    for (dist_targets) |dist_target| {
        const resolved = b.resolveTargetQuery(dist_target);

        const dist_ts_dep = b.dependency("tree_sitter", .{
            .target = resolved,
            .optimize = .ReleaseFast,
        });

        const dist_cli_dep = b.dependency("cli", .{
            .target = resolved,
            .optimize = .ReleaseFast,
        });

        const dist_exe = b.addExecutable(.{
            .name = "phpcma",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = resolved,
                .optimize = .ReleaseFast,
            }),
        });

        dist_exe.root_module.addImport("tree-sitter", dist_ts_dep.module("tree_sitter"));
        dist_exe.root_module.addImport("cli", dist_cli_dep.module("cli"));
        dist_exe.addIncludePath(php_src_root);
        dist_exe.addCSourceFile(.{
            .file = php_src_root.path(b, "parser.c"),
            .flags = &[_][]const u8{ "-std=c99", "-O3", "-fno-sanitize=undefined" },
        });
        dist_exe.addCSourceFile(.{
            .file = php_src_root.path(b, "scanner.c"),
            .flags = &[_][]const u8{ "-std=c99", "-O3", "-fno-sanitize=undefined" },
        });
        dist_exe.linkLibC();

        const target_triple = dist_target.zigTriple(b.allocator) catch @panic("OOM");
        const install = b.addInstallArtifact(dist_exe, .{
            .dest_dir = .{ .override = .{ .custom = b.fmt("dist/{s}", .{target_triple}) } },
        });
        dist_step.dependOn(&install.step);
    }

    // ----------------------------------------------------------------
    // Benchmarks (ReleaseFast)
    // ----------------------------------------------------------------
    const bench_step = b.step("bench", "Run performance benchmarks");

    // Build tree-sitter dep with ReleaseFast to avoid UBSan link errors
    const ts_dep_fast = b.dependency("tree_sitter", .{
        .target = target,
        .optimize = .ReleaseFast,
    });

    const bench_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });

    // Add tree-sitter module (ReleaseFast build)
    bench_tests.root_module.addImport("tree-sitter", ts_dep_fast.module("tree_sitter"));

    // Add CLI module
    bench_tests.root_module.addImport("cli", cli_dep.module("cli"));

    // Add PHP grammar C sources
    bench_tests.addIncludePath(php_src_root);
    bench_tests.addCSourceFile(.{
        .file = php_src_root.path(b, "parser.c"),
        .flags = &[_][]const u8{ "-std=c99", "-O3", "-fno-sanitize=undefined" },
    });
    bench_tests.addCSourceFile(.{
        .file = php_src_root.path(b, "scanner.c"),
        .flags = &[_][]const u8{ "-std=c99", "-O3", "-fno-sanitize=undefined" },
    });
    bench_tests.linkLibC();

    const run_bench_tests = b.addRunArtifact(bench_tests);
    bench_step.dependOn(&run_bench_tests.step);
}
