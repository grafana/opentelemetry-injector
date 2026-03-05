// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const config = @import("config.zig");
const print = @import("print.zig");
const types = @import("types.zig");
const test_util = @import("test_util.zig");

const testing = std.testing;

pub const node_options_env_var_name = "NODE_OPTIONS";

/// Returns the modified value for NODE_OPTIONS, including the --require flag; based on the original value of
/// NODE_OPTIONS.
///
/// The caller is responsible for freeing the returned string (unless the result is passed on to setenv and needs to
/// stay in memory).
pub fn checkNodeJsAutoInstrumentationAgentAndGetModifiedNodeOptionsValue(
    gpa: std.mem.Allocator,
    original_value_optional: ?[:0]const u8,
    configuration: config.InjectorConfiguration,
) ?[:0]u8 {
    return doCheckNodeJsAutoInstrumentationAgentAndGetModifiedNodeOptionsValue(
        gpa,
        original_value_optional,
        configuration.nodejs_auto_instrumentation_agent_path,
        configuration.nodejs_instrumentation_disabled,
        configuration.mode,
    );
}

fn doCheckNodeJsAutoInstrumentationAgentAndGetModifiedNodeOptionsValue(
    gpa: std.mem.Allocator,
    original_value_optional: ?[:0]const u8,
    nodejs_auto_instrumentation_agent_path: []u8,
    nodejs_instrumentation_disabled: bool,
    mode: config.InstrumentationMode,
) ?[:0]u8 {
    if (nodejs_instrumentation_disabled or nodejs_auto_instrumentation_agent_path.len == 0) {
        print.printInfo("Skipping the injection of the Node.js OpenTelemetry auto-instrumentation because it has been explicitly disabled.", .{});
        return null;
    }

    // Check the existence of the Node module: requiring or importing a module
    // that does not exist or cannot be opened will crash the Node.js process
    // with an 'ERR_MODULE_NOT_FOUND' error.
    std.fs.cwd().access(nodejs_auto_instrumentation_agent_path, .{}) catch |err| {
        print.printError("Skipping the injection of the Node.js OpenTelemetry auto-instrumentation in \"{s}\" because of an issue accessing the Node.js module at \"{s}\": {}", .{ node_options_env_var_name, nodejs_auto_instrumentation_agent_path, err });
        return null;
    };

    const require_nodejs_auto_instrumentation_agent = std.fmt.allocPrintSentinel(gpa, "--require {s}", .{nodejs_auto_instrumentation_agent_path}, 0) catch |err| {
        print.printError("Cannot allocate memory to manipulate the value of \"{s}\": {}", .{ node_options_env_var_name, err });
        return null;
    };

    return getModifiedNodeOptionsValue(
        gpa,
        original_value_optional,
        require_nodejs_auto_instrumentation_agent,
        mode,
    );
}

test "doCheckNodeJsAutoInstrumentationAgentAndGetModifiedNodeOptionsValue: should return null if nodejs_instrumentation_disabled is true" {
    const path = try std.fmt.allocPrint(testing.allocator, "/some/valid/path", .{});
    defer testing.allocator.free(path);
    const modified_node_options_value =
        doCheckNodeJsAutoInstrumentationAgentAndGetModifiedNodeOptionsValue(
            testing.allocator,
            null,
            path,
            true,
            .install_unless_conflict,
        );
    try test_util.expectWithMessage(modified_node_options_value == null, "modified_node_options_value == null");
}

test "doCheckNodeJsAutoInstrumentationAgentAndGetModifiedNodeOptionsValue: should return null if nodejs_auto_instrumentation_agent_path is the empty string" {
    const path = try std.fmt.allocPrint(testing.allocator, "", .{});
    defer testing.allocator.free(path);
    const modified_node_options_value =
        doCheckNodeJsAutoInstrumentationAgentAndGetModifiedNodeOptionsValue(
            testing.allocator,
            null,
            path,
            false,
            .install_unless_conflict,
        );
    try test_util.expectWithMessage(modified_node_options_value == null, "modified_node_options_value == null");
}

test "doCheckNodeJsAutoInstrumentationAgentAndGetModifiedNodeOptionsValue: should return null if the Node.js OTel auto-instrumentation agent cannot be accessed (no other NODE_OPTIONS are present)" {
    const path = try std.fmt.allocPrint(testing.allocator, "/invalid/path", .{});
    defer testing.allocator.free(path);
    const modified_node_options_value =
        doCheckNodeJsAutoInstrumentationAgentAndGetModifiedNodeOptionsValue(
            testing.allocator,
            null,
            path,
            false,
            .install_unless_conflict,
        );
    try test_util.expectWithMessage(modified_node_options_value == null, "modified_node_options_value == null");
}

test "doCheckNodeJsAutoInstrumentationAgentAndGetModifiedNodeOptionsValue: should return null if the Node.js OTel auto-instrumentation agent cannot be accessed (other NODE_OPTIONS are present)" {
    const path = try std.fmt.allocPrint(testing.allocator, "/invalid/path", .{});
    defer testing.allocator.free(path);
    const modified_node_options_value =
        doCheckNodeJsAutoInstrumentationAgentAndGetModifiedNodeOptionsValue(
            testing.allocator,
            "--abort-on-uncaught-exception"[0.. :0],
            path,
            false,
            .install_unless_conflict,
        );
    try test_util.expectWithMessage(modified_node_options_value == null, "modified_node_options_value == null");
}

