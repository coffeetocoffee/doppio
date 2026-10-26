const std = @import("std");
const schema = @import("schema.zig");

pub const Error = error{
    EvaluationFailed,
    ParseError,
    TypeError,
    OutOfMemory,
};

pub const Host = struct {
    context: *anyopaque,
    evaluateFn: *const fn (*anyopaque, []const u8, schema.Context) Error!bool,

    pub fn evaluate(self: Host, source: []const u8, context: schema.Context) Error!bool {
        return self.evaluateFn(self.context, source, context);
    }
};

pub const Value = union(enum) {
    boolean: bool,
    number: f64,
    string: []const u8,
    list: []const Value,
    null_val: void,

    pub fn isTruthy(self: Value) bool {
        return switch (self) {
            .boolean => |b| b,
            .number => |n| n != 0.0,
            .string => |s| s.len > 0,
            .list => |l| l.len > 0,
            .null_val => false,
        };
    }

    pub fn asNumber(self: Value) ?f64 {
        return switch (self) {
            .number => |n| n,
            .string => |s| std.fmt.parseFloat(f64, s) catch null,
            .boolean => |b| if (b) 1.0 else 0.0,
            else => null,
        };
    }

    pub fn asString(self: Value) ?[]const u8 {
        return switch (self) {
            .string => |s| s,
            else => null,
        };
    }

    pub fn equals(self: Value, other: Value) bool {
        switch (self) {
            .boolean => |b| {
                if (other == .boolean) return b == other.boolean;
                return false;
            },
            .number => |n| {
                if (other == .number) return n == other.number;
                if (other.asNumber()) |on| return n == on;
                return false;
            },
            .string => |s| {
                if (other == .string) return std.mem.eql(u8, s, other.string);
                if (self.asNumber()) |sn| {
                    if (other.asNumber()) |on| return sn == on;
                }
                return false;
            },
            .list => |l| {
                if (other != .list or l.len != other.list.len) return false;
                for (l, 0..) |item, i| {
                    if (!item.equals(other.list[i])) return false;
                }
                return true;
            },
            .null_val => return other == .null_val,
        }
    }

    pub fn containsItem(self: Value, item: Value) bool {
        if (self != .list) return false;
        for (self.list) |elem| {
            if (elem.equals(item)) return true;
        }
        return false;
    }
};

pub const UnaryOp = enum { not, negate };

pub const BinaryOp = enum {
    eq,
    neq,
    lt,
    lte,
    gt,
    gte,
    logical_and,
    logical_or,
    in_op,
    add,
    sub,
    mul,
    div,
    mod,
};

pub const Node = union(enum) {
    literal: Value,
    identifier: []const u8,
    unary: struct {
        op: UnaryOp,
        expr: *const Node,
    },
    binary: struct {
        op: BinaryOp,
        left: *const Node,
        right: *const Node,
    },
    call: struct {
        name: []const u8,
        args: []const *const Node,
    },
    member_call: struct {
        target: *const Node,
        method: []const u8,
        args: []const *const Node,
    },
};

pub const Ast = struct {
    arena: std.heap.ArenaAllocator,
    root: *const Node,

    pub fn deinit(self: *Ast) void {
        self.arena.deinit();
    }
};

const TokenType = enum {
    identifier,
    string,
    number,
    true_kw,
    false_kw,
    in_kw,
    eq_eq,
    bang_eq,
    lte,
    gte,
    lt,
    gt,
    and_and,
    or_or,
    bang,
    plus,
    minus,
    star,
    slash,
    percent,
    lparen,
    rparen,
    lbracket,
    rbracket,
    comma,
    dot,
    eof,
};

const Token = struct {
    type: TokenType,
    text: []const u8,
    num_val: f64 = 0.0,
};

