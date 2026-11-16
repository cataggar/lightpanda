// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
//
// Francis Bouvier <francis@lightpanda.io>
// Pierre Tachoire <pierre@lightpanda.io>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.
const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../js/js.zig");

const Page = @import("../Page.zig");
const Frame = @import("../Frame.zig");
const layout = @import("../layout.zig");
const Tokenizer = @import("../css/Tokenizer.zig");

const Node = @import("Node.zig");
const Element = @import("Element.zig");
const Document = @import("Document.zig");
const DOMRect = @import("DOMRect.zig");

const log = lp.log;

pub fn registerTypes() []const type {
    return &.{
        IntersectionObserver,
        IntersectionObserverEntry,
    };
}

const IntersectionObserver = @This();

_rc: lp.RC = .{},
_arena: *lp.Arena,
_callback: js.Function.Global,
_observing: std.ArrayList(*Element) = .empty,
_root: ?*Element = null,
/// The `root` option as given (an Element or the Document), for the getter;
/// `_root` is the element intersections are computed against.
_root_node: ?*Node = null,
/// Set when an explicit `root` belonged to a document that has been torn down,
/// so the observer never silently falls back to the viewport.
_root_dead: bool = false,
/// rootMargin and scrollMargin, parsed and serialized back (four values).
_root_margin: []const u8 = "0px 0px 0px 0px",
_scroll_margin: []const u8 = "0px 0px 0px 0px",
_parsed_root_margin: [4]Margin = .{
    .{ .value = 0, .percent = false },
    .{ .value = 0, .percent = false },
    .{ .value = 0, .percent = false },
    .{ .value = 0, .percent = false },
},
/// Sorted ascending, each in [0, 1].
_threshold: []const f64 = &.{0.0},
_delay: i32 = 0,
_track_visibility: bool = false,
// these are RC'd (by us, and v8)
_pending_entries: std.ArrayList(*IntersectionObserverEntry) = .empty,
// Per-target state retained across scroll/layout transitions until unobserved.
_tracked: std.AutoHashMapUnmanaged(*Element, Tracked) = .{},

const Tracked = struct {
    reported: bool = false,
    was_connected: bool = false,
    is_intersecting: bool = false,
    threshold_index: usize = 0,
};

const ObserverInit = struct {
    delay: i32 = 0,
    root: ?*Node = null,
    rootMargin: ?[]const u8 = null,
    scrollMargin: ?[]const u8 = null,
    threshold: Threshold = .{ .scalar = 0.0 },
    trackVisibility: bool = false,

    const Threshold = union(enum) {
        scalar: f64,
        array: []const f64,
    };
};

pub fn init(callback: js.Function.Global, options: ?ObserverInit, frame: *Frame) !*IntersectionObserver {
    const arena = try frame.getArena(.small, "IntersectionObserver");
    errdefer arena.release();

    const opts = options orelse ObserverInit{};

    // The options' WebIDL conversion comes first, so its TypeErrors do: a
    // root that's neither an Element nor a Document (below), and a threshold
    // that isn't a finite (restricted) double.
    const given_thresholds: []const f64 = switch (opts.threshold) {
        .scalar => |*value| value[0..1],
        .array => |arr| arr,
    };
    for (given_thresholds) |value| {
        if (!std.math.isFinite(value)) return error.TypeError;
    }

    const root: ?*Element = blk: {
        const root_opt = opts.root orelse break :blk null;
        switch (root_opt._type) {
            .element => break :blk root_opt.subtype(Element),
            .document => {
                // not strictly correct, `null` means the viewport, not the
                // entire document, but since we don't render anything, this
                // should be fine.
                break :blk null;
            },
            else => return error.TypeError,
        }
    };

    const parsed_root_margin = try parseMargin(opts.rootMargin orelse "0px");
    const root_margin = try serializeMargin(arena.allocator(), parsed_root_margin);
    const scroll_margin = try serializeMargin(arena.allocator(), try parseMargin(opts.scrollMargin orelse "0px"));

    // Each threshold is in [0, 1], sorted ascending; an empty list is [0].
    const threshold = blk: {
        if (given_thresholds.len == 0) {
            break :blk &[_]f64{0.0};
        }
        const sorted = try arena.dupe(f64, given_thresholds);
        for (sorted) |value| {
            if (value < 0 or value > 1) return error.RangeError;
        }
        std.mem.sort(f64, sorted, {}, std.sort.asc(f64));
        break :blk sorted;
    };

    // Tracking visibility raises the delay to at least 100ms.
    const delay = if (opts.trackVisibility and opts.delay < 100) 100 else opts.delay;

    const self = try arena.create(IntersectionObserver);
    self.* = .{
        ._arena = arena,
        ._callback = callback,
        ._root = root,
        ._root_node = opts.root,
        ._root_margin = root_margin,
        ._scroll_margin = scroll_margin,
        ._parsed_root_margin = parsed_root_margin,
        ._threshold = threshold,
        ._delay = delay,
        ._track_visibility = opts.trackVisibility,
    };
    return self;
}

/// One side of a rootMargin or scrollMargin: a length in px, or a percentage.
const Margin = struct {
    value: f32,
    percent: bool,
};

/// "Parse a margin": one to four px lengths or percentages, expanded like CSS
/// margins to top, right, bottom, left. An empty string is all zero. Any other
/// token (a unitless number, another unit, calc(), a comma) is a SyntaxError.
fn parseMargin(text: []const u8) error{SyntaxError}![4]Margin {
    var margins: [4]Margin = undefined;
    var count: usize = 0;
    var tokenizer: Tokenizer = .{ .input = text };
    while (tokenizer.next()) |token| {
        const margin: Margin = switch (token) {
            .white_space, .comment => continue,
            .dimension => |d| blk: {
                if (std.ascii.eqlIgnoreCase(d.unit, "px") == false) {
                    return error.SyntaxError;
                }
                break :blk .{ .value = d.value, .percent = false };
            },
            // unit_value is divided by 100; prefer the exact integer.
            .percentage => |p| .{
                .value = if (p.int_value) |int| @floatFromInt(int) else p.unit_value * 100,
                .percent = true,
            },
            else => return error.SyntaxError,
        };
        if (count == 4) {
            return error.SyntaxError;
        }
        margins[count] = margin;
        count += 1;
    }
    const zero: Margin = .{ .value = 0, .percent = false };
    return switch (count) {
        0 => .{ zero, zero, zero, zero },
        1 => .{ margins[0], margins[0], margins[0], margins[0] },
        2 => .{ margins[0], margins[1], margins[0], margins[1] },
        3 => .{ margins[0], margins[1], margins[2], margins[1] },
        else => margins,
    };
}

/// The four margins as the rootMargin/scrollMargin attributes give them.
fn serializeMargin(allocator: std.mem.Allocator, margins: [4]Margin) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    for (margins, 0..) |margin, i| {
        if (i > 0) try out.writer.writeByte(' ');
        // + 0 turns -0 into 0, which a JS number prints as "0".
        try out.writer.print("{d}{s}", .{ margin.value + 0, if (margin.percent) "%" else "px" });
    }
    return out.written();
}

fn getRoot(self: *const IntersectionObserver) ?*Node {
    return self._root_node;
}

fn getRootMargin(self: *const IntersectionObserver) []const u8 {
    return self._root_margin;
}

