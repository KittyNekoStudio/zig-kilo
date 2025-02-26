// TODO! look into inline loops for string formating
const std = @import("std");
const posix = std.posix;
const stdin = std.io.getStdIn();
const stdout = std.io.getStdOut();

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var editor = Editor.init(allocator);
    defer editor.filename.deinit();

    try editor.setStatusMessage("HELP: Ctrl-s = save | Ctrl-Q = quit | Ctrl-F = search", .{});

    try editor.enableRawMode();
    defer editor.disableRawMode();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len > 1) try editor.open(args[1]);

    while (!try editor.processKeypress()) {
        try editor.refreshScreen();
    }

    // TODO! handle the other errors or refactor disableRawMode to not return an err so I can defer it
    try stdout.writer().writeAll("\x1b[2J");
    try stdout.writer().writeAll("\x1b[H");

    for (editor.rows.items) |*row| row.deinit();
    editor.rows.deinit();
}

const VERSION = "0.0.1";
const QUIT_TIMES = 3;
const TAB_STOP = 8;
const HIGHLIGHT_NUMBERS = 1 << 0;
const HIGHLIGHT_STRINGS = 1 << 1;
const HIGHLIGHT_FLAGS = packed struct {
    number: bool = false,
    string: bool = false,
};
const ZIG_FILE_EXTENSIONS = [_][]const u8{"zig"};

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

const Highlight = enum(u8) {
    NORMAL = 1,
    COMMENT,
    KEYWORD1,
    KEYWORD2,
    STRING,
    NUMBER,
    MATCH,
};

const Syntax = struct {
    filetype: []const u8,
    filematch: []const []const u8,
    single_line_comment_start: []const u8,
    keywords: []const []const u8,
    flags: HIGHLIGHT_FLAGS,
};

const Row = struct {
    row: std.ArrayList(u8),
    render: std.ArrayList(u8),
    highlight: std.ArrayList(Highlight),

    pub fn init(allocator: std.mem.Allocator) Row {
        return Row{
            .row = std.ArrayList(u8).init(allocator),
            .render = std.ArrayList(u8).init(allocator),
            .highlight = std.ArrayList(Highlight).init(allocator),
        };
    }

    pub fn deinit(self: Row) void {
        self.row.deinit();
        self.render.deinit();
        self.highlight.deinit();
    }

    fn updateRow(self: *Row, editor: Editor) !void {
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
        try self.updateSyntax(editor);
    }

    fn insertChar(self: *Row, at: usize, char: u8, editor: Editor) !void {
        var at_in = at;
        if (at_in < 0 or at_in > self.row.items.len) at_in = self.row.items.len;
        try self.row.insert(at_in, char);
        try self.updateRow(editor);
    }

    fn delChar(self: *Row, at: usize, editor: Editor) !void {
        if (at < 0 or at >= self.row.items.len) return;
        _ = self.row.orderedRemove(at);
        try self.updateRow(editor);
    }

    fn freeRow(self: *Row) void {
        self.row.deinit();
        self.render.deinit();
        self.highlight.deinit();
    }

    fn appendString(self: *Row, string: []const u8, editor: Editor) !void {
        try self.row.appendSlice(string);
        try self.updateRow(editor);
    }

    fn updateSyntax(self: *Row, editor: Editor) !void {
        self.highlight.clearAndFree();
        try self.highlight.appendNTimes(Highlight.NORMAL, self.render.items.len);

        if (editor.syntax == null) return;

        const keywords = editor.syntax.?.keywords;
        const scs = editor.syntax.?.single_line_comment_start;

        var previous_sep = true;
        var in_string: u8 = 0;

        var i: usize = 0;
        while (i < self.render.items.len) {
            const char = self.render.items[i];
            const previous_highlight = if (i > 0) self.highlight.items[i - 1] else Highlight.NORMAL;

            if (scs.len > 0 and in_string == 0 and self.render.items.len > i + scs.len) {
                if (std.mem.eql(u8, self.render.items[i .. i + scs.len], scs)) {
                    @memset(self.highlight.items[i..self.render.items.len], Highlight.COMMENT);
                    break;
                }
            }

            if (editor.syntax.?.flags.string) {
                if (in_string > 0) {
                    self.highlight.items[i] = Highlight.STRING;
                    if (char == '\\' and i + 1 < self.render.items.len) {
                        self.highlight.items[i + 1] = Highlight.STRING;
                        i += 2;
                        continue;
                    }
                    if (char == in_string) in_string = 0;
                    previous_sep = true;
                    i += 1;
                    continue;
                } else {
                    if (char == '"' or char == '\'') {
                        in_string = char;
                        self.highlight.items[i] = Highlight.STRING;
                        i += 1;
                        continue;
                    }
                }
            }

            if (editor.syntax.?.flags.number) {
                if (std.ascii.isDigit(char)) {
                    if ((previous_sep or previous_highlight == Highlight.NUMBER) or (char == '.' and previous_highlight == Highlight.NUMBER)) {
                        self.highlight.items[i] = Highlight.NUMBER;
                        previous_sep = false;
                        i += 1;
                        continue;
                    }
                }
            }

            if (previous_sep) {
                var x: usize = 0;
                while (x < keywords.len) : (x += 1) {
                    const keyword = keywords[x];
                    var keyword_len = keyword.len;

                    const is_keyword2 = keyword[keyword_len - 1] == '|';
                    if (is_keyword2) keyword_len -= 1;

                    // TODO! there is something wrong with the sperator before the keyword
                    if (i + keyword_len < self.render.items.len and std.mem.eql(u8, self.render.items[i .. i + keyword_len], keyword[0..keyword_len]) and isSeperator(self.render.items[i + keyword_len])) {
                        @memset(self.highlight.items[i .. i + keyword_len], if (is_keyword2) Highlight.KEYWORD2 else Highlight.KEYWORD1);
                        i += keyword_len;
                        break;
                    }
                }
                if (x != keywords.len - 1) {
                    previous_sep = false;
                    continue;
                }
            }

            previous_sep = isSeperator(char);
            i += 1;
        }
    }
};