const Tokenizer = struct {
    source: []const u8,
    cursor: usize = 0,

    fn init(source: []const u8) Tokenizer {
        return .{ .source = source };
    }

    fn next(self: *Tokenizer) Error!Token {
        self.skipWhitespace();
        if (self.cursor >= self.source.len) {
            return .{ .type = .eof, .text = "" };
        }

        const start = self.cursor;
        const c = self.source[self.cursor];

        if (c == '"' or c == '\'') {
            return self.readString(c);
        }

        if (std.ascii.isDigit(c)) {
            return self.readNumber();
        }

        if (std.ascii.isAlphabetic(c) or c == '_') {
            return self.readIdentifier();
        }

        self.cursor += 1;
        switch (c) {
            '(' => return .{ .type = .lparen, .text = self.source[start..self.cursor] },
            ')' => return .{ .type = .rparen, .text = self.source[start..self.cursor] },
            '[' => return .{ .type = .lbracket, .text = self.source[start..self.cursor] },
            ']' => return .{ .type = .rbracket, .text = self.source[start..self.cursor] },
            ',' => return .{ .type = .comma, .text = self.source[start..self.cursor] },
            '.' => return .{ .type = .dot, .text = self.source[start..self.cursor] },
            '+' => return .{ .type = .plus, .text = self.source[start..self.cursor] },
            '-' => return .{ .type = .minus, .text = self.source[start..self.cursor] },
            '*' => return .{ .type = .star, .text = self.source[start..self.cursor] },
            '/' => return .{ .type = .slash, .text = self.source[start..self.cursor] },
            '%' => return .{ .type = .percent, .text = self.source[start..self.cursor] },
            '=' => {
                if (self.cursor < self.source.len and self.source[self.cursor] == '=') {
                    self.cursor += 1;
                    return .{ .type = .eq_eq, .text = self.source[start..self.cursor] };
                }
                return error.ParseError;
            },
            '!' => {
                if (self.cursor < self.source.len and self.source[self.cursor] == '=') {
                    self.cursor += 1;
                    return .{ .type = .bang_eq, .text = self.source[start..self.cursor] };
                }
                return .{ .type = .bang, .text = self.source[start..self.cursor] };
            },
            '<' => {
                if (self.cursor < self.source.len and self.source[self.cursor] == '=') {
                    self.cursor += 1;
                    return .{ .type = .lte, .text = self.source[start..self.cursor] };
                }
                return .{ .type = .lt, .text = self.source[start..self.cursor] };
            },
            '>' => {
                if (self.cursor < self.source.len and self.source[self.cursor] == '=') {
                    self.cursor += 1;
                    return .{ .type = .gte, .text = self.source[start..self.cursor] };
                }
                return .{ .type = .gt, .text = self.source[start..self.cursor] };
            },
            '&' => {
                if (self.cursor < self.source.len and self.source[self.cursor] == '&') {
                    self.cursor += 1;
                    return .{ .type = .and_and, .text = self.source[start..self.cursor] };
                }
                return error.ParseError;
            },
            '|' => {
                if (self.cursor < self.source.len and self.source[self.cursor] == '|') {
                    self.cursor += 1;
                    return .{ .type = .or_or, .text = self.source[start..self.cursor] };
                }
                return error.ParseError;
            },
            else => return error.ParseError,
        }
    }

    fn skipWhitespace(self: *Tokenizer) void {
        while (self.cursor < self.source.len) {
            const c = self.source[self.cursor];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                self.cursor += 1;
            } else {
                break;
            }
        }
    }

    fn readString(self: *Tokenizer, quote: u8) Error!Token {
        self.cursor += 1; // skip opening quote
        const content_start = self.cursor;
        while (self.cursor < self.source.len and self.source[self.cursor] != quote) {
            if (self.source[self.cursor] == '\\' and self.cursor + 1 < self.source.len) {
                self.cursor += 2;
            } else {
                self.cursor += 1;
            }
        }
        if (self.cursor >= self.source.len) return error.ParseError;
        const text = self.source[content_start..self.cursor];
        self.cursor += 1; // skip closing quote
        return .{ .type = .string, .text = text };
    }

    fn readNumber(self: *Tokenizer) Error!Token {
        const start = self.cursor;
        while (self.cursor < self.source.len and std.ascii.isDigit(self.source[self.cursor])) {
            self.cursor += 1;
        }
        if (self.cursor < self.source.len and self.source[self.cursor] == '.') {
            if (self.cursor + 1 < self.source.len and std.ascii.isDigit(self.source[self.cursor + 1])) {
                self.cursor += 1;
                while (self.cursor < self.source.len and std.ascii.isDigit(self.source[self.cursor])) {
                    self.cursor += 1;
                }
            }
        }
        const text = self.source[start..self.cursor];
        const val = std.fmt.parseFloat(f64, text) catch return error.ParseError;
        return .{ .type = .number, .text = text, .num_val = val };
    }

    fn readIdentifier(self: *Tokenizer) Error!Token {
        const start = self.cursor;
        while (self.cursor < self.source.len) {
            const c = self.source[self.cursor];
            if (std.ascii.isAlphanumeric(c) or c == '_') {
                self.cursor += 1;
            } else {
                break;
            }
        }
        const text = self.source[start..self.cursor];
        if (std.mem.eql(u8, text, "true")) return .{ .type = .true_kw, .text = text };
        if (std.mem.eql(u8, text, "false")) return .{ .type = .false_kw, .text = text };
        if (std.mem.eql(u8, text, "in")) return .{ .type = .in_kw, .text = text };
        return .{ .type = .identifier, .text = text };
    }
};