fn getScrollMargin(self: *const IntersectionObserver) []const u8 {
    return self._scroll_margin;
}

fn getThresholds(self: *const IntersectionObserver) []const f64 {
    return self._threshold;
}

fn getDelay(self: *const IntersectionObserver) i32 {
    return self._delay;
}

fn getTrackVisibility(self: *const IntersectionObserver) bool {
    return self._track_visibility;
}

pub fn deinit(self: *IntersectionObserver, page: *Page) void {
    self._callback.release();
    releaseAll(self._pending_entries.items, page);
    self._arena.release();
}

pub fn releaseRef(self: *IntersectionObserver, page: *Page) void {
    self._rc.release(self, page);
}

pub fn acquireRef(self: *IntersectionObserver) void {
    self._rc.acquire();
}

pub fn observe(self: *IntersectionObserver, target: *Element, frame: *Frame) !void {
    // Check if already observing this target
    for (self._observing.items) |elem| {
        if (elem == target) {
            return;
        }
    }

    try self._observing.append(self._arena.allocator(), target);
    if (self._observing.items.len == 1) {
        try Frame.observers.registerIntersectionObserver(frame, self);
    }

    try self._tracked.put(self._arena.allocator(), target, .{});
    Frame.observers.scheduleIntersectionChecks(frame);
}

fn unobserve(self: *IntersectionObserver, target: *Element, frame: *Frame) void {
    const original_length = self._observing.items.len;
    for (self._observing.items, 0..) |elem, i| {
        if (elem == target) {
            _ = self._observing.swapRemove(i);
            _ = self._tracked.remove(target);

            // Remove any pending entries for this target.
            var j: usize = 0;
            while (j < self._pending_entries.items.len) {
                if (self._pending_entries.items[j]._target == target) {
                    const entry = self._pending_entries.swapRemove(j);
                    entry.releaseRef(frame.page);
                } else {
                    j += 1;
                }
            }
            break;
        }
    }

    if (original_length > 0 and self._observing.items.len == 0) {
        Frame.observers.unregisterIntersectionObserver(frame, self);
    }
}

// Drops every observation without touching the frame's observer list
pub fn reset(self: *IntersectionObserver, page: *Page) void {
    releaseAll(self._pending_entries.items, page);
    self._pending_entries.clearRetainingCapacity();
    self._tracked.clearRetainingCapacity();
    self._observing.clearRetainingCapacity();
}

pub fn disconnect(self: *IntersectionObserver, frame: *Frame) void {
    const registered = self._observing.items.len > 0;
    self.reset(frame.page);
    if (registered) {
        Frame.observers.unregisterIntersectionObserver(frame, self);
    }
}

pub fn pruneDocument(self: *IntersectionObserver, doc: *const Document, frame: *Frame) void {
    if (self._root) |root| {
        if (root.asNode().ownerDocument(frame) == doc) {
            self._root = null;
            self._root_node = null;
            self._root_dead = true;
        }
    } else if (self._root_node) |root_node| {
        if (root_node.ownerDocument(frame) == doc or (root_node._type == .document and root_node.subtype(Document) == doc)) {
            self._root_node = null;
            self._root_dead = true;
        }
    }
    var i: usize = 0;
    while (i < self._observing.items.len) {
        const target = self._observing.items[i];
        if (target.asNode().ownerDocument(frame) == doc) {
            self.unobserve(target, frame);
        } else {
            i += 1;
        }
    }
}

pub fn needsCheck(self: *const IntersectionObserver, frame: *Frame) bool {
    for (self._observing.items) |target| {
        const tracked = self._tracked.get(target) orelse continue;
        if (!tracked.reported) return true;
        const node = target.asNode();
        if (node.ownerFrame(frame) == null) continue;
        if (node.isConnected() != tracked.was_connected) return true;
    }
    return false;
}

fn takeRecords(self: *IntersectionObserver, frame: *Frame) !js.Value {
    const local = frame.js.local orelse return error.NotHandled;
    const entries = try self.takePendingEntries(frame);
    // whether we safely deliver these to v8 or not, we're done with these
    defer releaseAll(entries, frame.page);
    return local.zigValueToJs(entries, .{});
}

fn takePendingEntries(self: *IntersectionObserver, frame: *Frame) ![]*IntersectionObserverEntry {
    const entries = try frame.call_arena.dupe(*IntersectionObserverEntry, self._pending_entries.items);
    self._pending_entries.clearRetainingCapacity();
    return entries;
}

fn releaseAll(entries: []const *IntersectionObserverEntry, page: *Page) void {
    for (entries) |entry| {
        entry.releaseRef(page);
    }
}

const IntersectionData = struct {
    intersection_ratio: f64,
    intersection_rect: DOMRect.Data,
    bounding_client_rect: DOMRect.Data,
    root_bounds: DOMRect.Data,
};

const TargetEvaluation = struct {
    is_intersecting: bool,
    threshold_index: usize,
    data: IntersectionData,
};

fn expandRootBounds(bounds: DOMRect.Data, margins: [4]Margin) DOMRect.Data {
    const top_m: f64 = if (margins[0].percent) bounds.height * (@as(f64, margins[0].value) / 100.0) else @as(f64, margins[0].value);
    const right_m: f64 = if (margins[1].percent) bounds.width * (@as(f64, margins[1].value) / 100.0) else @as(f64, margins[1].value);
    const bottom_m: f64 = if (margins[2].percent) bounds.height * (@as(f64, margins[2].value) / 100.0) else @as(f64, margins[2].value);
    const left_m: f64 = if (margins[3].percent) bounds.width * (@as(f64, margins[3].value) / 100.0) else @as(f64, margins[3].value);

    const x = bounds.x - left_m;
    const y = bounds.y - top_m;
    const w = @max(0.0, bounds.width + left_m + right_m);
    const h = @max(0.0, bounds.height + top_m + bottom_m);
    return .{ .x = x, .y = y, .width = w, .height = h };
}

fn lookupBoxRect(el: *Element, owner: *Frame) DOMRect.Data {
    return layout.elementClientRect(el, owner);
}

fn calculateLegacyIntersection(
    self: *IntersectionObserver,
    target: *Element,
    frame: *Frame,
) IntersectionData {
    const target_rect = target.boundingClientRectValues(frame);
    const root_rect = if (self._root) |root|
        root.boundingClientRectValues(frame)
    else blk: {
        const viewport = frame.page.getViewport();
        break :blk DOMRect.Data{
            .width = @floatFromInt(viewport.width),
            .height = @floatFromInt(viewport.height),
        };
    };

    return .{
        .intersection_ratio = 1.0,
        .intersection_rect = target_rect,
        .bounding_client_rect = target_rect,
        .root_bounds = root_rect,
    };
}

const ClipResult = struct {
    x1: f64,
    y1: f64,
    x2: f64,
    y2: f64,
    valid: bool,
};

fn intersectAxis(a1: f64, a2: f64, c1: f64, c2: f64, zero_size_target: bool) struct { lo: f64, hi: f64, ok: bool } {
    const lo = @max(a1, c1);
    const hi = @min(a2, c2);
    const ok = if (zero_size_target) hi >= lo else hi > lo;
    return .{ .lo = lo, .hi = if (hi > lo) hi else lo, .ok = ok };
}

