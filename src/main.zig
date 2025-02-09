const std = @import("std");
const posix = std.posix;
const stdin = std.io.getStdIn();

const Editor = struct {
    in: std.fs.File,
    origin_termios: ?posix.termios,

    pub fn new() Editor {
        return Editor {
            .in = stdin,
            .origin_termios = null
        };
    }

    // Thank you https://codeberg.org/zenith-editor/zenith
    // I tried for an hour to get this to work using os.linux but couldn't
    // Thanks for showing me std.posix
    pub fn enable_raw_mode(self: *Editor) !void {
        var raw = try posix.tcgetattr(self.in.handle);
        self.origin_termios = raw;

        raw.lflag.ECHO = false;

        try posix.tcsetattr(stdin.handle, posix.TCSA.FLUSH, raw);
    }

    pub fn disable_raw_mode(self: *Editor) !void {
        if (self.origin_termios) |origin_termios| {
            try posix.tcsetattr(stdin.handle, posix.TCSA.FLUSH, origin_termios);
        }
    }
};

pub fn main() !void {
    var editor = Editor.new();
    try editor.enable_raw_mode();

    var buffer: [1]u8 = undefined;
    while (true) {
        const n = try stdin.reader().read(&buffer);

        if (n != 1 or buffer[0] == 'q') break;
    } 

    try editor.disable_raw_mode();
}