pub const Parser = struct {
    tokenizer: Tokenizer,
    current: Token,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) Error!Parser {
        var tok = Tokenizer.init(source);
        const first = try tok.next();
        return .{
            .tokenizer = tok,
            .current = first,
            .allocator = allocator,
        };
    }

    fn consume(self: *Parser, expected: TokenType) Error!Token {
        if (self.current.type == expected) {
            const tok = self.current;
            self.current = try self.tokenizer.next();
            return tok;
        }
        return error.ParseError;
    }

    pub fn parseExpression(self: *Parser) Error!*const Node {
        return self.parseOr();
    }

    fn parseOr(self: *Parser) Error!*const Node {
        var left = try self.parseAnd();
        while (self.current.type == .or_or) {
            _ = try self.consume(.or_or);
            const right = try self.parseAnd();
            const node = try self.allocator.create(Node);
            node.* = .{ .binary = .{ .op = .logical_or, .left = left, .right = right } };
            left = node;
        }
        return left;
    }

    fn parseAnd(self: *Parser) Error!*const Node {
        var left = try self.parseEquality();
        while (self.current.type == .and_and) {
            _ = try self.consume(.and_and);
            const right = try self.parseEquality();
            const node = try self.allocator.create(Node);
            node.* = .{ .binary = .{ .op = .logical_and, .left = left, .right = right } };
            left = node;
        }
        return left;
    }

    fn parseEquality(self: *Parser) Error!*const Node {
        var left = try self.parseRelational();
        while (self.current.type == .eq_eq or self.current.type == .bang_eq or self.current.type == .in_kw) {
            const tok = self.current;
            _ = try self.consume(tok.type);
            const right = try self.parseRelational();
            const op: BinaryOp = switch (tok.type) {
                .eq_eq => .eq,
                .bang_eq => .neq,
                .in_kw => .in_op,
                else => unreachable,
            };
            const node = try self.allocator.create(Node);
            node.* = .{ .binary = .{ .op = op, .left = left, .right = right } };
            left = node;
        }
        return left;
    }

    fn parseRelational(self: *Parser) Error!*const Node {
        var left = try self.parseAdditive();
        while (self.current.type == .lt or self.current.type == .lte or self.current.type == .gt or self.current.type == .gte) {
            const tok = self.current;
            _ = try self.consume(tok.type);
            const right = try self.parseAdditive();
            const op: BinaryOp = switch (tok.type) {
                .lt => .lt,
                .lte => .lte,
                .gt => .gt,
                .gte => .gte,
                else => unreachable,
            };
            const node = try self.allocator.create(Node);
            node.* = .{ .binary = .{ .op = op, .left = left, .right = right } };
            left = node;
        }
        return left;
    }

    fn parseAdditive(self: *Parser) Error!*const Node {
        var left = try self.parseMultiplicative();
        while (self.current.type == .plus or self.current.type == .minus) {
            const tok = self.current;
            _ = try self.consume(tok.type);
            const right = try self.parseMultiplicative();
            const op: BinaryOp = if (tok.type == .plus) .add else .sub;
            const node = try self.allocator.create(Node);
            node.* = .{ .binary = .{ .op = op, .left = left, .right = right } };
            left = node;
        }
        return left;
    }

    fn parseMultiplicative(self: *Parser) Error!*const Node {
        var left = try self.parseUnary();
        while (self.current.type == .star or self.current.type == .slash or self.current.type == .percent) {
            const tok = self.current;
            _ = try self.consume(tok.type);
            const right = try self.parseUnary();
            const op: BinaryOp = switch (tok.type) {
                .star => .mul,
                .slash => .div,
                .percent => .mod,
                else => unreachable,
            };
            const node = try self.allocator.create(Node);
            node.* = .{ .binary = .{ .op = op, .left = left, .right = right } };
            left = node;
        }
        return left;
    }

    fn parseUnary(self: *Parser) Error!*const Node {
        if (self.current.type == .bang) {
            _ = try self.consume(.bang);
            const expr = try self.parseUnary();
            const node = try self.allocator.create(Node);
            node.* = .{ .unary = .{ .op = .not, .expr = expr } };
            return node;
        }
        if (self.current.type == .minus) {
            _ = try self.consume(.minus);
            const expr = try self.parseUnary();
            const node = try self.allocator.create(Node);
            node.* = .{ .unary = .{ .op = .negate, .expr = expr } };
            return node;
        }
        return self.parsePrimary();
    }

    fn parsePrimary(self: *Parser) Error!*const Node {
        var node = try self.parseBase();
        while (self.current.type == .dot) {
            _ = try self.consume(.dot);
            const method_tok = try self.consume(.identifier);
            if (self.current.type == .lparen) {
                _ = try self.consume(.lparen);
                var args: std.ArrayList(*const Node) = .empty;
                if (self.current.type != .rparen) {
                    try args.append(self.allocator, try self.parseExpression());
                    while (self.current.type == .comma) {
                        _ = try self.consume(.comma);
                        try args.append(self.allocator, try self.parseExpression());
                    }
                }
                _ = try self.consume(.rparen);

                const member_node = try self.allocator.create(Node);
                member_node.* = .{
                    .member_call = .{
                        .target = node,
                        .method = method_tok.text,
                        .args = try args.toOwnedSlice(self.allocator),
                    },
                };
                node = member_node;
            } else {
                // Property access e.g. target.field -> combine identifier
                if (node.* == .identifier) {
                    const combined = try std.fmt.allocPrint(
                        self.allocator,
                        "{s}.{s}",
                        .{ node.identifier, method_tok.text },
                    );
                    const id_node = try self.allocator.create(Node);
                    id_node.* = .{ .identifier = combined };
                    node = id_node;
                } else {
                    return error.ParseError;
                }
            }
        }
        return node;
    }

    fn parseBase(self: *Parser) Error!*const Node {
        switch (self.current.type) {
            .true_kw => {
                _ = try self.consume(.true_kw);
                const node = try self.allocator.create(Node);
                node.* = .{ .literal = .{ .boolean = true } };
                return node;
            },
            .false_kw => {
                _ = try self.consume(.false_kw);
                const node = try self.allocator.create(Node);
                node.* = .{ .literal = .{ .boolean = false } };
                return node;
            },
            .number => {
                const tok = try self.consume(.number);
                const node = try self.allocator.create(Node);
                node.* = .{ .literal = .{ .number = tok.num_val } };
                return node;
            },
            .string => {
                const tok = try self.consume(.string);
                const node = try self.allocator.create(Node);
                node.* = .{ .literal = .{ .string = tok.text } };
                return node;
            },
            .lbracket => {
                _ = try self.consume(.lbracket);
                var items: std.ArrayList(Value) = .empty;
                if (self.current.type != .rbracket) {
                    const first_node = try self.parseExpression();
                    if (first_node.* != .literal) return error.ParseError;
                    try items.append(self.allocator, first_node.literal);

                    while (self.current.type == .comma) {
                        _ = try self.consume(.comma);
                        const next_node = try self.parseExpression();
                        if (next_node.* != .literal) return error.ParseError;
                        try items.append(self.allocator, next_node.literal);
                    }
                }
                _ = try self.consume(.rbracket);
                const node = try self.allocator.create(Node);
                node.* = .{ .literal = .{ .list = try items.toOwnedSlice(self.allocator) } };
                return node;
            },
            .lparen => {
                _ = try self.consume(.lparen);
                const inner = try self.parseExpression();
                _ = try self.consume(.rparen);
                return inner;
            },
            .identifier => {
                const tok = try self.consume(.identifier);
                if (self.current.type == .lparen) {
                    _ = try self.consume(.lparen);
                    var args: std.ArrayList(*const Node) = .empty;
                    if (self.current.type != .rparen) {
                        try args.append(self.allocator, try self.parseExpression());
                        while (self.current.type == .comma) {
                            _ = try self.consume(.comma);
                            try args.append(self.allocator, try self.parseExpression());
                        }
                    }
                    _ = try self.consume(.rparen);
                    const node = try self.allocator.create(Node);
                    node.* = .{
                        .call = .{
                            .name = tok.text,
                            .args = try args.toOwnedSlice(self.allocator),
                        },
                    };
                    return node;
                } else {
                    const node = try self.allocator.create(Node);
                    node.* = .{ .identifier = tok.text };
                    return node;
                }
            },
            else => return error.ParseError,
        }
    }
};