fn evaluateTarget(
    self: *IntersectionObserver,
    target: *Element,
    owner: *Frame,
) TargetEvaluation {
    if (!target.isVisible(owner)) {
        return .{
            .is_intersecting = false,
            .threshold_index = 0,
            .data = .{
                .intersection_ratio = 0.0,
                .intersection_rect = .{},
                .bounding_client_rect = .{},
                .root_bounds = .{},
            },
        };
    }

    const target_rect = lookupBoxRect(target, owner);

    if (self._root_dead) {
        return .{
            .is_intersecting = false,
            .threshold_index = 0,
            .data = .{
                .intersection_ratio = 0.0,
                .intersection_rect = .{},
                .bounding_client_rect = target_rect,
                .root_bounds = .{},
            },
        };
    }

    if (self._root) |root| {
        if (!root.asNode().isConnected() or !root.isVisible(owner)) {
            return .{
                .is_intersecting = false,
                .threshold_index = 0,
                .data = .{
                    .intersection_ratio = 0.0,
                    .intersection_rect = .{},
                    .bounding_client_rect = target_rect,
                    .root_bounds = .{},
                },
            };
        }
    } else if (self._root_node) |root_node| {
        if (root_node._type == .document and target.asNode().getDocument(owner) != root_node.subtype(Document)) {
            return .{
                .is_intersecting = false,
                .threshold_index = 0,
                .data = .{
                    .intersection_ratio = 0.0,
                    .intersection_rect = .{},
                    .bounding_client_rect = target_rect,
                    .root_bounds = .{},
                },
            };
        }
    }

    const raw_root_bounds: DOMRect.Data = if (self._root) |root| blk: {
        const rb = lookupBoxRect(root, owner);
        break :blk .{
            .x = rb.x,
            .y = rb.y,
            .width = root.getClientWidth(owner),
            .height = root.getClientHeight(owner),
        };
    } else blk: {
        const viewport = owner.page.getViewport();
        break :blk .{
            .x = 0.0,
            .y = 0.0,
            .width = @floatFromInt(viewport.width),
            .height = @floatFromInt(viewport.height),
        };
    };
    const root_bounds = expandRootBounds(raw_root_bounds, self._parsed_root_margin);

    const zero_w = target_rect.width <= 0.0;
    const zero_h = target_rect.height <= 0.0;
    var clip: ClipResult = .{
        .x1 = target_rect.x,
        .y1 = target_rect.y,
        .x2 = target_rect.x + @max(0.0, target_rect.width),
        .y2 = target_rect.y + @max(0.0, target_rect.height),
        .valid = true,
    };

    // Walk up intermediate overflow containers (and verify `self._root` is an
    // ancestor when an explicit root element is configured).
    const style_manager = &owner._style_manager;
    var reached_root = self._root == null;
    var cur_node: *Node = target.asNode();
    while (cur_node.flatParent(owner)) |parent| : (cur_node = parent) {
        const ancestor = parent.is(Element) orelse continue;
        if (self._root) |root| {
            if (ancestor == root) {
                reached_root = true;
                break;
            }
        }
        if (ancestor.isRootContainer()) continue;

        const overflows = style_manager.overflowAxes(ancestor);
        const clips_x = overflows.x or style_manager.clipsOverflowX(ancestor);
        const clips_y = overflows.y or style_manager.clipsOverflowY(ancestor);
        if (!clips_x and !clips_y) continue;

        const anc_rect = lookupBoxRect(ancestor, owner);
        const anc_w = ancestor.getClientWidth(owner);
        const anc_h = ancestor.getClientHeight(owner);
        if (clips_x) {
            const rx = intersectAxis(clip.x1, clip.x2, anc_rect.x, anc_rect.x + anc_w, zero_w);
            clip.x1 = rx.lo;
            clip.x2 = rx.hi;
            if (!rx.ok) {
                clip.valid = false;
                break;
            }
        }
        if (clips_y) {
            const ry = intersectAxis(clip.y1, clip.y2, anc_rect.y, anc_rect.y + anc_h, zero_h);
            clip.y1 = ry.lo;
            clip.y2 = ry.hi;
            if (!ry.ok) {
                clip.valid = false;
                break;
            }
        }
    }

    if (!reached_root) {
        clip.valid = false;
    }

    if (clip.valid) {
        const rx = intersectAxis(clip.x1, clip.x2, root_bounds.x, root_bounds.x + root_bounds.width, zero_w);
        const ry = intersectAxis(clip.y1, clip.y2, root_bounds.y, root_bounds.y + root_bounds.height, zero_h);
        clip.x1 = rx.lo;
        clip.x2 = rx.hi;
        clip.y1 = ry.lo;
        clip.y2 = ry.hi;
        clip.valid = rx.ok and ry.ok;
    }

    if (!clip.valid) {
        return .{
            .is_intersecting = false,
            .threshold_index = 0,
            .data = .{
                .intersection_ratio = 0.0,
                .intersection_rect = .{},
                .bounding_client_rect = target_rect,
                .root_bounds = root_bounds,
            },
        };
    }

    const intersection_rect: DOMRect.Data = .{
        .x = clip.x1,
        .y = clip.y1,
        .width = clip.x2 - clip.x1,
        .height = clip.y2 - clip.y1,
    };
    const target_area = @max(0.0, target_rect.width) * @max(0.0, target_rect.height);
    const intersection_area = intersection_rect.width * intersection_rect.height;
    const ratio: f64 = if (target_area > 0.0)
        std.math.clamp(intersection_area / target_area, 0.0, 1.0)
    else
        1.0;

    const intersects = self.meetsThreshold(ratio);
    return .{
        .is_intersecting = intersects,
        .threshold_index = if (intersects) self.thresholdIndex(ratio) else 0,
        .data = .{
            .intersection_ratio = ratio,
            .intersection_rect = intersection_rect,
            .bounding_client_rect = target_rect,
            .root_bounds = root_bounds,
        },
    };
}

fn meetsThreshold(self: *const IntersectionObserver, ratio: f64) bool {
    for (self._threshold) |threshold| {
        if (ratio >= threshold) {
            return true;
        }
    }
    return false;
}

fn thresholdIndex(self: *const IntersectionObserver, ratio: f64) usize {
    var idx: usize = 0;
    for (self._threshold) |threshold| {
        if (ratio >= threshold) {
            idx += 1;
        } else {
            break;
        }
    }
    return idx;
}

fn appendEntry(
    self: *IntersectionObserver,
    target: *Element,
    is_intersecting: bool,
    data: IntersectionData,
    frame: *Frame,
) !void {
    const arena = try frame.getArena(.tiny, "IntersectionObserverEntry");
    errdefer arena.release();

    const entry = try arena.create(IntersectionObserverEntry);
    entry.* = .{
        ._rc = .init(1),
        ._arena = arena,
        ._target = target,
        ._time = frame.window._performance.now(),
        ._is_intersecting = is_intersecting,
        ._root_bounds = try DOMRect.create(data.root_bounds, frame._factory),
        ._intersection_rect = try DOMRect.create(data.intersection_rect, frame._factory),
        ._bounding_client_rect = try DOMRect.create(data.bounding_client_rect, frame._factory),
        ._intersection_ratio = data.intersection_ratio,
    };
    try self._pending_entries.append(self._arena.allocator(), entry);
}

