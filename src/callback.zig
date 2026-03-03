const std = @import("std");
const assert = std.debug.assert;

pub fn Callback(comptime params: []const type, comptime Return: type) type {
    return struct {
        const Self = @This();

        func: *const FuncActual,
        data: ?*const anyopaque,

        const FuncActual = @Fn(
            &[2]type{ @Tuple(params), ?*const anyopaque },
            &@splat(.{}),
            Return,
            .{},
        );

        const FuncWithoutData = @Fn(
            params,
            &@splat(.{}),
            Return,
            .{},
        );

        fn FuncWithData(comptime Data: type) type {
            return @Fn(
                params ++ [1]type{Data},
                &@splat(.{}),
                Return,
                .{},
            );
        }

        pub fn call(callback: *const Self, args: @Tuple(params)) Return {
            try @call(.auto, callback.func, .{ args, callback.data });
        }

        pub fn withoutData(comptime func: FuncWithoutData) Self {
            const wrapped = struct {
                fn wrapped(
                    args: @Tuple(params),
                    data: ?*const anyopaque,
                ) Return {
                    assert(data == null);
                    return @call(.auto, func, args);
                }
            }.wrapped;

            return .{ .func = wrapped, .data = null };
        }

        pub fn withData(
            comptime Data: type,
            comptime func: FuncWithData(Data),
            data_init: Data,
        ) Self {
            const wrapped = struct {
                fn wrapped(
                    args: @Tuple(params),
                    data: ?*const anyopaque,
                ) Return {
                    const casted = castData(Data, data);
                    const args_actual = appendDataArg(Data, args, casted);
                    return @call(.auto, func, args_actual);
                }
            }.wrapped;

            return .{ .func = wrapped, .data = data_init };
        }

        fn castData(comptime Data: type, data: ?*const anyopaque) Data {
            return @ptrCast(@alignCast(@constCast(data.?)));
        }

        fn appendDataArg(
            comptime Data: type,
            args: @Tuple(params),
            data: Data,
        ) @Tuple(params ++ [1]type{Data}) {
            var args_actual: @Tuple(params ++ [1]type{Data}) = undefined;
            inline for (params, 0..) |_, i| {
                args_actual[i] = args[i];
            }
            args_actual[params.len] = data;
            return args_actual;
        }
    };
}