pub fn parse(allocator: std.mem.Allocator, source: []const u8) Error!Ast {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    var parser = try Parser.init(arena.allocator(), source);
    const root = try parser.parseExpression();
    if (parser.current.type != .eof) return error.ParseError;

    return .{
        .arena = arena,
        .root = root,
    };
}

pub fn evaluateNode(node: *const Node, context: schema.Context) Error!Value {
    switch (node.*) {
        .literal => |lit| return lit,
        .identifier => |name| {
            if (std.mem.eql(u8, name, "unit_id") or std.mem.eql(u8, name, "user.id") or std.mem.eql(u8, name, "user_id") or std.mem.eql(u8, name, "id")) {
                return .{ .string = context.unit_id };
            }
            if (context.getAttribute(name)) |val| {
                return .{ .string = val };
            }
            if (std.mem.startsWith(u8, name, "custom.")) {
                const key = name["custom.".len..];
                if (context.getAttribute(key)) |val| return .{ .string = val };
            }
            if (std.mem.startsWith(u8, name, "user.")) {
                const key = name["user.".len..];
                if (context.getAttribute(key)) |val| return .{ .string = val };
            }
            if (std.mem.startsWith(u8, name, "account.")) {
                const key = name["account.".len..];
                if (context.getAttribute(key)) |val| return .{ .string = val };
            }
            return .{ .null_val = {} };
        },
        .unary => |un| {
            const val = try evaluateNode(un.expr, context);
            switch (un.op) {
                .not => return .{ .boolean = !val.isTruthy() },
                .negate => {
                    const n = val.asNumber() orelse return error.TypeError;
                    return .{ .number = -n };
                },
            }
        },
        .binary => |bin| {
            switch (bin.op) {
                .logical_and => {
                    const left = try evaluateNode(bin.left, context);
                    if (!left.isTruthy()) return .{ .boolean = false };
                    const right = try evaluateNode(bin.right, context);
                    return .{ .boolean = right.isTruthy() };
                },
                .logical_or => {
                    const left = try evaluateNode(bin.left, context);
                    if (left.isTruthy()) return .{ .boolean = true };
                    const right = try evaluateNode(bin.right, context);
                    return .{ .boolean = right.isTruthy() };
                },
                .in_op => {
                    const left = try evaluateNode(bin.left, context);
                    const right = try evaluateNode(bin.right, context);
                    if (right == .list) {
                        return .{ .boolean = right.containsItem(left) };
                    }
                    if (right == .string and left == .string) {
                        return .{ .boolean = std.mem.indexOf(u8, right.string, left.string) != null };
                    }
                    return error.TypeError;
                },
                .eq => {
                    const left = try evaluateNode(bin.left, context);
                    const right = try evaluateNode(bin.right, context);
                    return .{ .boolean = left.equals(right) };
                },
                .neq => {
                    const left = try evaluateNode(bin.left, context);
                    const right = try evaluateNode(bin.right, context);
                    return .{ .boolean = !left.equals(right) };
                },
                .lt, .lte, .gt, .gte => {
                    const left = try evaluateNode(bin.left, context);
                    const right = try evaluateNode(bin.right, context);
                    const ln = left.asNumber() orelse return error.TypeError;
                    const rn = right.asNumber() orelse return error.TypeError;
                    const res = switch (bin.op) {
                        .lt => ln < rn,
                        .lte => ln <= rn,
                        .gt => ln > rn,
                        .gte => ln >= rn,
                        else => unreachable,
                    };
                    return .{ .boolean = res };
                },
                .add, .sub, .mul, .div, .mod => {
                    const left = try evaluateNode(bin.left, context);
                    const right = try evaluateNode(bin.right, context);
                    const ln = left.asNumber() orelse return error.TypeError;
                    const rn = right.asNumber() orelse return error.TypeError;
                    const res = switch (bin.op) {
                        .add => ln + rn,
                        .sub => ln - rn,
                        .mul => ln * rn,
                        .div => if (rn != 0.0) ln / rn else return error.EvaluationFailed,
                        .mod => @mod(ln, rn),
                        else => unreachable,
                    };
                    return .{ .number = res };
                },
            }
        },
        .call => |call| {
            if (std.mem.eql(u8, call.name, "has")) {
                if (call.args.len != 1) return error.ParseError;
                const arg = call.args[0];
                if (arg.* == .identifier) {
                    const val = try evaluateNode(arg, context);
                    return .{ .boolean = val != .null_val };
                }
                return error.ParseError;
            }
            if (std.mem.eql(u8, call.name, "size")) {
                if (call.args.len != 1) return error.ParseError;
                const val = try evaluateNode(call.args[0], context);
                switch (val) {
                    .string => |s| return .{ .number = @floatFromInt(s.len) },
                    .list => |l| return .{ .number = @floatFromInt(l.len) },
                    else => return error.TypeError,
                }
            }
            if (std.mem.eql(u8, call.name, "startsWith")) {
                if (call.args.len != 2) return error.ParseError;
                const s = (try evaluateNode(call.args[0], context)).asString() orelse return error.TypeError;
                const p = (try evaluateNode(call.args[1], context)).asString() orelse return error.TypeError;
                return .{ .boolean = std.mem.startsWith(u8, s, p) };
            }
            if (std.mem.eql(u8, call.name, "endsWith")) {
                if (call.args.len != 2) return error.ParseError;
                const s = (try evaluateNode(call.args[0], context)).asString() orelse return error.TypeError;
                const p = (try evaluateNode(call.args[1], context)).asString() orelse return error.TypeError;
                return .{ .boolean = std.mem.endsWith(u8, s, p) };
            }
            if (std.mem.eql(u8, call.name, "contains")) {
                if (call.args.len != 2) return error.ParseError;
                const s = (try evaluateNode(call.args[0], context)).asString() orelse return error.TypeError;
                const sub = (try evaluateNode(call.args[1], context)).asString() orelse return error.TypeError;
                return .{ .boolean = std.mem.indexOf(u8, s, sub) != null };
            }
            if (std.mem.eql(u8, call.name, "matches")) {
                if (call.args.len != 2) return error.ParseError;
                const s = (try evaluateNode(call.args[0], context)).asString() orelse return error.TypeError;
                const pattern = (try evaluateNode(call.args[1], context)).asString() orelse return error.TypeError;
                return .{ .boolean = matchPattern(s, pattern) };
            }
            return error.EvaluationFailed;
        },
        .member_call => |mc| {
            const target_val = try evaluateNode(mc.target, context);
            const s = target_val.asString() orelse return error.TypeError;
            if (std.mem.eql(u8, mc.method, "startsWith")) {
                if (mc.args.len != 1) return error.ParseError;
                const p = (try evaluateNode(mc.args[0], context)).asString() orelse return error.TypeError;
                return .{ .boolean = std.mem.startsWith(u8, s, p) };
            }
            if (std.mem.eql(u8, mc.method, "endsWith")) {
                if (mc.args.len != 1) return error.ParseError;
                const p = (try evaluateNode(mc.args[0], context)).asString() orelse return error.TypeError;
                return .{ .boolean = std.mem.endsWith(u8, s, p) };
            }
            if (std.mem.eql(u8, mc.method, "contains")) {
                if (mc.args.len != 1) return error.ParseError;
                const sub = (try evaluateNode(mc.args[0], context)).asString() orelse return error.TypeError;
                return .{ .boolean = std.mem.indexOf(u8, s, sub) != null };
            }
            if (std.mem.eql(u8, mc.method, "matches")) {
                if (mc.args.len != 1) return error.ParseError;
                const pat = (try evaluateNode(mc.args[0], context)).asString() orelse return error.TypeError;
                return .{ .boolean = matchPattern(s, pat) };
            }
            return error.EvaluationFailed;
        },
    }
}

