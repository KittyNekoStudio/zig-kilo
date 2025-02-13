// TODO! look into inline loops for string formating
const std = @import("std");
const posix = std.posix;
const stdin = std.io.getStdIn();
const stdout = std.io.getStdOut();

const Movement = enum(u16) {
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

const Editor = struct {
    origin_termios: ?posix.termios,
    version: []const u8,
    screen_rows: u16,
    screen_cols: u16,
    cursor_x: u16,
    cursor_y: u16,
    numrows: u16,
    row: []u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !*Editor {
        var editor = try allocator.create(Editor);
        editor.* = .{
            .version = "0.0.1",
            .origin_termios = null,
            .screen_rows = 0,
            .screen_cols = 0,
            .cursor_x = 0,
            .cursor_y = 0,
            .numrows = 0,
            .row = undefined,
            .allocator = allocator,
        };

        // TODO! handle the return value
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
        var win_size = std.posix.system.winsize{.ws_col = 0, .ws_row = 0,
            .ws_xpixel = 0, .ws_ypixel = 0};

        if (std.posix.system.ioctl(stdout.handle, 
                posix.system.T.IOCGWINSZ, @intFromPtr(&win_size)) == -1
            or win_size.ws_col == 0) {
                return -1;
        } else {
            self.screen_rows = win_size.ws_row;
            self.screen_cols = win_size.ws_col;
        }

        return 0;
    }

    fn editorRefreshScreen(self: Editor) !void {
        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();

        var writer = buffer.writer();

        try writer.writeAll("\x1b[?25l");
        try writer.writeAll("\x1b[H");

        try self.drawRows(writer);

        // TODO! find a better way to format strings.

        const move_cursor = try std.fmt.allocPrint(self.allocator, 
            "\x1b[{d};{d}H", .{self.cursor_y + 1, self.cursor_x + 1});
        defer self.allocator.free(move_cursor);
        try writer.writeAll(move_cursor);

        try writer.writeAll("\x1b[?25h");
        
        try stdout.writer().writeAll(buffer.items);
    }

    fn drawRows(self: Editor, writer: anytype) !void {
        for (0..self.screen_rows) |y| {
            if (y >= self.numrows) {
                if (self.numrows == 0 and y == self.screen_rows / 3) {
                    var welcome = try std.fmt.allocPrint(self.allocator, 
                        "Zilo Editor -- version {s}", .{self.version});
                    defer self.allocator.free(welcome);

                    if (welcome.len > self.screen_cols) welcome
                        = welcome[0..self.screen_cols];
                    
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
                var len = self.row.len;
                if (len > self.screen_cols) len = self.screen_cols;

                const string = try std.fmt.allocPrint(self.allocator, "{s}",
                    .{self.row[0..len]});
                defer self.allocator.free(string);
                try writer.writeAll(string);
            }
            try writer.writeAll("\x1b[K");
            if (y < self.screen_rows - 1) {
                try writer.writeAll("\r\n");
            }
        }
    }

    fn moveCursor(self: *Editor, key: u16) void {
        switch (key) {
            @intFromEnum(Movement.MOVE_UP)    => if (self.cursor_y != 0) {self.cursor_y -= 1;},
            @intFromEnum(Movement.MOVE_DOWN)  => if (self.cursor_y != self.screen_rows - 1) {self.cursor_y += 1;},
            @intFromEnum(Movement.MOVE_RIGHT) => if (self.cursor_x != self.screen_cols - 1) {self.cursor_x += 1;},
            @intFromEnum(Movement.MOVE_LEFT)  => if (self.cursor_x != 0) {self.cursor_x -= 1;},
            else => {}
        }
    }

    fn processKeypress(self: *Editor) !bool {
        const c: u16 = try editorReadKey();

        switch (c) {
            ctrlKey('q') => return false,
            @intFromEnum(Movement.MOVE_UP),
            @intFromEnum(Movement.MOVE_DOWN),
            @intFromEnum(Movement.MOVE_RIGHT),
            @intFromEnum(Movement.MOVE_LEFT) => self.moveCursor(c),
            @intFromEnum(Movement.PAGE_UP),
            @intFromEnum(Movement.PAGE_DOWN) => {
                // TODO! clean this up.
                var times = self.screen_rows;
                while(times > 0) : (times -= 1) {
                    const move = if (c == @intFromEnum(Movement.PAGE_UP)) @intFromEnum(Movement.MOVE_UP)
                        else @intFromEnum(Movement.MOVE_DOWN);

                    self.moveCursor(move);
                }
            },
            @intFromEnum(Movement.HOME_KEY) => self.cursor_x = 0,
            @intFromEnum(Movement.END_KEY) => self.cursor_x = self.screen_cols - 1,
            else => {},
        }
        return true;
    }

    fn open(self: *Editor, filepath: []const u8) !void {
       const file = try std.fs.cwd().openFile(filepath, .{.mode = .read_only});
        defer file.close();
            self.row = try file.reader()
                .readUntilDelimiterAlloc(self.allocator, '\n', 1024 * 1024);
            self.numrows = 1;

    }
};

fn ctrlKey(key: u8) u8 {
    return key & 0x1f;
}

fn editorReadKey() !u16 {
    var buffer: [1]u8 = undefined;
    _ = try stdin.reader().read(&buffer);

    if (buffer[0] == '\x1b') {
        var seq: [3]u8 = undefined;

        if (try stdin.reader().read(seq[0..1]) != 1) return '\x1b';
        if (try stdin.reader().read(seq[1..2]) != 1) return '\x1b';

        if (seq[0] == '[') {
            if (seq[1] >= '0' and seq[1] <= '9') {
                if (try stdin.reader().read(seq[2..3]) != 1) return '\x1b';
                if (seq[2] == '~') {
                        switch (seq[1]) {
                            '1'  => return @intFromEnum(Movement.HOME_KEY),
                            '3'  => return @intFromEnum(Movement.DEL_KEY),
                            '4'  => return @intFromEnum(Movement.END_KEY),
                            '5'  => return @intFromEnum(Movement.PAGE_UP),
                            '6'  => return @intFromEnum(Movement.PAGE_DOWN),
                            '7'  => return @intFromEnum(Movement.HOME_KEY),
                            '8'  => return @intFromEnum(Movement.END_KEY),
                            else => return '\x1b',
                    }
                }
            } else {
                switch (seq[1]) {
                    'A'  => return @intFromEnum(Movement.MOVE_UP),
                    'B'  => return @intFromEnum(Movement.MOVE_DOWN),
                    'C'  => return @intFromEnum(Movement.MOVE_RIGHT),
                    'D'  => return @intFromEnum(Movement.MOVE_LEFT),
                    'H'  => return @intFromEnum(Movement.HOME_KEY),
                    'F'  => return @intFromEnum(Movement.END_KEY),
                    else => return '\x1b',
                }
            } 
        } else if (seq[0] == 'O') {
            switch (seq[1]) {
                'H'  => return @intFromEnum(Movement.HOME_KEY),
                'F'  => return @intFromEnum(Movement.END_KEY),
                else => return '\x1b',
            }
        }
    }
    return buffer[0];
}

fn onExit() !void {
    try stdout.writer().writeAll("\x1b[2J");
    try stdout.writer().writeAll("\x1b[H");
}


pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // TODO! change to argsWithAllocator
        defer {
        const mem_leak = gpa.deinit();
        switch (mem_leak) {
            .ok => std.debug.print("No memory leak.\n", .{}),
            .leak => std.debug.print("Memory was leaked.", .{}),
        }
    }

    var editor = try Editor.init(allocator);
    defer allocator.destroy(editor);

    var args = try std.process.argsWithAllocator(allocator);
    defer std.process.ArgIterator.deinit(&args);

    try editor.enableRawMode();

    _ = args.skip();
    if (args.next()) |filepath| try editor.open(filepath);

    while (try editor.processKeypress()) {
        try editor.editorRefreshScreen();
    }

    try editor.disableRawMode();

    // TODO! seems a little weird to check based on lenght.
    if (editor.row.len != undefined) allocator.free(editor.row);

    try onExit();
}
