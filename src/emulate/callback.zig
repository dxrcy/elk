const std = @import("std");
const assert = std.debug.assert;

// TODO: Share with `Traps`
pub fn Callback(comptime params: []const type, comptime Return: type) type {
    const FuncNoData = @Fn(
        params,
        &@splat(.{}),
        Return,
        .{},
    );

    const FuncFull = @Fn(
        &[2]type{
            @Tuple(params),
            ?*const anyopaque,
        },
        &@splat(.{}),
        Return,
        .{},
    );

    return struct {
        const Self = @This();

        func: *const FuncFull,
        data: ?*const anyopaque,

        pub fn call(callback: *const Self, args: @Tuple(params)) Return {
            try @call(.auto, callback.func, .{ args, callback.data });
        }

        pub fn noData(comptime func: FuncNoData) Self {
            const wrapped = struct {
                fn wrapped(
                    args: @Tuple(params),
                    data: ?*const anyopaque,
                ) Return {
                    assert(data == null);
                    return @call(.auto, func, args);
                }
            }.wrapped;

            return .{
                .func = wrapped,
                .data = null,
            };
        }

        pub fn withData(
            comptime Data: type,
            comptime func: FuncData(Data),
            data: Data,
        ) Self {
            const wrapped = struct {
                fn wrapped(
                    args: @Tuple(params),
                    data_inner: ?*const anyopaque,
                ) Return {
                    const casted: Data = @ptrCast(@alignCast(@constCast(data_inner.?)));

                    var args_full: @Tuple(ParamData(Data)) = undefined;
                    inline for (params, 0..) |_, i| {
                        args_full[i] = args[i];
                    }
                    args_full[params.len] = casted;

                    return @call(.auto, func, args_full);
                }
            }.wrapped;

            return .{
                .func = wrapped,
                .data = data,
            };
        }

        fn ParamData(comptime Data: type) []const type {
            return params ++ [1]type{Data};
        }

        fn FuncData(comptime Data: type) type {
            return @Fn(
                ParamData(Data),
                &@splat(.{}),
                Return,
                .{},
            );
        }
    };
}
