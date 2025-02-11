const std = @import("std");
const posix = std.posix;
const stdin = std.io.getStdIn();
const stdout = std.io.getStdOut();

const Editor = struct {
    in: std.fs.File,
    origin_termios: ?posix.termios,
    version: []const u8,
    rows: u16,
    cols: u16,
    cursor_x: u16,
    cursor_y: u16,

    pub fn init() !Editor {
        var editor = Editor {
            .in = stdin,
            .version = "0.0.1",
            .origin_termios = null,
            .rows = 0,
            .cols = 0,
            .cursor_x = 0,
            .cursor_y = 0,
        };

        // TODO! handle the return value
        _ = try editor.getWindowSize();

        return editor;
    }

    // Thank you https://codeberg.org/zenith-editor/zenith
    // I tried for an hour to get this to work using os.linux but couldn't
    // Thanks for showing me std.posix
    pub fn enableRawMode(self: *Editor) !void {
        var raw = try posix.tcgetattr(self.in.handle);

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

        // TODO! this feels wrong
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
            self.rows = win_size.ws_row;
            self.cols = win_size.ws_col;
        }

        return 0;
    }

    fn editorRefreshScreen(self: Editor, allocator: std.mem.Allocator) !void {
        var buffer = std.ArrayList(u8).init(allocator);
        defer buffer.deinit();

        var writer = buffer.writer();

        try writer.writeAll("\x1b[?25l");
        try writer.writeAll("\x1b[H");

        try self.editorDrawRows(writer);

        // TODO! find a better way to format strings.
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        const string_allocator = gpa.allocator();

        const move_cursor = try std.fmt.allocPrint(string_allocator, 
            "\x1b[{d};{d}H", .{self.cursor_y + 1, self.cursor_x + 1});
        defer string_allocator.free(move_cursor);
        try writer.writeAll(move_cursor);

        try writer.writeAll("\x1b[?25h");
        
        try stdout.writer().writeAll(buffer.items);
    }

    fn editorDrawRows(self: Editor, writer: anytype) !void {
        for (0..self.rows) |i| {

            if (i == self.rows / 3) {
                // TODO! find a better way to format strings.
                var gpa = std.heap.GeneralPurposeAllocator(.{}){};
                const allocator = gpa.allocator();

                var welcome = try std.fmt.allocPrint(allocator, 
                    "Zilo Editor -- version {s}", .{self.version});
                defer allocator.free(welcome);

                if (welcome.len > self.cols) welcome = welcome[0..self.cols];
                
                var padding = (self.cols - welcome.len) / 2;
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

            try writer.writeAll("\x1b[K");
            if (i < self.rows - 1) {
                try writer.writeAll("\r\n");
            }
        }
    }

    fn moveCursor(self: *Editor, key: u8) void {
        switch (key) {
            'w' => self.cursor_y -= 1,
            'a' => self.cursor_x -= 1,
            's' => self.cursor_y += 1,
            'd' => self.cursor_x += 1,
            else => {}
        }
    }
};

fn ctrlKey(key: u8) u8 {
    return key & 0x1f;
}

fn editorReadKey() !u8 {
    var buffer: [1]u8 = undefined;
    _ = try stdin.reader().read(&buffer);
    return buffer[0];
}

// TODO! move this to a method of Editor.
fn editorProcessKeypress(editor: *Editor) !bool {
    const c = try editorReadKey();

    switch (c) {
        ctrlKey('q') => return false,
        // TODO! find a way to colapse these into one case.
        'w' => editor.moveCursor(c),
        'a' => editor.moveCursor(c),
        's' => editor.moveCursor(c),
        'd' => editor.moveCursor(c),
        else => {}
    }

    return true;
}

fn onExit() !void {
    try stdout.writer().writeAll("\x1b[2J");
    try stdout.writer().writeAll("\x1b[H");
}


pub fn main() !void {
    // TODO! add this to the editor struct?
    // Don't know how I feel about having an allocator as a struct field.
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var editor = try Editor.init();

    try editor.enableRawMode();

    while (try editorProcessKeypress(&editor)) {
        try editor.editorRefreshScreen(allocator);
    }

    try editor.disableRawMode();

    try onExit();
}