pub fn evaluateExpression(ast: *const Ast, context: schema.Context) Error!bool {
    const val = try evaluateNode(ast.root, context);
    return val.isTruthy();
}

pub fn evaluate(source: []const u8, context: schema.Context) Error!bool {
    var buffer: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    var arena = std.heap.ArenaAllocator.init(fba.allocator());
    defer arena.deinit();

    var parser = Parser.init(arena.allocator(), source) catch return error.ParseError;
    const root = parser.parseExpression() catch return error.ParseError;
    if (parser.current.type != .eof) return error.ParseError;

    const val = evaluateNode(root, context) catch return error.EvaluationFailed;
    return val.isTruthy();
}

pub fn matchPattern(text: []const u8, pattern: []const u8) bool {
    var p_idx: usize = 0;
    var t_idx: usize = 0;
    var star_idx: ?usize = null;
    var match_idx: usize = 0;

    const anchored_start = std.mem.startsWith(u8, pattern, "^");
    const clean_pattern = if (anchored_start) pattern[1..] else pattern;
    const anchored_end = std.mem.endsWith(u8, clean_pattern, "$");
    const effective_pattern = if (anchored_end) clean_pattern[0 .. clean_pattern.len - 1] else clean_pattern;

    while (t_idx < text.len) {
        if (p_idx < effective_pattern.len and (effective_pattern[p_idx] == '?' or effective_pattern[p_idx] == '.' or effective_pattern[p_idx] == text[t_idx])) {
            p_idx += 1;
            t_idx += 1;
        } else if (p_idx < effective_pattern.len and effective_pattern[p_idx] == '*') {
            star_idx = p_idx;
            match_idx = t_idx;
            p_idx += 1;
        } else if (star_idx) |s_idx| {
            p_idx = s_idx + 1;
            match_idx += 1;
            t_idx = match_idx;
        } else if (!anchored_start) {
            match_idx += 1;
            t_idx = match_idx;
            p_idx = 0;
        } else {
            return false;
        }
    }

    while (p_idx < effective_pattern.len and effective_pattern[p_idx] == '*') {
        p_idx += 1;
    }

    if (anchored_end or anchored_start) {
        return p_idx == effective_pattern.len;
    }
    return p_idx == effective_pattern.len or star_idx != null;
}

