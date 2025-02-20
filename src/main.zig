// TODO! look into inline loops for string formating
const std = @import("std");
const posix = std.posix;
const stdin = std.io.getStdIn();
const stdout = std.io.getStdOut();

const Key = enum(u16) {
    BACKSPACE = 127,
    MOVE_LEFT = 1000,
    MOVE_RIGHT,
    MOVE_UP,
    MOVE_DOWN,
    DEL_KEY,
    HOME_KEY,
    END_KEY,
    PAGE_UP,
    PAGE_DOWN,
};

const VERSION = "0.0.1";
const QUIT_TIMES = 3;
const TAB_STOP = 8;

const Row = struct {
    row: std.ArrayList(u8),
    render: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) Row {
        return Row{
            .row = std.ArrayList(u8).init(allocator),
            .render = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: Row) void {
        self.row.deinit();
        self.render.deinit();
    }

    fn updateRow(self: *Row) !void {
        self.render.clearAndFree();
        for (self.row.items) |char| {
            if (char == '\t') {
                for (0..TAB_STOP) |_| {
                    try self.render.append(' ');
                }
            } else {
                try self.render.append(char);
            }
        }
    }

    fn insertChar(self: *Row, at: usize, char: u8) !void {
        var at_in = at;
        if (at_in < 0 or at_in > self.row.items.len) at_in = self.row.items.len;
        try self.row.insert(at_in, char);
        try self.updateRow();
    }
};