fn checkLegacyIntersection(
    self: *IntersectionObserver,
    target: *Element,
    cross_frame: bool,
    frame: *Frame,
) !void {
    const tracked = self._tracked.getEntry(target) orelse return;
    const node = target.asNode();
    const is_now_intersecting = !self._root_dead and node.isConnected() and self.meetsThreshold(1.0);
    const data: IntersectionData = blk: {
        if (is_now_intersecting) {
            break :blk self.calculateLegacyIntersection(target, frame);
        }
        if (tracked.value_ptr.reported) {
            return;
        }
        break :blk .{
            .intersection_ratio = 0,
            .intersection_rect = .{},
            .bounding_client_rect = .{},
            .root_bounds = .{},
        };
    };

    try self.appendEntry(target, is_now_intersecting, data, frame);
    if (is_now_intersecting or cross_frame) {
        _ = self._tracked.removeByPtr(tracked.key_ptr);
    } else {
        tracked.value_ptr.* = .{
            .reported = true,
            .was_connected = node.isConnected(),
            .is_intersecting = false,
            .threshold_index = 0,
        };
    }
}

fn checkIntersection(self: *IntersectionObserver, target: *Element, frame: *Frame, force: bool) !void {
    const tracked = self._tracked.getEntry(target) orelse return;

    const node = target.asNode();
    const owner = node.ownerFrame(frame) orelse {
        // Frameless documents (DOMParser, createHTMLDocument) aren't rendered.
        return;
    };

    if (!frame.layoutIntersectionEnabled() or owner != frame) {
        if (owner != frame and owner.window._closed) {
            _ = self._tracked.removeByPtr(tracked.key_ptr);
            return;
        }
        return self.checkLegacyIntersection(target, owner != frame, frame);
    }

    const is_connected = node.isConnected();
    if (tracked.value_ptr.reported and !force and is_connected == tracked.value_ptr.was_connected) {
        return;
    }

    const eval: TargetEvaluation = if (!is_connected) .{
        .is_intersecting = false,
        .threshold_index = 0,
        .data = .{
            .intersection_ratio = 0.0,
            .intersection_rect = .{},
            .bounding_client_rect = .{},
            .root_bounds = .{},
        },
    } else self.evaluateTarget(target, owner);

    const prev = tracked.value_ptr.*;
    const should_report = if (!prev.reported)
        true
    else if (!is_connected)
        prev.is_intersecting
    else
        (eval.is_intersecting != prev.is_intersecting or eval.threshold_index != prev.threshold_index);

    tracked.value_ptr.* = .{
        .reported = true,
        .was_connected = is_connected,
        .is_intersecting = eval.is_intersecting,
        .threshold_index = eval.threshold_index,
    };

    if (!should_report) {
        return;
    }

    try self.appendEntry(target, eval.is_intersecting, eval.data, frame);
}

pub fn checkIntersections(self: *IntersectionObserver, frame: *Frame, force: bool) !void {
    if (self._observing.items.len == 0) {
        return;
    }

    for (self._observing.items) |target| {
        try self.checkIntersection(target, frame, force);
    }

    if (self._pending_entries.items.len > 0) {
        try Frame.observers.scheduleIntersectionDelivery(frame);
    }
}

pub fn deliverEntries(self: *IntersectionObserver, frame: *Frame) !void {
    if (self._pending_entries.items.len == 0) {
        return;
    }

    const entries = try self.takePendingEntries(frame);
    // whether we safely deliver these to v8 or not, we're done with these
    defer releaseAll(entries, frame.page);

    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    ls.toLocal(self._callback).callWithThisReport(self, .{ entries, self }) catch |err| {
        log.debug(.frame, "IntsctObserver.deliverEntries", .{ .err = err });
        return err;
    };
}