const Editor = struct {
    origin_termios: ?posix.termios,
    screen_rows: u16,
    screen_cols: u16,
    cursor_row_x: u16,
    cursor_render_x: u16,
    cursor_y: u16,
    filename: std.ArrayList(u8),
    status_message: [1024]u8,
    status_message_time: i64,
    rows: std.ArrayList(Row),
    dirty: usize,
    // TODO! are there static variables in zig?
    quit_times: u8,
    row_off: u16,
    col_off: u16,
    allocator: std.mem.Allocator,
    syntax: ?Syntax,

    pub fn init(allocator: std.mem.Allocator) Editor {
        var editor = Editor{
            .origin_termios = null,
            .screen_rows = 0,
            .screen_cols = 0,
            .cursor_row_x = 0,
            .cursor_render_x = 0,
            .cursor_y = 0,
            .filename = std.ArrayList(u8).init(allocator),
            .status_message = undefined,
            .status_message_time = 0,
            .rows = std.ArrayList(Row).init(allocator),
            .dirty = 0,
            .quit_times = QUIT_TIMES,
            .row_off = 0,
            .col_off = 0,
            .allocator = allocator,
            .syntax = null,
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

    pub fn disableRawMode(self: *Editor) void {
        if (self.origin_termios) |origin_termios| {
            posix.tcsetattr(stdin.handle, posix.TCSA.FLUSH, origin_termios) catch {
                std.debug.print("Failed at tcsetattr in disableRawMode. Restart terminal.\n", .{});
                return;
            };
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
                const chars = self.rows.items[filerow].render.items;
                const highlight = self.rows.items[filerow].highlight.items;
                var current_color: u8 = 0;
                if (len != 0) {
                    for (self.col_off..self.col_off + len) |i| {
                        if (highlight[i] == Highlight.NORMAL) {
                            if (current_color != 0) {
                                try writer.writeAll("\x1b[39m");
                                current_color = 0;
                            }
                        } else {
                            const color = syntaxToColor(highlight[i]);
                            if (color != current_color) {
                                current_color = color;
                                const string = try std.fmt.allocPrint(self.allocator, "\x1b[{d}m", .{color});
                                defer self.allocator.free(string);
                                try writer.writeAll(string);
                            }
                        }
                        try writer.writeByte(chars[i]);
                    }
                }
                try writer.writeAll("\x1b[39m");
            }
            try writer.writeAll("\x1b[K");
            try writer.writeAll("\r\n");
        }
    }

    fn drawStatusBar(self: Editor, writer: anytype) !void {
        try writer.writeAll("\x1b[7m");

        var status = try std.fmt.allocPrint(self.allocator, "{s} - {d} lines {s}", .{ if (self.filename.items.len == 0) "[No Name]" else self.filename.items, self.rows.items.len, if (self.dirty != 0) "(modified)" else "" });
        defer self.allocator.free(status);

        const rstatus = try std.fmt.allocPrint(self.allocator, "{s} | {d}/{d} ", .{ if (self.syntax) |syntax| syntax.filetype else "no ft", self.cursor_y + 1, self.rows.items.len });
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
            '\r' => try self.insertNewLine(),
            ctrlKey('q') => if (self.dirty != 0) {
                self.quit_times -= 1;
                try self.setStatusMessage("WARNING!!! File has unsaved changes. Press Ctrl-Q {d} more times to quit.", .{self.quit_times});
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
            ctrlKey('s') => {
                try self.save();
            },
            ctrlKey('f') => try self.find(),
            ctrlKey('h'), @intFromEnum(Key.BACKSPACE), @intFromEnum(Key.DEL_KEY) => {
                if (c == @intFromEnum(Key.DEL_KEY)) self.moveCursor(@intFromEnum(Key.MOVE_RIGHT));
                try self.delChar();
            },
            ctrlKey('l') => {},
            '\x1b' => {},
            else => try self.insertChar(@intCast(c)),
        }

        if (self.dirty > 0 and self.quit_times == 0) quit = true;
        if (c != ctrlKey('q')) self.quit_times = QUIT_TIMES;
        return quit;
    }

    fn insertRow(self: *Editor, line: []u8, at: usize) !void {
        if (at < 0 or at > self.rows.items.len) return;

        var row = Row.init(self.allocator);
        try row.row.appendSlice(line);
        try row.updateRow(self.*);
        try self.rows.insert(at, row);
        self.dirty += 1;
    }

    fn open(self: *Editor, filepath: []u8) !void {
        try self.filename.appendSlice(filepath);

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

        var buffer: [10000]u8 = undefined;

        self.updateFileDescriptor();

        while (try file.reader().readUntilDelimiterOrEof(buffer[0..], '\n')) |line| {
            try self.insertRow(line, self.rows.items.len);
            // Overflows if file is to long and assigning dirty to zero is outside of loop
            self.dirty = 0;
        }
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

    // TODO! make this not a method
    fn renderCursorToRowCursor(self: Editor, row: std.ArrayList(u8), rx: usize) u16 {
        var current_cursor: u16 = 0;
        _ = self;

        for (0..row.items.len) |cx| {
            if (row.items[cx] == '\t') current_cursor += (TAB_STOP - 1) - (current_cursor % TAB_STOP);
            current_cursor += 1;

            if (current_cursor > rx) return @intCast(cx);
        }

        return current_cursor;
    }

    fn insertChar(self: *Editor, char: u8) !void {
        if (self.cursor_y == self.rows.items.len) try self.insertRow("", 0);
        try self.rows.items[self.cursor_y].insertChar(self.cursor_row_x, char, self.*);
        self.cursor_row_x += 1;
        self.dirty += 1;
    }

    fn insertNewLine(self: *Editor) !void {
        if (self.cursor_row_x == 0) {
            try self.insertRow("", self.cursor_y);
        } else {
            const row = self.rows.items[self.cursor_y];
            const end = row.row.items.len;
            try self.insertRow(row.row.items[self.cursor_row_x..end], self.cursor_y + 1);
            try self.rows.items[self.cursor_y].row.resize(self.cursor_row_x);
            try self.rows.items[self.cursor_y].updateRow(self.*);
        }

        self.cursor_y += 1;
        self.cursor_row_x = 0;
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
        if (self.filename.items.len == 0) if (try self.promt("Save as: {s} (ESC to cancel)", null)) |filename| {
            self.filename.deinit();
            self.filename = filename;
            self.updateFileDescriptor();
            for (self.rows.items) |*row| try row.updateSyntax(self.*);
        } else {
            try self.setStatusMessage("Save aborted", .{});
            return;
        };

        const buffer = try self.rowsToString();
        defer buffer.deinit();

        const file = try std.fs.cwd().createFile(self.filename.items, .{ .read = false });
        defer file.close();

        const written = try file.write(buffer.items);
        if (written != buffer.items.len) return error.WriteReturnedNotEqual;

        try self.setStatusMessage("{d} bytes written to disk", .{written});
        self.dirty = 0;
    }

    fn delChar(self: *Editor) !void {
        if (self.cursor_y == self.rows.items.len) return;
        if (self.cursor_row_x == 0 and self.cursor_y == 0) return;

        var row = &self.rows.items[self.cursor_y];
        if (self.cursor_row_x > 0) {
            try row.delChar(self.cursor_row_x - 1, self.*);
            self.cursor_row_x -= 1;
        } else {
            self.cursor_row_x = @intCast(self.rows.items[self.cursor_y - 1].row.items.len);
            try self.rows.items[self.cursor_y - 1].appendString(row.row.items, self.*);
            try self.delRow(self.cursor_y);
            self.cursor_y -= 1;
        }

        self.dirty += 1;
    }

    fn delRow(self: *Editor, at: usize) !void {
        if (at < 0 or at >= self.rows.items.len) return;

        _ = &self.rows.items[at].freeRow();
        _ = self.rows.orderedRemove(at);

        self.dirty += 1;
    }

    fn promt(self: *Editor, comptime promt_message: []const u8, callback: ?*const fn (editor: *Editor, query: []u8, key: u16) std.mem.Allocator.Error!void) !?std.ArrayList(u8) {
        var buffer = std.ArrayList(u8).init(self.allocator);

        while (true) {
            try self.setStatusMessage(promt_message, .{buffer.items});
            try self.refreshScreen();

            const c = try editorReadKey();

            // Catches when no input is recived, otherwise cursor goes to top of file
            if (c == 0) continue;

            // TODO! switch on c instead of else if chain
            if (c == @intFromEnum(Key.DEL_KEY) or c == ctrlKey('h') or c == @intFromEnum(Key.BACKSPACE)) {
                if (buffer.items.len != 0) _ = buffer.pop();
            } else if (c == '\x1b') {
                try self.setStatusMessage("", .{});
                if (callback) |callback_inside| try callback_inside(self, buffer.items, c);
                buffer.deinit();
                return null;
            } else if (c == '\r') {
                if (buffer.items.len != 0) {
                    try self.setStatusMessage("", .{});
                    if (callback) |callback_inside| try callback_inside(self, buffer.items, c);
                    return buffer;
                }
            } else if (!std.ascii.isControl(@truncate(c)) and c < 128) {
                try buffer.append(@intCast(c));
            }
            if (callback) |callback_inside| try callback_inside(self, buffer.items, c);
        }
    }

    fn find(self: *Editor) !void {
        const saved_cursor_y = self.cursor_y;
        const saved_cursor_row_x = self.cursor_row_x;
        const saved_col_off = self.col_off;
        const saved_row_off = self.row_off;

        const query = try self.promt("Search: {s} (Use ESC/Arrows/Enter)", findCallback) orelse {
            self.cursor_y = saved_cursor_y;
            self.cursor_row_x = saved_cursor_row_x;
            self.col_off = saved_col_off;
            self.row_off = saved_row_off;
            return;
        };
        defer query.deinit();
    }

    fn findCallback(self: *Editor, query: []u8, key: u16) std.mem.Allocator.Error!void {
        const state = struct {
            var last_match: i32 = -1;
            var direction: i32 = 1;
            var saved_hl_line: i32 = undefined;
            var saved_hl: ?[]Highlight = null;
        };

        if (state.saved_hl) |saved_hl| {
            std.mem.copyForwards(Highlight, self.rows.items[@intCast(state.saved_hl_line)].highlight.items, saved_hl);
            self.allocator.free(saved_hl);
            state.saved_hl = null;
        }

        if (key == '\r' or key == '\x1b') {
            state.last_match = -1;
            state.direction = 1;
            return;
        } else if (key == @intFromEnum(Key.MOVE_UP) or key == @intFromEnum(Key.MOVE_LEFT)) {
            state.direction = -1;
        } else if (key == @intFromEnum(Key.MOVE_DOWN) or key == @intFromEnum(Key.MOVE_RIGHT)) {
            state.direction = 1;
        } else {
            state.last_match = -1;
            state.direction = 1;
        }

        if (state.last_match == -1) state.direction = 1;
        var current: i32 = state.last_match;

        for (0..self.rows.items.len) |_| {
            current += state.direction;

            if (current == -1) {
                current = @intCast(self.rows.items.len - 1);
            } else if (current == self.rows.items.len) {
                current = 0;
            }

            const row = self.rows.items[@intCast(current)];
            const match = std.mem.indexOf(u8, row.render.items, query);

            if (match != null) {
                state.last_match = current;
                self.cursor_y = @intCast(current);
                self.cursor_row_x = self.renderCursorToRowCursor(row.row, match.?);
                self.row_off = @intCast(self.rows.items.len);

                state.saved_hl_line = current;
                state.saved_hl = try self.allocator.alloc(Highlight, row.render.items.len);
                std.mem.copyForwards(Highlight, state.saved_hl.?, row.highlight.items);

                @memset(row.highlight.items[match.? .. match.? + query.len], Highlight.MATCH);
                break;
            }
        }
    }

    fn updateFileDescriptor(self: *Editor) void {
        if (self.filename.items.len != 0) {
            if (std.mem.endsWith(u8, self.filename.items, ".zig")) {
                self.syntax = .{ .filetype = "zig", .filematch = &ZIG_FILE_EXTENSIONS, .single_line_comment_start = "//", .keywords = &.{
                    "fn",    "if",    "else",  "break",  "while", "for",   "switch", "return", "var",  "const", "enum",   "error", "struct",
                    "union", "catch", "defer", "try",    "pub",   "u8|",   "u16|",   "u32|",   "u64|", "u128|", "usize|", "i8|",   "i16|",
                    "i32|",  "i64|",  "i128|", "isize|", "bool|", "void|", "!void|", "f8|",    "f16|", "f32|",  "f64|",   "f128|", "null|",
                }, .flags = HIGHLIGHT_FLAGS{ .number = true, .string = true } };
            }
        }
    }
};

fn ctrlKey(key: u8) u8 {
    return key & 0x1f;
}

// TODO! change this to return u8
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

fn syntaxToColor(highlight: Highlight) u8 {
    switch (highlight) {
        .COMMENT => return 36,
        .KEYWORD1 => return 31,
        .KEYWORD2 => return 33,
        .STRING => return 35,
        .NUMBER => return 32,
        .MATCH => return 34,
        .NORMAL => return 37,
    }
}

fn isSeperator(char: u8) bool {
    const seperators = ",.()+-/*=~%<>[];";
    //const seperators = [15]u8{',', '.', '(', ')', '+', '-', '*', '=', '~', '%', '<', '>', '[', ']', ';'};
    return std.ascii.isWhitespace(char) or seperator: {
        for (seperators) |seperator| {
            if (char == seperator) break :seperator true;
        }
        break :seperator false;
    };
}
