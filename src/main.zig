const std = @import("std");
const posix = std.posix;
const stdin = std.io.getStdIn();
const stdout = std.io.getStdOut();

const Editor = struct {
    in: std.fs.File,
    origin_termios: ?posix.termios,

    pub fn init() Editor {
        return Editor {
            .in = stdin,
            .origin_termios = null
        };
    }

    // Thank you https://codeberg.org/zenith-editor/zenith
    // I tried for an hour to get this to work using os.linux but couldn't
    // Thanks for showing me std.posix
    pub fn enable_raw_mode(self: *Editor) !void {
        var raw = posix.tcgetattr(self.in.handle) 
            catch {
                die("ENABLE_RAW_MODE: tcgetattr");
                // We exit above but need to satisfy the compiler
                return;
            };

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

        posix.tcsetattr(stdin.handle, posix.TCSA.FLUSH, raw) 
            catch die("ENABLE_RAW_MODE: tcsetattr");
    }

    pub fn disable_raw_mode(self: *Editor) !void {
        if (self.origin_termios) |origin_termios| {
            posix.tcsetattr(stdin.handle, posix.TCSA.FLUSH, origin_termios)
                catch die("DISABLE_RAW_MODE: tcsetattr");
        }
    }
};

fn die(string: []const u8) void {
    std.debug.print("ERROR: {s}\n", .{string});
    std.process.exit(1);
}

pub fn main() !void {
    var editor = Editor.init();
    try editor.enable_raw_mode();

    var buffer: [1]u8 = undefined;

    while (true) {
        buffer[0] = '0';

        _ = stdin.reader().read(&buffer) catch die("MAIN: read");

        if (std.ascii.isControl(buffer[0])) {
            try stdout.writer().print("{d}\r\n", .{buffer[0]});
        } else {
            try stdout.writer().print("{d} ('{c}')\r\n", .{buffer[0], buffer[0]});
        }

        if (buffer[0] == 'q') break;
    } 

    try editor.disable_raw_mode();
}