fn getModifiedNodeOptionsValue(
    gpa: std.mem.Allocator,
    original_value_optional: ?[:0]const u8,
    require_nodejs_auto_instrumentation_agent: [:0]u8,
    mode: config.InstrumentationMode,
) ?[:0]u8 {
    if (original_value_optional) |original_value| {
        if (std.mem.indexOf(u8, original_value, require_nodejs_auto_instrumentation_agent)) |_| {
            // Our exact "--require ..." flag is already present — double injection (e.g. shell → Node.js child process).
            if (mode == .install) {
                print.printWarn("mode=install: our --require flag is already present in NODE_OPTIONS, forcing re-injection.", .{});
            } else {
                gpa.free(require_nodejs_auto_instrumentation_agent);
                return null;
            }
        }

        // Check for a foreign --require flag (not ours) — indicates existing instrumentation.
        if (mode == .install_unless_conflict and std.mem.indexOf(u8, original_value, "--require") != null) {
            // There's a --require flag but it's not ours (we already checked for our exact flag above).
            if (std.mem.indexOf(u8, original_value, require_nodejs_auto_instrumentation_agent) == null) {
                print.printInfo("mode=install_unless_conflict: existing --require detected in NODE_OPTIONS, backing off.", .{});
                gpa.free(require_nodejs_auto_instrumentation_agent);
                return null;
            }
        }

        // If NODE_OPTIONS is already set, prepend the "--require ..." flag to the original value.
        // Since we copy over require_nodejs_auto_instrumentation_agent into newly allocated memory, we can free the
        // parameter here.
        defer gpa.free(require_nodejs_auto_instrumentation_agent);
        return std.fmt.allocPrintSentinel(
            gpa,
            "{s} {s}",
            .{ require_nodejs_auto_instrumentation_agent, original_value },
            0,
        ) catch |err| {
            print.printError("Cannot allocate memory to manipulate the value of \"{s}\": {}", .{ node_options_env_var_name, err });
            return null;
        };
    }

    // If NODE_OPTIONS is not set, simply return the "--require ..." flag.
    return require_nodejs_auto_instrumentation_agent[0..];
}

test "getModifiedNodeOptionsValue: should return --require if original value is unset" {
    const require_nodejs_auto_instrumentation_agent = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "--require /usr/lib/opentelemetry/nodejs/node_modules/@opentelemetry/auto-instrumentations-node/build/src/register.js",
        .{},
        0,
    );
    const modified_node_options_value =
        getModifiedNodeOptionsValue(
            testing.allocator,
            null,
            require_nodejs_auto_instrumentation_agent,
            .install_unless_conflict,
        );
    defer (if (modified_node_options_value) |val| {
        testing.allocator.free(val);
    });
    try testing.expectEqualStrings(
        "--require /usr/lib/opentelemetry/nodejs/node_modules/@opentelemetry/auto-instrumentations-node/build/src/register.js",
        modified_node_options_value orelse "-",
    );
}

test "getModifiedNodeOptionsValue: should prepend --require if original value exists" {
    const original_value: [:0]const u8 = "--abort-on-uncaught-exception"[0.. :0];
    const require_nodejs_auto_instrumentation_agent = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "--require /usr/lib/opentelemetry/nodejs/node_modules/@opentelemetry/auto-instrumentations-node/build/src/register.js",
        .{},
        0,
    );
    const modified_node_options_value =
        getModifiedNodeOptionsValue(
            testing.allocator,
            original_value,
            require_nodejs_auto_instrumentation_agent,
            .install_unless_conflict,
        );
    defer (if (modified_node_options_value) |val| {
        testing.allocator.free(val);
    });
    try testing.expectEqualStrings(
        "--require /usr/lib/opentelemetry/nodejs/node_modules/@opentelemetry/auto-instrumentations-node/build/src/register.js --abort-on-uncaught-exception",
        modified_node_options_value orelse "-",
    );
}

test "getModifiedNodeOptionsValue: should do nothing if our --require is already present" {
    const original_value: [:0]const u8 = "--abort-on-uncaught-exception --require /usr/lib/opentelemetry/nodejs/node_modules/@opentelemetry/auto-instrumentations-node/build/src/register.js --something-else"[0.. :0];
    const require_nodejs_auto_instrumentation_agent = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "--require /usr/lib/opentelemetry/nodejs/node_modules/@opentelemetry/auto-instrumentations-node/build/src/register.js",
        .{},
        0,
    );
    const modified_node_options_value =
        getModifiedNodeOptionsValue(
            testing.allocator,
            original_value,
            require_nodejs_auto_instrumentation_agent,
            .install_unless_conflict,
        );
    try test_util.expectWithMessage(modified_node_options_value == null, "modified_node_options_value == null");
}