pub const IntersectionObserverEntry = struct {
    _rc: lp.RC = .{},
    _arena: *lp.Arena,
    _time: f64,
    _target: *Element,
    _bounding_client_rect: *DOMRect,
    _intersection_rect: *DOMRect,
    _root_bounds: *DOMRect,
    _intersection_ratio: f64,
    _is_intersecting: bool,

    pub fn deinit(self: *IntersectionObserverEntry, _: *Page) void {
        self._arena.release();
    }

    pub fn releaseRef(self: *IntersectionObserverEntry, page: *Page) void {
        self._rc.release(self, page);
    }

    pub fn acquireRef(self: *IntersectionObserverEntry) void {
        self._rc.acquire();
    }

    pub fn getTarget(self: *const IntersectionObserverEntry) *Element {
        return self._target;
    }

    fn getTime(self: *const IntersectionObserverEntry) f64 {
        return self._time;
    }

    pub fn getBoundingClientRect(self: *const IntersectionObserverEntry) *DOMRect {
        return self._bounding_client_rect;
    }

    fn getIntersectionRect(self: *const IntersectionObserverEntry) *DOMRect {
        return self._intersection_rect;
    }

    fn getRootBounds(self: *const IntersectionObserverEntry) ?*DOMRect {
        return self._root_bounds;
    }

    fn getIntersectionRatio(self: *const IntersectionObserverEntry) f64 {
        return self._intersection_ratio;
    }

    fn getIsIntersecting(self: *const IntersectionObserverEntry) bool {
        return self._is_intersecting;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(IntersectionObserverEntry);

        pub const Meta = struct {
            pub const name = "IntersectionObserverEntry";
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const target = bridge.accessor(IntersectionObserverEntry.getTarget, null, .{});
        pub const time = bridge.accessor(IntersectionObserverEntry.getTime, null, .{});
        pub const boundingClientRect = bridge.accessor(IntersectionObserverEntry.getBoundingClientRect, null, .{});
        pub const intersectionRect = bridge.accessor(IntersectionObserverEntry.getIntersectionRect, null, .{});
        pub const rootBounds = bridge.accessor(IntersectionObserverEntry.getRootBounds, null, .{});
        pub const intersectionRatio = bridge.accessor(IntersectionObserverEntry.getIntersectionRatio, null, .{});
        pub const isIntersecting = bridge.accessor(IntersectionObserverEntry.getIsIntersecting, null, .{});
    };
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(IntersectionObserver);

    pub const Meta = struct {
        pub const name = "IntersectionObserver";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(init, .{});

    pub const root = bridge.accessor(IntersectionObserver.getRoot, null, .{});
    pub const rootMargin = bridge.accessor(IntersectionObserver.getRootMargin, null, .{});
    pub const scrollMargin = bridge.accessor(IntersectionObserver.getScrollMargin, null, .{});
    pub const thresholds = bridge.accessor(IntersectionObserver.getThresholds, null, .{});
    pub const delay = bridge.accessor(IntersectionObserver.getDelay, null, .{});
    pub const trackVisibility = bridge.accessor(IntersectionObserver.getTrackVisibility, null, .{});

    pub const observe = bridge.function(IntersectionObserver.observe, .{});
    pub const unobserve = bridge.function(IntersectionObserver.unobserve, .{});
    pub const disconnect = bridge.function(IntersectionObserver.disconnect, .{});
    pub const takeRecords = bridge.function(IntersectionObserver.takeRecords, .{});
};

const testing = @import("../../testing.zig");

// Infinite scroll: the callback observes a fresh sentinel, which we report as
// intersecting the moment it is connected, so the page never settles on its own.
// Old sentinels stay observed (_tracked keeps them from re-firing) so that the
// observer stays registered on the frame for as long as it is alive. `deferred`
// re-observes from a timer, one delivery per macrotask tick, the way a
// fetch-driven pager behaves; otherwise the chain never leaves the microtask
// checkpoint. New sentinels go first: an appended one would measure every
// earlier sibling, making the chain quadratic.
fn observeSentinelChain(frame: *Frame, comptime deferred: bool) !void {
    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    try ls.local.eval(
        \\(function(deferred) {
        \\  const root = document.documentElement ?? document.appendChild(document.createElement('html'));
        \\  const list = root.appendChild(document.createElement('div'));
        \\  const observe = () => io.observe(list.insertBefore(document.createElement('div'), list.firstChild));
        \\  const io = new IntersectionObserver((entries) => {
        \\    for (const entry of entries) {
        \\      if (!entry.isIntersecting) continue;
        \\      if (deferred) setTimeout(observe, 0); else observe();
        \\    }
        \\  });
        \\  observe();
        \\})(
    ++ (if (deferred) "true" else "false") ++ ")", null);

    frame.js.env.runMicrotasks();
    try frame.js.env.runMacrotasks();
    try testing.expect(frame._intersection.last_delivery_ms != 0);
}

// Nested zero-delay timers are clamped to 4ms past a nesting depth of five, so
// a yielding chain needs real time to pass between ticks.
fn tick(frame: *Frame) !void {
    lp.io.sleep(.fromMilliseconds(5), .awake) catch {};
    frame.js.env.runMicrotasks();
    try frame.js.env.runMacrotasks();
}

fn tickUntilDisconnected(frame: *Frame) !void {
    for (0..200) |_| {
        try tick(frame);
        if (!Frame.observers.hasIntersectionObservers(frame)) break;
    }
}

test "WebApi: synchronous IntersectionObserver chain is disconnected" {
    testing.silenceLog(&.{.frame});

    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();

    try observeSentinelChain(frame, false);
    try tickUntilDisconnected(frame);

    try testing.expectEqual(false, Frame.observers.hasIntersectionObservers(frame));
    try testing.expectEqual(true, frame._intersection.runaway);
    try testing.expect(frame._intersection.burst_deliveries > Frame.observers.INTERSECTION_BURST_LIMIT);
}

test "WebApi: IntersectionObserver burst older than the limit is disconnected" {
    testing.silenceLog(&.{.frame});

    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();

    try observeSentinelChain(frame, true);
    frame._intersection.burst_start_ms -|= Frame.observers.INTERSECTION_RUNAWAY_MS + 1;
    try tickUntilDisconnected(frame);

    try testing.expectEqual(false, Frame.observers.hasIntersectionObservers(frame));
    try testing.expectEqual(true, frame._intersection.runaway);
    try testing.expect(frame._intersection.burst_deliveries <= Frame.observers.INTERSECTION_BURST_LIMIT);
}

test "WebApi: IntersectionObserver delivery after a quiet gap starts a new burst" {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();

    try observeSentinelChain(frame, true);

    // An old burst that went quiet: its age must not count against what follows.
    frame._intersection.burst_start_ms -|= Frame.observers.INTERSECTION_RUNAWAY_MS + 1;
    frame._intersection.last_delivery_ms -|= Frame.observers.INTERSECTION_QUIET_MS + 1;
    const stale_start = frame._intersection.burst_start_ms;

    try tick(frame);

    try testing.expectEqual(true, Frame.observers.hasIntersectionObservers(frame));
    try testing.expectEqual(false, frame._intersection.runaway);
    try testing.expectEqual(1, frame._intersection.burst_deliveries);
    try testing.expect(frame._intersection.burst_start_ms > stale_start);
}

test "WebApi: IntersectionObserver" {
    try testing.htmlRunner("intersection_observer", .{});
}

test "WebApi: IntersectionObserver default mode ignores viewport override without layout_intersection" {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();
    defer testing.test_session.browser.setViewportOverride(null);
    testing.test_session.browser.setViewportOverride(.{ .width = 800, .height = 600 });

    {
        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();

        try ls.local.eval(
            \\(function() {
            \\  const root = document.documentElement ?? document.appendChild(document.createElement('html'));
            \\  const body = document.body ?? root.appendChild(document.createElement('body'));
            \\  for (let i = 0; i < 10; i++) {
            \\    const sec = body.appendChild(document.createElement('section'));
            \\    sec.style.height = '300px';
            \\    const img = sec.appendChild(document.createElement('img'));
            \\    img.id = 'lazy-' + i;
            \\  }
            \\  window.__seen = [];
            \\  const io = new IntersectionObserver((entries) => {
            \\    for (const e of entries) {
            \\      if (e.isIntersecting) window.__seen.push(e.target.id);
            \\    }
            \\  });
            \\  io.observe(document.getElementById('lazy-9'));
            \\})()
        , null);
    }

    frame.js.env.runMicrotasks();
    try frame.js.env.runMacrotasks();

    {
        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();

        const seen = try ls.local.exec("JSON.stringify(window.__seen)", null);
        try testing.expectString("[\"lazy-9\"]", try seen.toZig([]const u8));
    }
    try testing.expectEqual(@as(usize, 0), frame._intersection.observers.items[0]._tracked.count());
}

test "WebApi: IntersectionObserver scroll container and zero-height sentinel transitions" {
    testing.test_session.experimental_features.layout_intersection = true;
    defer testing.test_session.experimental_features = .{};

    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();

    {
        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();

        try ls.local.eval(
            \\(function() {
            \\  const root = document.documentElement ?? document.appendChild(document.createElement('html'));
            \\  const body = document.body ?? root.appendChild(document.createElement('body'));
            \\  const scroller = body.appendChild(document.createElement('div'));
            \\  scroller.id = 'scroller';
            \\  scroller.style.cssText = 'height: 400px; overflow-y: auto;';
            \\  for (let i = 0; i < 4; i++) {
            \\    const item = scroller.appendChild(document.createElement('div'));
            \\    item.id = 'item-' + i;
            \\    item.style.height = '200px';
            \\  }
            \\  const sentinel = scroller.appendChild(document.createElement('div'));
            \\  sentinel.id = 'sentinel';
            \\  sentinel.style.height = '0px';
            \\
            \\  window.__events = [];
            \\  window.__state = {};
            \\  const io = new IntersectionObserver((entries) => {
            \\    for (const e of entries) {
            \\      window.__state[e.target.id] = e.isIntersecting;
            \\      window.__events.push(e.target.id + ':' + e.isIntersecting);
            \\    }
            \\  });
            \\  for (const el of scroller.children) io.observe(el);
            \\})()
        , null);
    }

    frame.js.env.runMicrotasks();
    try frame.js.env.runMacrotasks();

    {
        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();

        const initial = try ls.local.exec(
            "JSON.stringify([window.__state['item-0'], window.__state['item-1'], window.__state['item-2'], window.__state['item-3'], window.__state['sentinel']])",
            null,
        );
        try testing.expectString("[true,true,false,false,false]", try initial.toZig([]const u8));

        _ = try ls.local.exec("window.__events = []; document.getElementById('scroller').scrollTo(0, 400);", null);
    }

    frame.js.env.runMicrotasks();
    try frame.js.env.runMacrotasks();

    {
        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();

        const after_scroll = try ls.local.exec(
            "JSON.stringify([window.__state['item-0'], window.__state['item-1'], window.__state['item-2'], window.__state['item-3'], window.__state['sentinel']])",
            null,
        );
        try testing.expectString("[false,false,true,true,true]", try after_scroll.toZig([]const u8));
    }
}

test "WebApi: IntersectionObserver window scroll and rootMargin" {
    testing.test_session.experimental_features.layout_intersection = true;
    defer testing.test_session.experimental_features = .{};

    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();
    defer testing.test_session.browser.setViewportOverride(null);
    testing.test_session.browser.setViewportOverride(.{ .width = 800, .height = 400 });

    {
        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();

        try ls.local.eval(
            \\(function() {
            \\  const root = document.documentElement ?? document.appendChild(document.createElement('html'));
            \\  const body = document.body ?? root.appendChild(document.createElement('body'));
            \\  const spacer = body.appendChild(document.createElement('div'));
            \\  spacer.style.height = '600px';
            \\  const card = body.appendChild(document.createElement('div'));
            \\  card.id = 'card';
            \\  card.style.height = '200px';
            \\
            \\  window.__strict = null;
            \\  window.__preloaded = null;
            \\  new IntersectionObserver((es) => { window.__strict = es[es.length - 1].isIntersecting; }).observe(card);
            \\  new IntersectionObserver((es) => { window.__preloaded = es[es.length - 1].isIntersecting; }, { rootMargin: '0px 0px 250px 0px' }).observe(card);
            \\})()
        , null);
    }

    frame.js.env.runMicrotasks();
    try frame.js.env.runMacrotasks();

    {
        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();

        // At scrollY=0 with viewport height 400: card is at [600, 800], so
        // strict viewport [0, 400] misses it while +250px bottom rootMargin
        // [0, 650] intersects it.
        const initial = try ls.local.exec("JSON.stringify([window.__strict, window.__preloaded])", null);
        try testing.expectString("[false,true]", try initial.toZig([]const u8));

        _ = try ls.local.exec("window.scrollTo(0, 300);", null);
    }

    frame.js.env.runMicrotasks();
    try frame.js.env.runMacrotasks();

    {
        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();

        const scrolled = try ls.local.exec("JSON.stringify([window.__strict, window.__preloaded])", null);
        try testing.expectString("[true,true]", try scrolled.toZig([]const u8));
    }
}

test "WebApi: IntersectionObserver infinite-scroll sentinel loads successive batches" {
    testing.test_session.experimental_features.layout_intersection = true;
    defer testing.test_session.experimental_features = .{};

    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();
    defer testing.test_session.browser.setViewportOverride(null);
    testing.test_session.browser.setViewportOverride(.{ .width = 800, .height = 400 });

    {
        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();

        try ls.local.eval(
            \\(function() {
            \\  const root = document.documentElement ?? document.appendChild(document.createElement('html'));
            \\  const body = document.body ?? root.appendChild(document.createElement('body'));
            \\  const hero = body.appendChild(document.createElement('div'));
            \\  hero.style.height = '1000px';
            \\  const list = body.appendChild(document.createElement('div'));
            \\  list.id = 'list';
            \\  const sentinel = body.appendChild(document.createElement('div'));
            \\  sentinel.id = 'sentinel';
            \\  sentinel.style.height = '0px';
            \\
            \\  const io = new IntersectionObserver((entries) => {
            \\    for (const e of entries) {
            \\      if (!e.isIntersecting) continue;
            \\      for (let i = 0; i < 10; i++) {
            \\        const item = document.createElement('div');
            \\        item.className = 'item';
            \\        item.style.height = '100px';
            \\        list.appendChild(item);
            \\      }
            \\    }
            \\  });
            \\  io.observe(sentinel);
            \\})()
        , null);
    }

    frame.js.env.runMicrotasks();
    try frame.js.env.runMacrotasks();

    {
        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();

        const c0 = try ls.local.exec("String(document.querySelectorAll('#list .item').length)", null);
        try testing.expectString("0", try c0.toZig([]const u8));

        _ = try ls.local.exec("window.scrollTo(0, 800);", null);
    }

    frame.js.env.runMicrotasks();
    try frame.js.env.runMacrotasks();

    {
        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();

        const c1 = try ls.local.exec("String(document.querySelectorAll('#list .item').length)", null);
        try testing.expectString("10", try c1.toZig([]const u8));

        _ = try ls.local.exec("window.scrollTo(0, 1800);", null);
    }

    frame.js.env.runMicrotasks();
    try frame.js.env.runMacrotasks();

    {
        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();

        const c2 = try ls.local.exec("String(document.querySelectorAll('#list .item').length)", null);
        try testing.expectString("20", try c2.toZig([]const u8));
    }
}

test "WebApi: IntersectionObserver window scrollTo over 10 sections and img matches getBoundingClientRect" {
    testing.test_session.experimental_features.layout_intersection = true;
    defer testing.test_session.experimental_features = .{};

    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();
    defer testing.test_session.browser.setViewportOverride(null);
    testing.test_session.browser.setViewportOverride(.{ .width = 800, .height = 600 });

    {
        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();

        try ls.local.eval(
            \\(function() {
            \\  const root = document.documentElement ?? document.appendChild(document.createElement('html'));
            \\  const head = root.appendChild(document.createElement('head'));
            \\  const style = head.appendChild(document.createElement('style'));
            \\  style.textContent = 'section { height: 300px; }';
            \\  const body = document.body ?? root.appendChild(document.createElement('body'));
            \\  const main = body.appendChild(document.createElement('main'));
            \\  for (let i = 0; i < 10; i++) {
            \\    const sec = main.appendChild(document.createElement('section'));
            \\    const img = sec.appendChild(document.createElement('img'));
            \\    img.id = 'img-' + i;
            \\  }
            \\  window.__last = null;
            \\  const io = new IntersectionObserver((entries) => {
            \\    for (const e of entries) {
            \\      window.__last = {
            \\        intersecting: e.isIntersecting,
            \\        entryTop: e.boundingClientRect.top,
            \\        domTop: e.target.getBoundingClientRect().top,
            \\      };
            \\    }
            \\  });
            \\  io.observe(document.getElementById('img-9'));
            \\})()
        , null);
    }

    frame.js.env.runMicrotasks();
    try frame.js.env.runMacrotasks();

    {
        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();

        const before = try ls.local.exec("JSON.stringify([window.__last.intersecting, window.__last.entryTop, window.__last.domTop, document.documentElement.scrollHeight])", null);
        try testing.expectString("[false,2700,2700,3000]", try before.toZig([]const u8));

        _ = try ls.local.exec("window.scrollTo(0, 5000);", null);
    }

    frame.js.env.runMicrotasks();
    try frame.js.env.runMacrotasks();

    {
        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();

        const after = try ls.local.exec("JSON.stringify([window.__last.intersecting, window.__last.entryTop, window.__last.domTop, window.scrollY])", null);
        try testing.expectString("[true,300,300,2400]", try after.toZig([]const u8));
    }
}

test "WebApi: IntersectionObserver 2000 targets className toggle stays linear" {
    testing.test_session.experimental_features.layout_intersection = true;
    defer testing.test_session.experimental_features = .{};

    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();
    defer testing.test_session.browser.setViewportOverride(null);
    testing.test_session.browser.setViewportOverride(.{ .width = 800, .height = 600 });

    {
        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();

        try ls.local.eval(
            \\(function() {
            \\  const root = document.documentElement ?? document.appendChild(document.createElement('html'));
            \\  const head = root.appendChild(document.createElement('head'));
            \\  const style = head.appendChild(document.createElement('style'));
            \\  style.textContent = '.row { height: 40px; } .toggled { color: blue; }';
            \\  const body = document.body ?? root.appendChild(document.createElement('body'));
            \\  const toggle = body.appendChild(document.createElement('div'));
            \\  toggle.id = 'toggle';
            \\  const io = new IntersectionObserver(() => {});
            \\  for (let i = 0; i < 2000; i++) {
            \\    const d = body.appendChild(document.createElement('div'));
            \\    d.className = 'row';
            \\    io.observe(d);
            \\  }
            \\})()
        , null);
    }

    frame.js.env.runMicrotasks();
    try frame.js.env.runMacrotasks();

    const start_ms = lp.datetime.milliTimestamp(.boot);
    {
        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();

        _ = try ls.local.exec("document.getElementById('toggle').className = 'toggled';", null);
    }
    frame.js.env.runMicrotasks();
    const elapsed_ms = lp.datetime.milliTimestamp(.boot) - start_ms;
    try testing.expect(elapsed_ms < 100);
}

test "WebApi: IntersectionObserver does not retain cross-frame iframe targets after teardown" {
    testing.test_session.experimental_features.layout_intersection = true;
    defer testing.test_session.experimental_features = .{};

    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();

    {
        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();

        try ls.local.eval(
            \\(function() {
            \\  const root = document.documentElement ?? document.appendChild(document.createElement('html'));
            \\  const body = document.body ?? root.appendChild(document.createElement('body'));
            \\  const iframe = body.appendChild(document.createElement('iframe'));
            \\  iframe.id = 'child';
            \\  window.__io = new IntersectionObserver(() => {});
            \\  window.__io.observe(body);
            \\})()
        , null);
    }

    const child_frame = frame.child_frames.items[0];
    const child_div = try child_frame.document.createElement("div", null, child_frame);
    const io = frame._intersection.observers.items[0];
    try io.observe(child_div, frame);

    {
        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();

        _ = try ls.local.exec("document.getElementById('child').remove();", null);
    }

    frame.js.env.runMicrotasks();
    try frame.js.env.runMacrotasks();
    try testing.expectEqual(false, io._tracked.contains(child_div));
}

test "WebApi: IntersectionObserver virtualized absolute and translated rows in scroll container" {
    testing.test_session.experimental_features.layout_intersection = true;
    defer testing.test_session.experimental_features = .{};
    testing.test_session.browser.setViewportOverride(.{ .width = 800, .height = 600 });
    defer testing.test_session.browser.setViewportOverride(null);

    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();

    {
        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();

        try ls.local.eval(
            \\(function() {
            \\  const root = document.documentElement ?? document.appendChild(document.createElement('html'));
            \\  const body = document.body ?? root.appendChild(document.createElement('body'));
            \\  const scroller = body.appendChild(document.createElement('div'));
            \\  scroller.id = 'scroller';
            \\  scroller.style.cssText = 'overflow-y: auto; height: 600px;';
            \\  const spacer = scroller.appendChild(document.createElement('div'));
            \\  spacer.style.cssText = 'position: relative; height: 24000px;';
            \\
            \\  const row45 = spacer.appendChild(document.createElement('div'));
            \\  row45.id = 'row45';
            \\  row45.style.cssText = 'position: absolute; top: 9000px; left: 0; right: 0; height: 200px;';
            \\
            \\  const row90 = spacer.appendChild(document.createElement('div'));
            \\  row90.id = 'row90';
            \\  row90.style.cssText = 'position: absolute; top: 0; left: 0; width: 100%; height: 200px; transform: translateY(18000px);';
            \\
            \\  const oofScroller = body.appendChild(document.createElement('div'));
            \\  oofScroller.id = 'oofScroller';
            \\  oofScroller.style.cssText = 'position: relative; overflow-y: auto; height: 400px;';
            \\  const oofChild = oofScroller.appendChild(document.createElement('div'));
            \\  oofChild.style.cssText = 'position: absolute; top: 5000px; height: 200px;';
            \\
            \\  const fixedHud = body.appendChild(document.createElement('div'));
            \\  fixedHud.id = 'fixedHud';
            \\  fixedHud.style.cssText = 'position: fixed; bottom: 10px; right: 20px; width: 100px; height: 50px;';
            \\
            \\  const relBox = oofScroller.appendChild(document.createElement('div'));
            \\  relBox.id = 'relBox';
            \\  relBox.style.cssText = 'position: relative; inset-block-start: 15px; left: 25px; height: 30px;';
            \\
            \\  window.__state = {};
            \\  window.__io = new IntersectionObserver((entries) => {
            \\    for (const e of entries) {
            \\      window.__state[e.target.id] = {
            \\        isIntersecting: e.isIntersecting,
            \\        top: e.boundingClientRect.top,
            \\      };
            \\    }
            \\  }, { root: scroller });
            \\  window.__io.observe(row45);
            \\  window.__io.observe(row90);
            \\})()
        , null);
    }

    frame.js.env.runMicrotasks();
    try frame.js.env.runMacrotasks();

    {
        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();

        const init_json = try ls.local.exec(
            "JSON.stringify({ s: window.__state, r45: document.getElementById('row45').getBoundingClientRect().top, r90: document.getElementById('row90').getBoundingClientRect().top, oofH: document.getElementById('oofScroller').scrollHeight })",
            null,
        );
        try testing.expectString(
            "{\"s\":{\"row45\":{\"isIntersecting\":false,\"top\":9000},\"row90\":{\"isIntersecting\":false,\"top\":18000}},\"r45\":9000,\"r90\":18000,\"oofH\":5200}",
            try init_json.toZig([]const u8),
        );

        _ = try ls.local.exec("document.getElementById('scroller').scrollTop = 9000;", null);
    }

    frame.js.env.runMicrotasks();
    try frame.js.env.runMacrotasks();

    {
        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();

        const mid_json = try ls.local.exec(
            "JSON.stringify({ s: window.__state, r45: document.getElementById('row45').getBoundingClientRect().top, off45: document.getElementById('row45').offsetTop, w45: document.getElementById('row45').getBoundingClientRect().width, fx: [document.getElementById('fixedHud').getBoundingClientRect().left, document.getElementById('fixedHud').getBoundingClientRect().top], rel: [document.getElementById('relBox').getBoundingClientRect().left, document.getElementById('relBox').getBoundingClientRect().top - document.getElementById('oofScroller').getBoundingClientRect().top] })",
            null,
        );
        try testing.expectString(
            "{\"s\":{\"row45\":{\"isIntersecting\":true,\"top\":0},\"row90\":{\"isIntersecting\":false,\"top\":18000}},\"r45\":0,\"off45\":9000,\"w45\":800,\"fx\":[680,540],\"rel\":[25,15]}",
            try mid_json.toZig([]const u8),
        );

        _ = try ls.local.exec("document.getElementById('scroller').scrollTop = 18000;", null);
    }

    frame.js.env.runMicrotasks();
    try frame.js.env.runMacrotasks();

    {
        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();

        const end_json = try ls.local.exec(
            "JSON.stringify({ s: window.__state, r90: document.getElementById('row90').getBoundingClientRect().top })",
            null,
        );
        try testing.expectString(
            "{\"s\":{\"row45\":{\"isIntersecting\":false,\"top\":-9000},\"row90\":{\"isIntersecting\":true,\"top\":0}},\"r90\":0}",
            try end_json.toZig([]const u8),
        );
    }
}

test "WebApi: 2000 getBoundingClientRect calls stay O(N) with persistent box cache" {
    testing.test_session.experimental_features.layout_intersection = true;
    defer testing.test_session.experimental_features = .{};
    testing.test_session.browser.setViewportOverride(.{ .width = 800, .height = 600 });
    defer testing.test_session.browser.setViewportOverride(null);

    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();

    {
        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();

        try ls.local.eval(
            \\(function() {
            \\  const root = document.documentElement ?? document.appendChild(document.createElement('html'));
            \\  const body = document.body ?? root.appendChild(document.createElement('body'));
            \\  window.__items = [];
            \\  for (let i = 0; i < 2000; i++) {
            \\    const d = body.appendChild(document.createElement('div'));
            \\    d.style.height = '50px';
            \\    window.__items.push(d);
            \\  }
            \\})()
        , null);
    }

    const start_ms = lp.datetime.milliTimestamp(.boot);
    {
        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();

        const last_top = try ls.local.exec(
            \\(function() {
            \\  let last = 0;
            \\  for (let i = 0; i < window.__items.length; i++) {
            \\    last = window.__items[i].getBoundingClientRect().top;
            \\  }
            \\  return String(last);
            \\})()
        , null);
        try testing.expectString("99950", try last_top.toZig([]const u8));
    }
    const elapsed_ms = lp.datetime.milliTimestamp(.boot) - start_ms;
    try testing.expect(elapsed_ms < 100);
}

test "WebApi: IntersectionObserver explicit root in torn-down iframe does not convert to viewport observer" {
    testing.test_session.experimental_features.layout_intersection = true;
    defer testing.test_session.experimental_features = .{};
    testing.test_session.browser.setViewportOverride(.{ .width = 800, .height = 600 });
    defer testing.test_session.browser.setViewportOverride(null);

    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();

    {
        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();

        try ls.local.eval(
            \\(function() {
            \\  const root = document.documentElement ?? document.appendChild(document.createElement('html'));
            \\  const body = document.body ?? root.appendChild(document.createElement('body'));
            \\  const iframe = body.appendChild(document.createElement('iframe'));
            \\  iframe.id = 'child';
            \\  const target = body.appendChild(document.createElement('div'));
            \\  target.id = 'target';
            \\  target.style.height = '100px';
            \\  window.__last = null;
            \\  window.__io = new IntersectionObserver((entries) => {
            \\    window.__last = entries[entries.length - 1].isIntersecting;
            \\  });
            \\  window.__io.observe(target);
            \\})()
        , null);
    }

    const child_frame = frame.child_frames.items[0];
    const child_root = try child_frame.document.createElement("div", null, child_frame);
    const io = frame._intersection.observers.items[0];
    io._root = child_root;
    io._root_node = child_root.asNode();

    frame.js.env.runMicrotasks();
    try frame.js.env.runMacrotasks();

    try testing.expectEqual(false, io._root_dead);

    {
        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();

        _ = try ls.local.exec(
            \\document.getElementById('child').remove();
            \\document.getElementById('target').style.height = '120px';
        , null);
    }

    frame.js.env.runMicrotasks();
    try frame.js.env.runMacrotasks();

    try testing.expectEqual(true, io._root_dead);
    {
        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();

        const res = try ls.local.exec("String(window.__last)", null);
        try testing.expectString("false", try res.toZig([]const u8));
    }
}

test "WebApi: deeply nested bottom-anchored auto-height boxes, text reflow, and untransformed offsetTop" {
    testing.test_session.experimental_features.layout_intersection = true;
    defer testing.test_session.experimental_features = .{};
    testing.test_session.browser.setViewportOverride(.{ .width = 800, .height = 600 });
    defer testing.test_session.browser.setViewportOverride(null);

    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();

    const start_ms = lp.datetime.milliTimestamp(.boot);
    {
        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();

        try ls.local.eval(
            \\(function() {
            \\  const root = document.documentElement ?? document.appendChild(document.createElement('html'));
            \\  const body = document.body ?? root.appendChild(document.createElement('body'));
            \\  let cur = body;
            \\  for (let i = 0; i < 25; i++) {
            \\    const d = cur.appendChild(document.createElement('div'));
            \\    d.style.cssText = 'position: absolute; bottom: 1px; left: 0; width: 100px;';
            \\    cur = d;
            \\  }
            \\  const leaf = cur.appendChild(document.createElement('div'));
            \\  leaf.id = 'leaf';
            \\  leaf.style.height = '20px';
            \\
            \\  const trBox = body.appendChild(document.createElement('div'));
            \\  trBox.id = 'trBox';
            \\  trBox.style.cssText = 'position: absolute; top: 400px; left: 30px; height: 50px; transform: translate(120px, 500px);';
            \\
            \\  const textWrap = body.appendChild(document.createElement('div'));
            \\  textWrap.style.cssText = 'width: 40px; font-size: 16px;';
            \\  window.__tn = textWrap.appendChild(document.createTextNode('word '.repeat(200)));
            \\  const sentinel = body.appendChild(document.createElement('div'));
            \\  sentinel.id = 'sentinel';
            \\  sentinel.style.height = '10px';
            \\
            \\  window.__log = [];
            \\  new IntersectionObserver((es) => {
            \\    for (const e of es) window.__log.push([e.isIntersecting, e.boundingClientRect.top]);
            \\  }).observe(sentinel);
            \\})()
        , null);

        const metrics = try ls.local.exec(
            "JSON.stringify([document.getElementById('leaf').getBoundingClientRect().top, document.getElementById('trBox').getBoundingClientRect().top, document.getElementById('trBox').offsetTop, document.getElementById('trBox').offsetLeft])",
            null,
        );
        // 25 nested bottom: 1px shifts upward by 25px from viewport 600 -> 600 - 25 - 20 = 555.
        // trBox getBoundingClientRect().top includes translateY(500) = 900, while offsetTop/offsetLeft ignore transforms (400, 30).
        try testing.expectString("[555,900,400,30]", try metrics.toZig([]const u8));
    }
    const elapsed_ms = lp.datetime.milliTimestamp(.boot) - start_ms;
    try testing.expect(elapsed_ms < 100);

    frame.js.env.runMicrotasks();
    try frame.js.env.runMacrotasks();

    {
        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();

        _ = try ls.local.exec("window.__tn.data = 'x';", null);
    }

    frame.js.env.runMicrotasks();
    try frame.js.env.runMacrotasks();

    {
        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();

        const log_json = try ls.local.exec("JSON.stringify(window.__log.map((x) => x[0]))", null);
        try testing.expectString("[false,true]", try log_json.toZig([]const u8));
    }
}