const Mock = struct {
    value: bool,
};

fn mockEvaluate(context: *anyopaque, source: []const u8, eval_context: schema.Context) Error!bool {
    _ = source;
    _ = eval_context;
    const mock: *Mock = @ptrCast(@alignCast(context));
    return mock.value;
}

test "host delegates evaluation to the bound function" {
    var mock = Mock{ .value = true };
    const host = Host{ .context = &mock, .evaluateFn = mockEvaluate };

    try std.testing.expect(try host.evaluate("user.country == \"ID\"", .{ .unit_id = "user-1" }));

    mock.value = false;
    try std.testing.expect(!try host.evaluate("user.country == \"ID\"", .{ .unit_id = "user-1" }));
}

test "native CEL evaluation: equality and context" {
    const ctx = schema.Context{
        .unit_id = "user-1",
        .attributes = &[_]schema.Attribute{
            .{ .key = "user.country", .value = "ID" },
            .{ .key = "account.plan", .value = "pro" },
        },
    };

    try std.testing.expect(try evaluate("user.country == \"ID\"", ctx));
    try std.testing.expect(!try evaluate("user.country == \"US\"", ctx));
    try std.testing.expect(try evaluate("user.country != \"US\"", ctx));
    try std.testing.expect(try evaluate("user.country == \"ID\" && account.plan == \"pro\"", ctx));
    try std.testing.expect(!try evaluate("user.country == \"ID\" && account.plan == \"free\"", ctx));
    try std.testing.expect(try evaluate("user.country == \"US\" || account.plan == \"pro\"", ctx));
}

