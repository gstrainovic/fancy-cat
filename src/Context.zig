const std = @import("std");
const vaxis = @import("vaxis");
const ViewMode = @import("modes/ViewMode.zig");
const CommandMode = @import("modes/CommandMode.zig");
const fzwatch = @import("fzwatch");
const Config = @import("config/Config.zig");
const DocumentHandler = @import("handlers/DocumentHandler.zig");
const Cache = @import("./Cache.zig");
const ReloadIndicatorTimer = @import("services/ReloadIndicatorTimer.zig");
const History = @import("services/History.zig");

pub const panic = vaxis.panic_handler;

pub const Event = union(enum) {
    key_press: vaxis.Key,
    mouse: vaxis.Mouse,
    winsize: vaxis.Winsize,
    file_changed,
    reload_done: usize,
};

pub const ModeType = enum { view, command };
pub const Mode = union(ModeType) { view: ViewMode, command: CommandMode };
pub const ReloadIndicatorState = enum { idle, reload, watching };

pub const Context = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    should_quit: bool,
    tty: vaxis.Tty,
    vx: vaxis.Vaxis,
    mouse: ?vaxis.Mouse,
    document_handler: DocumentHandler,
    page_info_text: []u8,
    current_page: ?vaxis.Image,
    watcher: ?fzwatch.Watcher,
    watcher_thread: ?std.Thread,
    config: *Config,
    current_mode: Mode,
    history: History,
    reload_page: bool,
    cache: Cache,
    should_check_cache: bool,
    reload_indicator_timer: ReloadIndicatorTimer,
    current_reload_indicator_state: ReloadIndicatorState,
    reload_indicator_active: bool,
    buf: []u8,
    scroll_mode: bool,
    scroll_offset: i32, // Global scroll position in terminal rows (for scroll mode)
    page_height: u16, // Height of a page in terminal rows (for scroll mode calculations)

    pub fn init(allocator: std.mem.Allocator, args: [][:0]u8) !Self {
        const path = args[1];
        const initial_page = if (args.len == 3)
            try std.fmt.parseInt(u16, args[2], 10)
        else
            null;

        const config = try allocator.create(Config);
        errdefer allocator.destroy(config);
        config.* = Config.init(allocator);
        errdefer config.deinit();

        var document_handler = try DocumentHandler.init(allocator, path, initial_page, config);
        errdefer document_handler.deinit();

        var watcher: ?fzwatch.Watcher = null;
        if (config.file_monitor.enabled) {
            watcher = try fzwatch.Watcher.init(allocator);
            if (watcher) |*w| try w.addFile(path);
        }

        const vx = try vaxis.init(allocator, .{});
        const buf = try allocator.alloc(u8, 4096);
        const tty = try vaxis.Tty.init(buf);
        const reload_indicator_timer = ReloadIndicatorTimer.init(config);
        const history = History.init(allocator, config);

        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .should_quit = false,
            .tty = tty,
            .vx = vx,
            .document_handler = document_handler,
            .page_info_text = &[_]u8{},
            .current_page = null,
            .watcher = watcher,
            .mouse = null,
            .watcher_thread = null,
            .config = config,
            .current_mode = undefined,
            .history = history,
            .reload_page = true,
            .cache = Cache.init(allocator, config, vx, &tty),
            .should_check_cache = config.cache.enabled,
            .reload_indicator_timer = reload_indicator_timer,
            .current_reload_indicator_state = .idle,
            .reload_indicator_active = false,
            .buf = buf,
            .scroll_mode = false,
            .scroll_offset = 0,
            .page_height = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        switch (self.current_mode) {
            .command => |*state| state.deinit(),
            .view => {},
        }
        if (self.watcher) |*w| {
            w.stop();
            if (self.watcher_thread) |thread| thread.join();
            w.deinit();
        }

        if (self.page_info_text.len > 0) self.allocator.free(self.page_info_text);

        self.reload_indicator_timer.deinit();
        self.history.deinit();
        self.cache.deinit();
        self.document_handler.deinit();
        self.vx.deinit(self.allocator, self.tty.writer());
        self.tty.deinit();
        self.config.deinit();
        self.allocator.destroy(self.config);
        self.arena.deinit();
        self.allocator.free(self.buf);
    }

    fn callback(context: ?*anyopaque, event: fzwatch.Event) void {
        switch (event) {
            .modified => {
                const loop = @as(*vaxis.Loop(Event), @ptrCast(@alignCast(context.?)));
                loop.postEvent(Event.file_changed);
            },
        }
    }

    fn watcherWorker(self: *Self, watcher: *fzwatch.Watcher) !void {
        try watcher.start(.{ .latency = self.config.file_monitor.latency });
    }

    pub fn run(self: *Self) !void {
        self.current_mode = .{ .view = ViewMode.init(self) };

        var loop: vaxis.Loop(Event) = .{
            .tty = &self.tty,
            .vaxis = &self.vx,
        };

        try loop.init();
        try loop.start();
        defer loop.stop();
        try self.vx.enterAltScreen(self.tty.writer());
        try self.vx.queryTerminal(self.tty.writer(), 1 * std.time.ns_per_s);
        try self.vx.setMouseMode(self.tty.writer(), true);

        if (self.config.file_monitor.enabled) {
            if (self.watcher) |*w| {
                w.setCallback(callback, &loop);
                self.watcher_thread = try std.Thread.spawn(.{}, watcherWorker, .{ self, w });
                self.current_reload_indicator_state = .watching;
                if (self.config.status_bar.enabled and self.config.file_monitor.reload_indicator_duration > 0) {
                    for (self.config.status_bar.items) |item| {
                        if (item == .reload_aware) {
                            try self.reload_indicator_timer.start(&loop);
                            self.reload_indicator_active = true;
                            break;
                        }
                    }
                }
            }
        }

        while (!self.should_quit) {
            loop.pollEvent();

            while (loop.tryEvent()) |event| {
                try self.update(event);
            }

            try self.draw();

            var buffered = self.tty.writer();
            try self.vx.render(buffered);
            try buffered.flush();
        }
    }

    pub fn changeMode(self: *Self, new_state: ModeType) void {
        switch (self.current_mode) {
            .command => |*state| state.deinit(),
            .view => {},
        }

        switch (new_state) {
            .view => self.current_mode = .{ .view = ViewMode.init(self) },
            .command => self.current_mode = .{ .command = CommandMode.init(self) },
        }
    }

    pub fn resetCurrentPage(self: *Self) void {
        self.should_check_cache = self.config.cache.enabled;
        self.reload_page = true;
    }

    pub fn handleKeyStroke(self: *Self, key: vaxis.Key) !void {
        const km = self.config.key_map;

        // Global keybindings
        if (key.matches(km.quit.codepoint, km.quit.mods)) {
            self.should_quit = true;
            return;
        }

        try switch (self.current_mode) {
            .view => |*state| state.handleKeyStroke(key, km),
            .command => |*state| state.handleKeyStroke(key, km),
        };
    }

    pub fn update(self: *Self, event: Event) !void {
        switch (event) {
            .key_press => |key| try self.handleKeyStroke(key),
            .mouse => |mouse| self.mouse = mouse,
            .winsize => |ws| {
                try self.vx.resize(self.allocator, self.tty.writer(), ws);
                self.cache.clear();
                self.reload_page = true;
            },
            .file_changed => {
                try self.document_handler.reloadDocument();
                self.cache.clear();
                self.reload_page = true;
                if (self.reload_indicator_active) {
                    self.current_reload_indicator_state = .reload;
                    self.reload_indicator_timer.notifyChange();
                }
            },
            .reload_done => {
                self.current_reload_indicator_state = .watching;
            },
        }
    }

    pub fn getPage(
        self: *Self,
        page_number: u16,
        window_width: u32,
        window_height: u32,
    ) !vaxis.Image {
        const cache_key = Cache.Key{
            .colorize = self.config.general.colorize,
            .page = page_number,
            .width_mode = self.document_handler.getWidthMode(),

            // Scale zoom and position as integers with three digits of precision for use in key
            .zoom = @as(u32, @intFromFloat(self.document_handler.getActiveZoom() * 1000.0)),
            .x_offset = @as(i32, @intFromFloat(self.document_handler.getXOffset() * 1000.0)),
            .y_offset = @as(i32, @intFromFloat(self.document_handler.getYOffset() * 1000.0)),
        };

        if (self.should_check_cache) {
            if (self.cache.get(cache_key)) |cached| {
                self.should_check_cache = false;
                return cached.image;
            }
        }

        const encoded_image = try self.document_handler.renderPage(
            page_number,
            window_width,
            window_height,
        );
        defer self.allocator.free(encoded_image.base64);

        const image = try self.vx.transmitPreEncodedImage(
            self.tty.writer(),
            encoded_image.base64,
            encoded_image.width,
            encoded_image.height,
            .rgb,
        );

        if (self.should_check_cache) {
            _ = try self.cache.put(cache_key, .{ .image = image });
            self.should_check_cache = false;
        }

        return image;
    }

    pub fn drawCurrentPage(self: *Self, win: vaxis.Window) !void {
        if (self.scroll_mode) {
            try self.drawScrollMode(win);
        } else {
            try self.drawNormalMode(win);
        }
    }

    fn drawNormalMode(self: *Self, win: vaxis.Window) !void {
        if (self.reload_page) {
            const winsize = try vaxis.Tty.getWinsize(self.tty.fd);
            const pix_per_col = try std.math.divCeil(u16, win.screen.width_pix, win.screen.width);
            const pix_per_row = try std.math.divCeil(u16, win.screen.height_pix, win.screen.height);
            const x_pix = winsize.cols * pix_per_col;
            var y_pix = winsize.rows * pix_per_row;
            if (self.config.status_bar.enabled) {
                y_pix -|= 2 * pix_per_row;
            } else {
                y_pix -|= 1 * pix_per_row;
            }

            self.current_page = try self.getPage(
                self.document_handler.getCurrentPageNumber(),
                x_pix,
                y_pix,
            );

            self.reload_page = false;
        }

        if (self.current_page) |img| {
            const dims = try img.cellSize(win);
            const x_off = (win.width - dims.cols) / 2;
            var y_off = (win.height - dims.rows) / 2;
            if (self.config.status_bar.enabled) {
                y_off -|= 1; // room for status bar
            }
            const center = win.child(.{
                .x_off = x_off,
                .y_off = y_off,
                .width = dims.cols,
                .height = dims.rows,
            });
            try img.draw(center, .{ .scale = .contain });
        }
    }

    fn drawScrollMode(self: *Self, win: vaxis.Window) !void {
        const pix_per_col = try std.math.divCeil(u16, win.screen.width_pix, win.screen.width);
        const pix_per_row = try std.math.divCeil(u16, win.screen.height_pix, win.screen.height);
        const x_pix: u32 = @as(u32, win.width) * @as(u32, pix_per_col);

        // Calculate viewport height in terminal rows (area above status bar)
        var viewport_height: usize = win.height;
        if (self.config.status_bar.enabled) {
            viewport_height -|= 2;
        }

        // For scroll mode, render pages to fit viewport width, with height based on aspect ratio
        // Use viewport pixel dimensions for rendering
        const viewport_y_pix: u32 = @intCast(viewport_height * pix_per_row);

        const total_pages = self.document_handler.getTotalPages();
        const gap: i32 = 1; // Gap between pages in terminal rows

        // Render the first page to get dimensions (used for all pages for simplicity)
        // Use a large height so pages aren't height-constrained
        const first_page = try self.getPage(0, x_pix, viewport_y_pix * 10);
        const page_dims = try first_page.cellSize(win);
        self.page_height = @intCast(page_dims.rows);

        const page_height_i32: i32 = @intCast(self.page_height);
        const page_total_height: i32 = page_height_i32 + gap;
        const viewport_height_i32: i32 = @intCast(viewport_height);

        // Total height of all pages with gaps
        const total_height: i32 = @as(i32, @intCast(total_pages)) * page_total_height - gap;

        // Clamp scroll offset
        const max_scroll = @max(0, total_height - viewport_height_i32);
        self.scroll_offset = std.math.clamp(self.scroll_offset, 0, max_scroll);

        // Track which page has most visibility for status bar
        var most_visible_page: u16 = 0;
        var most_visible_rows: i32 = 0;

        // Iterate through all pages and draw visible ones
        var page_num: u16 = 0;
        while (page_num < total_pages) : (page_num += 1) {
            // Position of this page's top in the document
            const page_top: i32 = @as(i32, @intCast(page_num)) * page_total_height;
            const page_bottom: i32 = page_top + page_height_i32;

            // Position relative to viewport (where should this page appear on screen)
            const rel_top: i32 = page_top - self.scroll_offset;
            const rel_bottom: i32 = page_bottom - self.scroll_offset;

            // Check if page is visible in viewport
            if (rel_bottom <= 0 or rel_top >= viewport_height_i32) {
                continue; // Page not visible
            }

            // Calculate how many rows of this page are visible
            const visible_top = @max(0, rel_top);
            const visible_bottom = @min(viewport_height_i32, rel_bottom);
            const visible_rows = visible_bottom - visible_top;

            if (visible_rows > most_visible_rows) {
                most_visible_rows = visible_rows;
                most_visible_page = page_num;
            }

            // Render this page
            const img = try self.getPage(page_num, x_pix, viewport_y_pix * 10);
            const dims = try img.cellSize(win);
            const x_off: usize = (win.width -| dims.cols) / 2;

            // Calculate clipping for both top and bottom
            const clip_top: u16 = if (rel_top < 0) @intCast(-rel_top) else 0;
            const clip_bottom: u16 = if (rel_bottom > viewport_height_i32)
                @intCast(rel_bottom - viewport_height_i32)
            else
                0;

            const draw_y: usize = if (rel_top < 0) 0 else @intCast(rel_top);
            const draw_height: usize = @intCast(@max(0, page_height_i32 - @as(i32, clip_top) - @as(i32, clip_bottom)));

            if (draw_height > 0) {
                const page_win = win.child(.{
                    .x_off = @intCast(x_off),
                    .y_off = @intCast(draw_y),
                    .width = @intCast(dims.cols),
                    .height = @intCast(draw_height),
                });

                const pixels_from_top: u16 = clip_top * pix_per_row;
                const visible_pixel_height: u16 = @intCast(draw_height * pix_per_row);

                try img.draw(page_win, .{
                    .scale = .none,
                    .z_index = -1,
                    .clip_region = .{
                        .x = 0,
                        .y = pixels_from_top,
                        .width = null,
                        .height = visible_pixel_height,
                    },
                });
            }
        }

        // Update current page number to the page with most visibility
        self.document_handler.current_page_number = most_visible_page;

        self.reload_page = false;
    }

    pub fn drawStatusBar(self: *Self, win: vaxis.Window) !void {
        const arena = self.arena.allocator();
        defer _ = self.arena.reset(.retain_capacity);

        const status_bar = win.child(.{
            .x_off = 0,
            .y_off = win.height -| 2,
            .width = win.width,
            .height = 1,
        });

        // Expand all items into styled sub-items
        var expanded_items = std.array_list.Managed(Config.StatusBar.StyledItem).init(arena);
        defer expanded_items.deinit();

        for (self.config.status_bar.items) |item| {
            switch (item) {
                .styled => |styled| {
                    try expandPlaceholders(&expanded_items, styled);
                },
                .mode_aware => |mode_aware| {
                    switch (self.current_mode) {
                        .view => try expandPlaceholders(&expanded_items, mode_aware.view),
                        .command => try expandPlaceholders(&expanded_items, mode_aware.command),
                    }
                },
                .reload_aware => |reload_aware| {
                    switch (self.current_reload_indicator_state) {
                        .idle => try expandPlaceholders(&expanded_items, reload_aware.idle),
                        .reload => try expandPlaceholders(&expanded_items, reload_aware.reload),
                        .watching => try expandPlaceholders(&expanded_items, reload_aware.watching),
                    }
                },
            }
        }

        const items = expanded_items.items;

        // Find the separator
        var separator_index: usize = items.len;
        for (items, 0..) |item, i| {
            if (std.mem.eql(u8, item.text, Config.StatusBar.SEPARATOR)) {
                separator_index = i;
                break;
            }
        }

        if (separator_index < items.len) {
            status_bar.fill(vaxis.Cell{ .style = items[separator_index].style });
        } else {
            status_bar.fill(vaxis.Cell{ .style = self.config.status_bar.style });
        }

        // Left side
        var left_col: usize = 0;
        for (0..separator_index) |i| {
            try self.drawStatusText(status_bar, items[i], &left_col, true, arena);
        }

        // Right side
        if (separator_index < items.len - 1) {
            var right_col: usize = win.width;
            for (0..(items.len - separator_index - 1)) |j| {
                try self.drawStatusText(status_bar, items[items.len - 1 - j], &right_col, false, arena);
            }
        }
    }

    fn expandPlaceholders(list: *std.array_list.Managed(Config.StatusBar.StyledItem), styled_text: Config.StatusBar.StyledItem) !void {
        const text = styled_text.text;
        var last_index: usize = 0;

        while (last_index < text.len) {
            const open = std.mem.indexOfScalarPos(u8, text, last_index, '<') orelse {
                if (last_index < text.len) {
                    try list.append(.{ .text = text[last_index..], .style = styled_text.style });
                }
                break;
            };

            if (open > last_index) {
                try list.append(.{ .text = text[last_index..open], .style = styled_text.style });
            }

            const close = std.mem.indexOfScalarPos(u8, text, open, '>') orelse {
                try list.append(.{ .text = text[open..], .style = styled_text.style });
                break;
            };

            try list.append(.{ .text = text[open .. close + 1], .style = styled_text.style });

            last_index = close + 1;
        }
    }

    fn drawStatusText(self: *Self, status_bar: vaxis.Window, item: Config.StatusBar.StyledItem, col_offset: *usize, left_aligned: bool, allocator: std.mem.Allocator) !void {
        var text = item.text;

        if (std.mem.eql(u8, text, Config.StatusBar.PATH)) {
            const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
            defer allocator.free(cwd);

            const full_path = try std.fs.cwd().realpathAlloc(allocator, self.document_handler.getPath());
            defer allocator.free(full_path);

            if (std.mem.startsWith(u8, full_path, cwd)) {
                var path = full_path[cwd.len..];
                if (path.len > 0 and path[0] == '/') path = path[1..];
                text = try std.fmt.allocPrint(allocator, "{s}", .{path}); // trim cwd
            } else if (std.posix.getenv("HOME")) |home| {
                if (std.mem.startsWith(u8, full_path, home)) {
                    var path = full_path[home.len..];
                    if (path.len > 0 and path[0] == '/') path = path[1..];
                    text = try std.fmt.allocPrint(allocator, "~/{s}", .{path});
                } else {
                    text = try std.fmt.allocPrint(allocator, "{s}", .{full_path});
                }
            } else {
                text = try std.fmt.allocPrint(allocator, "{s}", .{full_path});
            }
        } else if (std.mem.eql(u8, text, Config.StatusBar.PAGE)) {
            text = try std.fmt.allocPrint(allocator, "{}", .{self.document_handler.getCurrentPageNumber() + 1});
        } else if (std.mem.eql(u8, text, Config.StatusBar.TOTAL_PAGES)) {
            text = try std.fmt.allocPrint(allocator, "{}", .{self.document_handler.getTotalPages()});
        } else if (std.mem.eql(u8, text, Config.StatusBar.SEPARATOR)) {
            text = "";
        }

        const width = vaxis.gwidth.gwidth(text, .wcwidth);

        if (!left_aligned) col_offset.* -= width;

        _ = status_bar.print(
            &.{.{ .text = text, .style = item.style }},
            .{ .col_offset = @intCast(col_offset.*) },
        );

        if (left_aligned) col_offset.* += width;
    }

    pub fn draw(self: *Self) !void {
        const win = self.vx.window();
        win.clear();

        try self.drawCurrentPage(win);

        if (self.config.status_bar.enabled) {
            try self.drawStatusBar(win);
        }

        if (self.current_mode == .command) {
            self.current_mode.command.drawCommandBar(win);
        }
    }

    pub fn toggleFullScreen(self: *Self) void {
        self.config.status_bar.enabled = !self.config.status_bar.enabled;
    }

    pub fn toggleScrollMode(self: *Self) void {
        self.scroll_mode = !self.scroll_mode;
        if (self.scroll_mode) {
            // Initialize scroll offset based on current page
            const gap: i32 = 1;
            const page_total_height: i32 = @as(i32, @intCast(self.page_height)) + gap;
            self.scroll_offset = @as(i32, @intCast(self.document_handler.current_page_number)) * page_total_height;
        } else {
            self.scroll_offset = 0;
        }
    }

    pub fn scrollInScrollMode(self: *Self, delta: i32) void {
        // Scroll by a number of terminal rows
        const scroll_amount: i32 = 3; // Rows to scroll per keypress
        self.scroll_offset += delta * scroll_amount;
        // Clamping is done in drawScrollMode
    }
};