const Editor = struct {
    origin_termios: ?posix.termios,
    screen_rows: u16,
    screen_cols: u16,
    cursor_row_x: u16,
    cursor_render_x: u16,
    cursor_y: u16,
    file_name: std.ArrayList(u8),
    status_message: [1024]u8,
    status_message_time: i64,
    rows: std.ArrayList(Row),
    dirty: u8,
    // TODO! are there static variables in zig?
    quit_times: u8,
    row_off: u16,
    col_off: u16,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Editor {
        var editor = Editor{
            .origin_termios = null,
            .screen_rows = 0,
            .screen_cols = 0,
            .cursor_row_x = 0,
            .cursor_render_x = 0,
            .cursor_y = 0,
            .file_name = std.ArrayList(u8).init(allocator),
            .status_message = undefined,
            .status_message_time = 0,
            .rows = std.ArrayList(Row).init(allocator),
            .dirty = 0,
            .quit_times = QUIT_TIMES,
            .row_off = 0,
            .col_off = 0,
            .allocator = allocator,
        };

        // TODO! collaps this into Editor.init
        _ = try editor.getWindowSize();

        return editor;
    }

    // Thank you https://codeberg.org/zenith-editor/zenith
    // I tried for an hour to get this to work using os.linux but couldn't
    // Thanks for showing me std.posix
    pub fn enableRawMode(self: *Editor) !void {
        var raw = try posix.tcgetattr(stdin.handle);

        self.origin_termios = raw;

        // Local flags
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;

        // Input flags
        raw.iflag.IXON = false;
        raw.iflag.ICRNL = false;
        raw.iflag.BRKINT = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;

        // Output flags
        raw.oflag.OPOST = false;

        // Control flags
        raw.cflag.CSIZE = posix.CSIZE.CS8;

        raw.cc[@intFromEnum(posix.V.MIN)] = 0;
        raw.cc[@intFromEnum(posix.V.TIME)] = 1;

        try posix.tcsetattr(stdin.handle, posix.TCSA.FLUSH, raw);
    }

    pub fn disableRawMode(self: *Editor) !void {
        if (self.origin_termios) |origin_termios| {
            try posix.tcsetattr(stdin.handle, posix.TCSA.FLUSH, origin_termios);
        }
    }

    pub fn getWindowSize(self: *Editor) !i8 {
        var win_size = std.posix.system.winsize{ .ws_col = 0, .ws_row = 0, .ws_xpixel = 0, .ws_ypixel = 0 };

        if (std.posix.system.ioctl(stdout.handle, posix.system.T.IOCGWINSZ, @intFromPtr(&win_size)) == -1 or win_size.ws_col == 0) {
            return -1;
        } else {
            self.screen_rows = win_size.ws_row - 2;
            self.screen_cols = win_size.ws_col;
        }

        return 0;
    }

    fn refreshScreen(self: *Editor) !void {
        self.scroll();

        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();

        var writer = buffer.writer();

        try writer.writeAll("\x1b[?25l");
        try writer.writeAll("\x1b[H");

        try self.drawRows(writer);
        try self.drawStatusBar(writer);
        try self.drawMessageBar(writer);

        // TODO! find a better way to format strings.
        const move_cursor = try std.fmt.allocPrint(self.allocator, "\x1b[{d};{d}H", .{ (self.cursor_y - self.row_off) + 1, (self.cursor_render_x - self.col_off) + 1 });
        defer self.allocator.free(move_cursor);
        try writer.writeAll(move_cursor);

        try writer.writeAll("\x1b[?25h");

        try stdout.writer().writeAll(buffer.items);
    }

    fn setStatusMessage(self: *Editor, comptime fmt: []const u8, args: anytype) !void {
        // TODO! find a better way to clear buffer. Switch to ArrayList?
        @memset(&self.status_message, 0);
        _ = try std.fmt.bufPrint(&self.status_message, fmt, args);
        self.status_message_time = std.time.timestamp();
    }

    fn drawRows(self: *Editor, writer: anytype) !void {
        for (0..self.screen_rows) |y| {
            const filerow = y + self.row_off;
            if (filerow >= self.rows.items.len) {
                if (self.rows.items.len == 0 and y == self.screen_rows / 3) {
                    var welcome: []const u8 = "Zilo Editor -- version " ++ VERSION;

                    if (welcome.len > self.screen_cols) welcome = welcome[0..self.screen_cols];

                    var padding = (self.screen_cols - welcome.len) / 2;
                    if (padding != 0) {
                        try writer.writeAll("~");
                        padding -= 1;
                    }

                    while (padding != 0) : (padding -= 1) {
                        try writer.writeAll(" ");
                    }

                    try writer.writeAll(welcome);
                } else {
                    try writer.writeAll("~");
                }
            } else {
                var len: usize = 0;
                if (self.col_off < self.rows.items[filerow].render.items.len) len = self.rows.items[filerow].render.items.len - self.col_off;
                if (len > self.screen_cols) len = self.screen_cols;

                if (len != 0) {
                    try writer.writeAll(self.rows.items[filerow].render.items[self.col_off .. self.col_off + len]);
                }
            }
            try writer.writeAll("\x1b[K");
            try writer.writeAll("\r\n");
        }
    }

    fn drawStatusBar(self: Editor, writer: anytype) !void {
        try writer.writeAll("\x1b[7m");

        var status = try std.fmt.allocPrint(self.allocator, "{s} - {d} lines {s}", .{ if (self.file_name.items.len == 0) "[No Name]" else self.file_name.items, self.rows.items.len, if (self.dirty != 0) "(modified)" else "" });
        defer self.allocator.free(status);

        const rstatus = try std.fmt.allocPrint(self.allocator, "{d}", .{self.cursor_y + 1});
        defer self.allocator.free(rstatus);

        if (status.len > self.screen_cols) status = status[0..self.screen_cols];

        try writer.writeAll(status);

        for (status.len..self.screen_cols) |len| {
            if (self.screen_cols - len == rstatus.len) {
                try writer.writeAll(rstatus);
                break;
            } else {
                try writer.writeAll(" ");
            }
        }

        try writer.writeAll("\x1b[m");
        try writer.writeAll("\r\n");
    }

    fn drawMessageBar(self: *Editor, writer: anytype) !void {
        try writer.writeAll("\x1b[K");

        var message_len = self.status_message.len;
        if (message_len > self.screen_cols) message_len = self.screen_cols;
        if (message_len != 0) {
            if (std.time.timestamp() - self.status_message_time < 5) try writer.writeAll(self.status_message[0..message_len]);
        }
    }

    fn moveCursor(self: *Editor, key: u16) void {
        const row = if (self.cursor_y >= self.rows.items.len) null else self.rows.items[self.cursor_y].row.items;
        switch (key) {
            @intFromEnum(Key.MOVE_UP) => if (self.cursor_y != 0) {
                self.cursor_y -= 1;
            },
            @intFromEnum(Key.MOVE_DOWN) => if (self.cursor_y < self.rows.items.len) {
                self.cursor_y += 1;
            },
            @intFromEnum(Key.MOVE_RIGHT) => {
                if (row != null and self.cursor_row_x < row.?.len) {
                    self.cursor_row_x += 1;
                } else if (row != null and self.cursor_row_x == row.?.len) {
                    self.cursor_y += 1;
                    self.cursor_row_x = 0;
                }
            },
            @intFromEnum(Key.MOVE_LEFT) => if (self.cursor_row_x != 0) {
                self.cursor_row_x -= 1;
            } else if (self.cursor_y > 0) {
                self.cursor_y -= 1;
                self.cursor_row_x = @intCast(self.rows.items[self.cursor_y].row.items.len);
            },
            else => {},
        }
        var rowlen: usize = 0;
        if (self.cursor_y < self.rows.items.len) {
            rowlen = self.rows.items[self.cursor_y].row.items.len;
        }
        if (self.cursor_row_x > rowlen) {
            self.cursor_row_x = @intCast(rowlen);
        }
    }

    fn processKeypress(self: *Editor) !bool {
        const c: u16 = try editorReadKey();
        var quit = false;

        if (c == 0) return quit;
        switch (c) {
            ctrlKey('y') => if (self.dirty != 0) {
                self.quit_times -= 1;
                try self.setStatusMessage("WARNING!!! File has unsaved changes. Press Ctrl-Y {d} more times to quit.", .{self.quit_times});
            } else {
                quit = true;
            },
            @intFromEnum(Key.MOVE_UP), @intFromEnum(Key.MOVE_DOWN), @intFromEnum(Key.MOVE_RIGHT), @intFromEnum(Key.MOVE_LEFT) => self.moveCursor(c),
            @intFromEnum(Key.PAGE_UP), @intFromEnum(Key.PAGE_DOWN) => {
                if (c == @intFromEnum(Key.PAGE_UP)) {
                    self.cursor_y = self.row_off;
                } else if (c == @intFromEnum(Key.PAGE_DOWN)) {
                    self.cursor_y = self.row_off + self.screen_rows - 1;
                    if (self.cursor_y > self.rows.items.len) self.cursor_y = @intCast(self.rows.items.len);
                }

                var times = self.screen_rows;
                while (times > 0) : (times -= 1) {
                    self.moveCursor(if (c == @intFromEnum(Key.PAGE_UP))
                        @intFromEnum(Key.MOVE_UP)
                    else
                        @intFromEnum(Key.MOVE_DOWN));
                }
            },
            @intFromEnum(Key.HOME_KEY) => self.cursor_row_x = 0,
            @intFromEnum(Key.END_KEY) => if (self.cursor_y < self.rows.items.len) {
                self.cursor_row_x = @intCast(self.rows.items[self.cursor_y].row.items.len);
            },
            ctrlKey('s') => try self.save(),
            // TODO! implement keys
            ctrlKey('h') => {},
            ctrlKey('l') => {},
            '\r' => {},
            '\x1b' => {},
            @intFromEnum(Key.BACKSPACE) => {},
            @intFromEnum(Key.DEL_KEY) => {},
            else => try self.insertChar(@intCast(c)),
        }

        if (self.dirty > 0 and self.quit_times == 0) quit = true;
        if (c != ctrlKey('y')) self.quit_times = QUIT_TIMES;
        return quit;
    }

    fn appendRow(self: *Editor, line: []u8) !void {
        var row = Row.init(self.allocator);
        try row.row.appendSlice(line);
        try row.updateRow();
        try self.rows.append(row);
        self.dirty += 1;
    }

    fn open(self: *Editor, filepath: []u8) !void {
        try self.file_name.appendSlice(filepath);

        // Wow I can actually write zig code
        const file = std.fs.cwd().openFile(filepath, .{ .mode = .read_only }) catch |err| file: {
            switch (err) {
                error.FileNotFound => {
                    break :file try std.fs.cwd().createFile(filepath, .{ .read = true });
                },
                else => return err,
            }
        };
        defer file.close();

        var buffer: [1000]u8 = undefined;

        while (try file.reader().readUntilDelimiterOrEof(buffer[0..], '\n')) |line| {
            try self.appendRow(line);
        }
        self.dirty = 0;
    }

    fn scroll(self: *Editor) void {
        self.cursor_render_x = 0;

        if (self.cursor_y < self.rows.items.len) {
            self.cursor_render_x = self.rowCursorToRenderCursor(self.rows.items[self.cursor_y]);
        }

        if (self.cursor_y < self.row_off) {
            self.row_off = self.cursor_y;
        }

        if (self.cursor_y >= self.row_off + self.screen_rows) {
            self.row_off = self.cursor_y - self.screen_rows + 1;
        }

        if (self.cursor_render_x < self.col_off) {
            self.col_off = self.cursor_render_x;
        }

        if (self.cursor_render_x >= self.col_off + self.screen_cols) {
            self.col_off = self.cursor_render_x - self.screen_cols + 1;
        }
    }

    fn rowCursorToRenderCursor(self: Editor, row: Row) u16 {
        var render_cursor: u16 = 0;

        for (0..self.cursor_row_x) |i| {
            if (row.row.items[i] == '\t') render_cursor += (TAB_STOP - 1) - (render_cursor % TAB_STOP);
            render_cursor += 1;
        }

        return render_cursor;
    }

    fn insertChar(self: *Editor, char: u8) !void {
        if (self.cursor_y == self.rows.items.len) try self.appendRow("");
        try self.rows.items[self.cursor_y].insertChar(self.cursor_row_x, char);
        self.cursor_row_x += 1;
        self.dirty += 1;
    }

    fn rowsToString(self: *Editor) !std.ArrayList(u8) {
        var buffer = std.ArrayList(u8).init(self.allocator);
        for (0..self.rows.items.len) |i| {
            try buffer.appendSlice(self.rows.items[i].row.items);
            try buffer.append('\n');
        }
        return buffer;
    }

    fn save(self: *Editor) !void {
        if (self.file_name.items.len == 0) return;

        const buffer = try self.rowsToString();
        defer buffer.deinit();

        const file = try std.fs.cwd().openFile(self.file_name.items, .{ .mode = .write_only });
        defer file.close();

        const written = try file.write(buffer.items);
        if (written != buffer.items.len) return error.WriteReturnedNotEqual;

        try self.setStatusMessage("{d} bytes written to disk", .{written});
        self.dirty = 0;
    }
};

