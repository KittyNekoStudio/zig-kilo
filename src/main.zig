const std = @import("std");
const posix = std.posix;
const stdin = std.io.getStdIn();
const stdout = std.io.getStdOut();

const Editor = struct {
    in: std.fs.File,
    origin_termios: ?posix.termios,
    rows: u16,
    cols: u16,

    pub fn init() !Editor {
        var editor = Editor {
            .in = stdin,
            .origin_termios = null,
            .rows = 0,
            .cols = 0,
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

        try writer.writeAll("\x1b[2J");
        try writer.writeAll("\x1b[H");

        try self.editorDrawRows(writer);
        try writer.writeAll("\x1b[H");
        
        try stdout.writer().writeAll(buffer.items);
    }

    fn editorDrawRows(self: Editor, writer: anytype) !void {
        for (0..self.rows) |i| {
            try writer.writeAll("~");
            if (i < self.rows - 1) {
                try writer.writeAll("\r\n");
            }
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

fn editorProcessKeypress() !bool {
    const c = try editorReadKey();

    switch (c) {
        ctrlKey('q') => return false,
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

    while (try editorProcessKeypress()) {
        try editor.editorRefreshScreen(allocator);
    }

    try editor.disableRawMode();

    try onExit();
}