test "native CEL evaluation: membership operator in" {
    const ctx = schema.Context{
        .unit_id = "user-123",
        .attributes = &[_]schema.Attribute{
            .{ .key = "country", .value = "CA" },
        },
    };

    try std.testing.expect(try evaluate("country in [\"US\", \"CA\", \"MX\"]", ctx));
    try std.testing.expect(!try evaluate("country in [\"GB\", \"FR\", \"DE\"]", ctx));
}

test "native CEL evaluation: presence and built-in functions" {
    const ctx = schema.Context{
        .unit_id = "user-vip-42",
        .attributes = &[_]schema.Attribute{
            .{ .key = "custom.ltv", .value = "1450" },
            .{ .key = "custom.email", .value = "alpha@example.com" },
        },
    };

    try std.testing.expect(try evaluate("has(custom.ltv)", ctx));
    try std.testing.expect(!try evaluate("has(custom.missing)", ctx));
    try std.testing.expect(try evaluate("custom.ltv >= 1000", ctx));
    try std.testing.expect(try evaluate("startsWith(unit_id, \"user-\")", ctx));
    try std.testing.expect(try evaluate("unit_id.endsWith(\"-42\")", ctx));
    try std.testing.expect(try evaluate("contains(custom.email, \"@example.com\")", ctx));
    try std.testing.expect(try evaluate("matches(custom.email, \"*@example.com\")", ctx));
}