fn ctrlKey(key: u8) u8 {
    return key & 0x1f;
}

fn editorReadKey() !u16 {
    var buffer: u8 = undefined;

    if (stdin.reader().readByte()) |key| buffer = key else |_| buffer = 0;

    if (buffer == '\x1b') {
        var seq: [3]u8 = undefined;

        if (try stdin.reader().read(seq[0..1]) != 1) return '\x1b';
        if (try stdin.reader().read(seq[1..2]) != 1) return '\x1b';

        if (seq[0] == '[') {
            if (seq[1] >= '0' and seq[1] <= '9') {
                if (try stdin.reader().read(seq[2..3]) != 1) return '\x1b';
                if (seq[2] == '~') {
                    switch (seq[1]) {
                        '1' => return @intFromEnum(Key.HOME_KEY),
                        '3' => return @intFromEnum(Key.DEL_KEY),
                        '4' => return @intFromEnum(Key.END_KEY),
                        '5' => return @intFromEnum(Key.PAGE_UP),
                        '6' => return @intFromEnum(Key.PAGE_DOWN),
                        '7' => return @intFromEnum(Key.HOME_KEY),
                        '8' => return @intFromEnum(Key.END_KEY),
                        else => return '\x1b',
                    }
                }
            } else {
                switch (seq[1]) {
                    'A' => return @intFromEnum(Key.MOVE_UP),
                    'B' => return @intFromEnum(Key.MOVE_DOWN),
                    'C' => return @intFromEnum(Key.MOVE_RIGHT),
                    'D' => return @intFromEnum(Key.MOVE_LEFT),
                    'H' => return @intFromEnum(Key.HOME_KEY),
                    'F' => return @intFromEnum(Key.END_KEY),
                    else => return '\x1b',
                }
            }
        } else if (seq[0] == 'O') {
            switch (seq[1]) {
                'H' => return @intFromEnum(Key.HOME_KEY),
                'F' => return @intFromEnum(Key.END_KEY),
                else => return '\x1b',
            }
        }
    }
    return buffer;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.detectLeaks();
    const allocator = gpa.allocator();

    var editor = Editor.init(allocator);
    defer editor.file_name.deinit();

    try editor.setStatusMessage("HELP: Ctrl-s = save | Ctrl-Y = quit", .{});

    try editor.enableRawMode();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len > 1) try editor.open(args[1]);

    while (!try editor.processKeypress()) {
        try editor.refreshScreen();
    }

    // TODO! handle the other errors or refactor disableRawMode to not return an err so I can defer it
    try editor.disableRawMode();
    try stdout.writer().writeAll("\x1b[2J");
    try stdout.writer().writeAll("\x1b[H");

    for (editor.rows.items) |*row| row.deinit();
    editor.rows.deinit();
}
