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

const Frame = @import("Frame.zig");
const StyleManager = @import("StyleManager.zig");
const text_measure = @import("text_measure.zig");

const Node = @import("webapi/Node.zig");
const CSS = @import("webapi/CSS.zig");
const Element = @import("webapi/Element.zig");
const Document = @import("webapi/Document.zig");
const DOMRect = @import("webapi/DOMRect.zig");
const TreeWalker = @import("webapi/TreeWalker.zig");

// Width flows down (height flows up): a block in normal flow is as wide as
// its containing block.
pub fn boxWidth(self: *Element, owner: *Frame) f64 {
    const style_manager = &owner._style_manager;
    if (style_manager.cachedWidth(self, .box)) |width| {
        return width;
    }
    const fill = StyleManager.fill_check.enter(style_manager);
    defer StyleManager.fill_check.exit(fill);

    const own = self.getElementAxis(owner, .width);
    const width = blk: {
        if (self.isRootContainer()) {
            // html/body return their set value regardless of children.
            break :blk own.value;
        }
        const sizing = style_manager.widthSizing(self);
        if (sizing == .contents) {
            break :blk 0;
        }
        if (style_manager.isFlexRowItem(self)) {
            const row = style_manager.boxParent(self).?;
            const item = flexBase(self, boxWidth(row, owner), owner);
            // Snapped to Chrome's 1/64px layout unit, past the float error
            const shrunk = @round(item.base * (1 - rowShrinkRatio(row, owner)) * 64) / 64;
            var width = @max(item.floor, shrunk);
            if (sizing == .grow and own.explicit == false) {
                width = @max(width, growShare(self, owner));
            }
            break :blk clampWidth(self, width, .box, owner);
        }
        const width = if (own.explicit) own.value else switch (sizing) {
            .fixed => |width| width,
            .percent => |fraction| fraction * containingBlockWidth(self, owner),
            .fill => fillWidth(self, owner),
            .grow, .shrink => @max(own.value, contentWidth(self, .clipped, owner)),
            .contents => unreachable,
        };
        break :blk clampWidth(self, width, .box, owner);
    };
    style_manager.cacheWidth(self, .box, width);
    return width;
}

// How a box that clips its overflow counts toward its ancestors' content.
// Out-of-flow boxes take no room in their parent's flow, so they don't size
// it, but they still extend a scroller's scrollable area.
pub const ContentMode = enum {
    full,
    clipped,
    // clipped, with out-of-flow boxes counted
    scrollable,
};

// What the box, with its margins, adds to its parent's content width.
fn widthContribution(self: *Element, comptime mode: ContentMode, owner: *Frame) f64 {
    const style_manager = &owner._style_manager;
    const own = self.getElementAxis(owner, .width);
    const width = if (own.explicit) own.value else switch (style_manager.widthSizing(self)) {
        .fixed => |width| width,
        .shrink, .grow => @max(own.value, contentWidth(self, mode, owner)),
        .percent, .fill => if (mode != .full and style_manager.clipsOverflowX(self)) 0 else contentWidth(self, mode, owner),
        .contents => return contentWidth(self, mode, owner),
    };
    return clampWidth(self, width, .contribution, owner) + style_manager.inlineMargins(self, null);
}

const FlexBase = struct {
    base: f64, // The width before the row shrinks it
    floor: f64, // The least it shrinks to; base when it doesn't shrink
};

// Get a flex row's item hypothetical width and how far it can shrink.
// No flex-basis (yet?)/
fn flexBase(self: *Element, row_width: f64, owner: *Frame) FlexBase {
    const style_manager = &owner._style_manager;
    const own = self.getElementAxis(owner, .width);
    const width = if (own.explicit) own.value else switch (style_manager.widthSizing(self)) {
        .fixed => |width| width,
        .percent => |fraction| fraction * row_width,
        .shrink, .grow, .fill => @max(own.value, contentWidth(self, .full, owner)),
        .contents => return .{
            .base = widthContribution(self, .full, owner),
            .floor = widthContribution(self, .clipped, owner),
        },
    };
    const base = clampWidth(self, width, .box, owner);
    if (style_manager.flexShrinks(self) == false) {
        return .{ .base = base, .floor = base };
    }
    return .{ .base = base, .floor = flexMinWidth(self, base, owner) };
}

// min-width: auto on a flex item: no narrower than its content, or than its
// width if that's narrower; 0 if it clips its overflow (CSS Flexbox §4.5).
// Content its descendants clip doesn't count. A declared min-width replaces
// it, and clampWidth applies that one.
fn flexMinWidth(self: *Element, base: f64, owner: *Frame) f64 {
    const style_manager = &owner._style_manager;
    if (style_manager.widthLimits(self).min != null or style_manager.clipsOverflowX(self)) {
        return 0;
    }
    if (self.getTag().isReplacedOrControl()) {
        // Its intrinsic width is unknown
        return base;
    }
    const own = self.getElementAxis(owner, .width);
    const content = contentWidth(self, .clipped, owner);
    // An auto width's fallback stands in for its text
    return @min(base, if (own.explicit) content else @max(own.value, content));
}

// The fraction of its base each shrinking item of an overflowing flex row
// gives up: the overflow split in proportion to the bases (a flex-shrink is
// 0 or 1 here). Items that would drop below their floor freeze there and the
// rest share what they couldn't give (CSS Flexbox §9.7). A wrapping row moves
// items to a new line instead, so it shrinks nothing.
fn rowShrinkRatio(self: *Element, owner: *Frame) f64 {
    const style_manager = &owner._style_manager;
    if (style_manager.flexWraps(self)) {
        return 0;
    }
    if (style_manager.cachedWidth(self, .row_shrink)) |ratio| {
        return ratio;
    }
    const fill = StyleManager.fill_check.enter(style_manager);
    defer StyleManager.fill_check.exit(fill);

    const row_width = boxWidth(self, owner);
    var total: f64 = 0;
    var items: TreeWalker.FlatChildren = .init(self.asNode(), .{ .frame = owner });
    while (nextFlexItem(&items, style_manager)) |el| {
        total += flexBase(el, row_width, owner).base + flexItemMargins(el, row_width, style_manager);
    }

    var ratio: f64 = 0;
    const overflow = total - row_width;
    if (overflow > 0) {
        // Freezing an item leaves more for the others to give, so the ratio
        // only grows between passes and a frozen item stays frozen: each pass
        // freezes at least one more item, or the count holds and it's settled.
        var frozen_before: ?usize = null;
        while (true) {
            var frozen: usize = 0;
            var given: f64 = 0;
            var shrinkable: f64 = 0;
            items = .init(self.asNode(), .{ .frame = owner });
            while (nextFlexItem(&items, style_manager)) |el| {
                const item = flexBase(el, row_width, owner);
                if (item.base <= item.floor) {
                    continue;
                }
                if (item.base * (1 - ratio) < item.floor) {
                    frozen += 1;
                    given += item.base - item.floor;
                } else {
                    shrinkable += item.base;
                }
            }
            ratio = if (shrinkable == 0) 1 else std.math.clamp((overflow - given) / shrinkable, 0, 1);
            if (frozen_before) |previous| {
                if (frozen <= previous) break;
            }
            frozen_before = frozen;
        }
    }
    style_manager.cacheWidth(self, .row_shrink, ratio);
    return ratio;
}

// The next child of a flex row that is one of its items: rendered and in flow.
fn nextFlexItem(children: *TreeWalker.FlatChildren, style_manager: *StyleManager) ?*Element {
    while (children.next()) |node| {
        const el = node.is(Element) orelse continue;
        if (style_manager.hasDisplayNone(el) or style_manager.isFlexRowItem(el) == false) {
            continue;
        }
        return el;
    }
    return null;
}

// display: contents has no margins; its children's are in its contribution.
fn flexItemMargins(el: *Element, row_width: f64, style_manager: *StyleManager) f64 {
    if (style_manager.widthSizing(el) == .contents) {
        return 0;
    }
    return style_manager.inlineMargins(el, row_width);
}

// max-width caps the width, min-width wins over both.
fn clampWidth(self: *Element, width: f64, comptime of: enum { box, contribution }, owner: *Frame) f64 {
    const limits = owner._style_manager.widthLimits(self);
    var clamped = width;
    if (limits.max) |max| {
        clamped = @min(clamped, resolveWidthLimit(self, max, of == .box, owner) orelse clamped);
    }
    if (limits.min) |min| {
        clamped = @max(clamped, resolveWidthLimit(self, min, of == .box, owner) orelse clamped);
    }
    return clamped;
}

fn resolveWidthLimit(self: *Element, limit: StyleManager.WidthLimit, resolve_percent: bool, owner: *Frame) ?f64 {
    return switch (limit) {
        .px => |px| px,
        .percent => |fraction| if (resolve_percent) fraction * containingBlockWidth(self, owner) else null,
    };
}

// A block in normal flow fills its containing block, less its margins; a
// positioned box pinned on both sides, less its offsets too.
fn fillWidth(self: *Element, owner: *Frame) f64 {
    const style_manager = &owner._style_manager;
    const containing = containingBlockWidth(self, owner);
    return @max(0, containing - style_manager.inlineMargins(self, containing) - style_manager.inlineInsets(self, containing));
}

/// The width of the containing block; the viewport above the root.
fn containingBlockWidth(self: *Element, owner: *Frame) f64 {
    const parent = owner._style_manager.containingBlock(self) orelse {
        return @floatFromInt(owner.page.getViewport().width);
    };
    return boxWidth(parent, owner);
}

/// A growing flex item's share: the row's free space, after the siblings
/// that don't grow and everyone's margins, split evenly among those that do.
fn growShare(self: *Element, owner: *Frame) f64 {
    const style_manager = &owner._style_manager;
    const parent = style_manager.boxParent(self) orelse return 0;
    const row_width = boxWidth(parent, owner);
    var taken: f64 = 0;
    var growers: f64 = 0;
    var items: TreeWalker.FlatChildren = .init(parent.asNode(), .{ .frame = owner });
    while (nextFlexItem(&items, style_manager)) |el| {
        switch (style_manager.widthSizing(el)) {
            .grow => growers += 1,
            // Its children are the row's items
            .contents => taken += widthContribution(el, .clipped, owner),
            // Only walks up, and the row's width never reads a child's box
            else => taken += boxWidth(el, owner),
        }
        taken += flexItemMargins(el, row_width, style_manager);
    }
    return @max(0, row_width - taken) / @max(1, growers);
}

// The width the children would take unconstrained: the sum of their
// contributions. In a flex row or grid they sit side by side; elsewhere
// block-level children stack, so the widest counts, and inline-level ones
// share one line that never wraps (the dummy layout has no line breaking,
// which keeps the "append until the lane outgrows its shell" idiom
// terminating).
pub fn contentWidth(self: *Element, comptime mode: ContentMode, owner: *Frame) f64 {
    const kind: StyleManager.WidthKind = switch (mode) {
        .full => .full_content,
        .clipped => .content,
        .scrollable => .scrollable_content,
    };
    const style_manager = &owner._style_manager;
    if (style_manager.cachedWidth(self, kind)) |width| {
        return width;
    }
    const fill = StyleManager.fill_check.enter(style_manager);
    defer StyleManager.fill_check.exit(fill);

    const in_row = style_manager.laysOutInRow(self);
    var widest: f64 = 0;
    var line: f64 = 0;
    var children: TreeWalker.FlatChildren = .init(self.asNode(), .{ .frame = owner });
    while (children.next()) |node| {
        const el = node.is(Element) orelse continue;
        if (style_manager.hasDisplayNone(el)) {
            continue;
        }
        if (mode != .scrollable and style_manager.isOutOfFlow(el)) {
            continue;
        }
        const width = widthContribution(el, mode, owner);
        if (in_row or style_manager.isBlockLevel(el) == false) {
            line += width;
        } else {
            widest = @max(widest, line, width);
            line = 0;
        }
    }
    const width = @max(widest, line);
    style_manager.cacheWidth(self, kind, width);
    return width;
}

pub const Box = struct {
    rect: DOMRect.Data = .{},
    scroll_height: f64 = 0,
    untransformed_x: f64 = 0,
    untransformed_y: f64 = 0,
};

pub const BoxMap = std.AutoHashMapUnmanaged(*const Element, Box);

const ContainingBlock = struct {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    explicit_h: bool,
    tr_x: f64 = 0,
    tr_y: f64 = 0,
};

const SubtreeMetrics = struct {
    placed_x: f64 = 0,
    placed_y: f64 = 0,
    box_w: f64 = 0,
    box_h: f64 = 0,
    flow_h: f64 = 0,
    scroll_w: f64 = 0,
    scroll_h: f64 = 0,
};

fn containsAsciiIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) {
            return true;
        }
    }
    return false;
}

fn inlineTranslateOffset(el: *Element, owner: *Frame) CSS.TranslateOffset {
    if (!el._flags.has_inline_style) {
        return .{};
    }
    if (el.existingStyle(owner)) |style| {
        const val = style.asCSSStyleDeclaration().getKnownPropertyValue(.transform, owner);
        return if (val.len == 0) .{} else CSS.parseTranslateXY(val);
    }
    const attr = el.getAttributeInterned("style") orelse return .{};
    if (!containsAsciiIgnoreCase(attr, "transform")) {
        return .{};
    }
    if (el.inlineStyle(owner)) |style| {
        const val = style.asCSSStyleDeclaration().getKnownPropertyValue(.transform, owner);
        return if (val.len == 0) .{} else CSS.parseTranslateXY(val);
    }
    return .{};
}

const KnownHeight = struct {
    value: f64,
    explicit: bool,
};

fn resolveKnownHeight(
    el: *Element,
    pos: StyleManager.Position,
    insets: StyleManager.InsetOffsets,
    ref_cb: ContainingBlock,
    parent_h: f64,
    parent_explicit_h: bool,
    style_manager: *StyleManager,
    owner: *Frame,
) KnownHeight {
    const own_h = el.getElementAxis(owner, .height);
    if (own_h.explicit) {
        return .{ .value = own_h.value, .explicit = true };
    }
    const is_oof = pos == .absolute or pos == .fixed;
    if (style_manager.heightPercent(el)) |pct| {
        if (is_oof) {
            if (ref_cb.explicit_h) {
                return .{ .value = @max(0.0, ref_cb.h * pct), .explicit = true };
            }
        } else if (parent_explicit_h) {
            return .{ .value = @max(0.0, parent_h * pct), .explicit = true };
        }
    }
    if (is_oof and ref_cb.explicit_h) {
        if (insets.top != null and insets.bottom != null) {
            return .{ .value = @max(0.0, ref_cb.h - insets.top.? - insets.bottom.?), .explicit = true };
        }
    }
    return .{ .value = own_h.value, .explicit = false };
}

/// Single-pass O(N) traversal of `frame.document` computing viewport-relative
/// boxes and scroll heights for every rendered element, returning the
/// document's flow extent. When `map` is null, zero allocations occur.
pub fn populateFrameBoxes(
    frame: *Frame,
    allocator: std.mem.Allocator,
    map: ?*BoxMap,
) !Document.Extent {
    const style_manager = &frame._style_manager;

    const vp = frame.page.getViewport();
    const vp_w: f64 = @floatFromInt(vp.width);
    const vp_h: f64 = @floatFromInt(vp.height);
    const scroll_x: f64 = @floatFromInt(frame.window.getScrollX());
    const scroll_y: f64 = @floatFromInt(frame.window.getScrollY());

    const icb: ContainingBlock = .{
        .x = -scroll_x,
        .y = -scroll_y,
        .w = vp_w,
        .h = vp_h,
        .explicit_h = true,
    };
    const fcb: ContainingBlock = .{
        .x = 0.0,
        .y = 0.0,
        .w = vp_w,
        .h = vp_h,
        .explicit_h = true,
    };

    var cursor_y: f64 = 0;
    var widest_w: f64 = 0;
    var max_h: f64 = 0;

    var doc_children: TreeWalker.FlatChildren = .init(frame.document.asNode(), .{ .frame = frame });
    while (doc_children.next()) |node| {
        const el = node.is(Element) orelse continue;
        if (style_manager.hasDisplayNone(el)) continue;

        const is_fixed = style_manager.position(el) == .fixed;
        const ox = if (is_fixed) 0.0 else -scroll_x;
        const oy = if (is_fixed) 0.0 else -scroll_y + cursor_y;
        const m = try layoutSubtree(el, ox, oy, 0.0, 0.0, icb, fcb, is_fixed, vp_w, vp_h, false, frame, allocator, map);
        if (!style_manager.isOutOfFlow(el)) {
            cursor_y += m.flow_h;
        }
        widest_w = @max(widest_w, m.scroll_w);
        max_h = @max(max_h, cursor_y, m.scroll_h);
    }

    const rounded: Document.Extent = .{ .width = @ceil(widest_w), .height = @ceil(max_h) };
    frame.document.cacheExtent(rounded);

    if (map) |m| {
        if (frame.document.getDocumentElement()) |doc_el| {
            if (style_manager.inlineSize(doc_el, .height) == null) {
                if (m.getPtr(doc_el)) |entry| {
                    entry.rect.height = rounded.height;
                    entry.scroll_height = @max(entry.scroll_height, rounded.height);
                }
            }
        }
        if (frame.document.getBody()) |html_body| {
            const body = html_body.asElement();
            if (style_manager.inlineSize(body, .height) == null) {
                if (m.getPtr(body)) |entry| {
                    entry.rect.height = rounded.height;
                    entry.scroll_height = @max(entry.scroll_height, rounded.height);
                }
            }
        }
    }

    return rounded;
}

/// Lazily populates (and returns) the frame's persistent O(N) layout box cache,
/// rebuilding only when DOM/style/scroll/viewport state has changed.
pub fn ensureBoxCache(frame: *Frame) !*const BoxMap {
    const ic = &frame._intersection;
    const style_ver = frame._style_manager.layoutVersion();
    const box_ver = frame._box_layout_version;
    const vp = frame.page.getViewport();
    if (ic.box_cache_valid and
        ic.box_cache_style_version == style_ver and
        ic.box_cache_box_version == box_ver and
        ic.box_cache_vp_width == vp.width and
        ic.box_cache_vp_height == vp.height)
    {
        return &ic.box_cache;
    }

    std.debug.assert(!ic.box_cache_building);
    ic.box_cache_building = true;
    defer ic.box_cache_building = false;

    ic.box_cache.clearRetainingCapacity();
    const allocator = frame._session.browser.allocator;
    const ext = try populateFrameBoxes(frame, allocator, &ic.box_cache);
    ic.cached_extent = ext;
    ic.box_cache_style_version = frame._style_manager.layoutVersion();
    ic.box_cache_box_version = frame._box_layout_version;
    ic.box_cache_vp_width = vp.width;
    ic.box_cache_vp_height = vp.height;
    ic.box_cache_valid = true;
    return &ic.box_cache;
}

pub fn documentFlowExtent(frame: *Frame) Document.Extent {
    if (ensureBoxCache(frame)) |_| {
        return frame._intersection.cached_extent;
    } else |_| {
        return populateFrameBoxes(frame, undefined, null) catch unreachable;
    }
}

fn shiftNonFixedDescendantsY(el: *Element, dy: f64, owner: *Frame, map: *BoxMap) void {
    const style_manager = &owner._style_manager;
    var children: TreeWalker.FlatChildren = .init(el.asNode(), .{ .frame = owner });
    while (children.next()) |node| {
        const child = node.is(Element) orelse continue;
        if (style_manager.hasDisplayNone(child)) continue;
        const child_contents = !child.isRootContainer() and style_manager.hasDisplayContents(child);
        if (!child_contents and style_manager.position(child) == .fixed) continue;
        if (!child_contents) {
            if (map.getPtr(child)) |entry| {
                entry.rect.y += dy;
                entry.untransformed_y += dy;
            }
        }
        shiftNonFixedDescendantsY(child, dy, owner, map);
    }
}

fn layoutSubtree(
    el: *Element,
    static_x: f64,
    static_y: f64,
    acc_tr_x: f64,
    acc_tr_y: f64,
    cb: ContainingBlock,
    fcb: ContainingBlock,
    in_fixed: bool,
    parent_w: f64,
    parent_h: f64,
    parent_explicit_h: bool,
    owner: *Frame,
    allocator: std.mem.Allocator,
    map: ?*BoxMap,
) !SubtreeMetrics {
    const style_manager = &owner._style_manager;
    const is_root = el.isRootContainer();
    const is_contents = !is_root and style_manager.hasDisplayContents(el);
    const pos: StyleManager.Position = if (is_contents)
        .static
    else
        style_manager.position(el);

    const inline_root_w = if (is_root) style_manager.inlineSize(el, .width) else null;
    const inline_root_h = if (is_root) style_manager.inlineSize(el, .height) else null;
    const box_w: f64 = if (is_contents)
        0.0
    else if (is_root)
        (inline_root_w orelse fcb.w)
    else
        boxWidth(el, owner);

    const ref_cb: ContainingBlock = if (pos == .fixed) fcb else cb;
    const insets: StyleManager.InsetOffsets = if (pos == .static)
        .{}
    else if (pos == .relative or pos == .sticky)
        style_manager.insetOffsets(el, parent_w, if (parent_explicit_h) parent_h else 0.0)
    else
        style_manager.insetOffsets(el, ref_cb.w, if (ref_cb.explicit_h) ref_cb.h else 0.0);

    const known_h: KnownHeight = if (is_root or is_contents)
        .{ .value = inline_root_h orelse 0.0, .explicit = inline_root_h != null }
    else
        resolveKnownHeight(el, pos, insets, ref_cb, parent_h, parent_explicit_h, style_manager, owner);

    var ox = static_x;
    var oy = static_y;
    var base_tr_x = acc_tr_x;
    var base_tr_y = acc_tr_y;
    var deferred_bottom: ?f64 = null;
    const tr: CSS.TranslateOffset = if (!is_contents) inlineTranslateOffset(el, owner) else .{};
    if (!is_contents) {
        switch (pos) {
            .static, .sticky => {},
            .relative => {
                ox += insets.left orelse -(insets.right orelse 0.0);
                oy += insets.top orelse -(insets.bottom orelse 0.0);
            },
            .absolute, .fixed => {
                if (insets.left) |l| {
                    ox = ref_cb.x + l;
                    base_tr_x = ref_cb.tr_x;
                } else if (insets.right) |r| {
                    ox = ref_cb.x + ref_cb.w - r - box_w;
                    base_tr_x = ref_cb.tr_x;
                } else {
                    ox = static_x;
                }

                if (insets.top) |t| {
                    oy = ref_cb.y + t;
                    base_tr_y = ref_cb.tr_y;
                } else if (insets.bottom) |b| {
                    base_tr_y = ref_cb.tr_y;
                    if (known_h.explicit) {
                        oy = ref_cb.y + ref_cb.h - b - known_h.value;
                    } else {
                        // Lay out children once at provisional oy=0, then shift
                        // non-fixed descendants in O(subtree) once box_h is known.
                        oy = 0.0;
                        deferred_bottom = b;
                    }
                } else {
                    oy = static_y;
                }
            },
        }
        ox += tr.x;
        oy += tr.y;
    }
    const self_tr_x = if (is_contents) acc_tr_x else base_tr_x + tr.x;
    const self_tr_y = if (is_contents) acc_tr_y else base_tr_y + tr.y;

    var content_x = ox;
    var content_y = oy;
    if (!is_root and !is_contents) {
        if (owner.page.element_scroll_positions.get(el)) |scroll| {
            content_x -= @floatFromInt(scroll.x);
            content_y -= @floatFromInt(scroll.y);
        }
    }

    const child_cb: ContainingBlock = if (!is_contents and pos != .static) .{
        .x = content_x,
        .y = content_y,
        .w = box_w,
        .h = if (is_root) (inline_root_h orelse fcb.h) else known_h.value,
        .explicit_h = if (is_root) true else known_h.explicit,
        .tr_x = self_tr_x,
        .tr_y = self_tr_y,
    } else cb;

    const child_parent_w: f64 = if (is_contents) parent_w else box_w;
    const child_parent_h: f64 = if (is_root)
        (inline_root_h orelse fcb.h)
    else if (is_contents)
        parent_h
    else
        known_h.value;
    const child_parent_explicit_h: bool = if (is_root)
        (inline_root_h != null)
    else if (is_contents)
        parent_explicit_h
    else
        known_h.explicit;

    var wrap: ?text_measure.LineWrap = null;
    if (!is_root and !is_contents) {
        const own_w = el.getElementAxis(owner, .width);
        if (own_w.explicit) {
            wrap = .{
                .line_width = own_w.value,
                .font_size = style_manager.computedFontSize(el),
                .white_space = style_manager.whiteSpace(el),
            };
        }
    }

    const in_row = style_manager.laysOutInRow(el);
    var cursor_y: f64 = 0;
    var line_x: f64 = 0;
    var line_h: f64 = 0;
    var max_oof_h: f64 = 0;
    var widest_w: f64 = 0;

    var children: TreeWalker.FlatChildren = .init(el.asNode(), .{ .frame = owner });
    while (children.next()) |node| {
        const child = node.is(Element) orelse {
            if (wrap) |*w| {
                if (node.is(Node.CData.Text)) |text| {
                    w.add(text.ownData());
                }
            }
            continue;
        };
        if (style_manager.hasDisplayNone(child)) continue;

        if (!child.isRootContainer() and style_manager.hasDisplayContents(child)) {
            cursor_y += line_h;
            line_x = 0;
            line_h = 0;
            const cm = try layoutSubtree(child, content_x, content_y + cursor_y, self_tr_x, self_tr_y, child_cb, fcb, in_fixed, child_parent_w, child_parent_h, child_parent_explicit_h, owner, allocator, map);
            cursor_y += cm.flow_h;
            max_oof_h = @max(max_oof_h, cm.scroll_h);
            widest_w = @max(widest_w, cm.scroll_w);
            continue;
        }

        if (style_manager.isOutOfFlow(child)) {
            const child_fixed = style_manager.position(child) == .fixed;
            const child_in_line = in_row or !style_manager.isBlockLevel(child);
            const static_cx = if (child_in_line) content_x + line_x else content_x;
            const static_cy = if (child_in_line) content_y + cursor_y else content_y + cursor_y + line_h;
            const cm = try layoutSubtree(child, static_cx, static_cy, self_tr_x, self_tr_y, child_cb, fcb, in_fixed or child_fixed, child_parent_w, child_parent_h, child_parent_explicit_h, owner, allocator, map);
            if (!child_fixed) {
                const child_ext_h = if (style_manager.clipsOverflowY(child)) cm.box_h else @max(cm.box_h, cm.scroll_h);
                const child_ext_w = if (style_manager.clipsOverflowX(child)) cm.box_w else @max(cm.box_w, cm.scroll_w);
                max_oof_h = @max(max_oof_h, @max(0.0, cm.placed_y - content_y) + child_ext_h);
                widest_w = @max(widest_w, @max(0.0, cm.placed_x - content_x) + child_ext_w);
            }
            continue;
        }

        if (in_row or !style_manager.isBlockLevel(child)) {
            const cm = try layoutSubtree(child, content_x + line_x, content_y + cursor_y, self_tr_x, self_tr_y, child_cb, fcb, in_fixed, child_parent_w, child_parent_h, child_parent_explicit_h, owner, allocator, map);
            line_x += cm.box_w;
            line_h = @max(line_h, cm.box_h);
            widest_w = @max(widest_w, line_x);
            const child_ext_h = if (style_manager.clipsOverflowY(child)) cm.box_h else @max(cm.box_h, cm.scroll_h);
            max_oof_h = @max(max_oof_h, @max(0.0, cm.placed_y - content_y) + child_ext_h);
        } else {
            cursor_y += line_h;
            line_x = 0;
            line_h = 0;
            const cm = try layoutSubtree(child, content_x, content_y + cursor_y, self_tr_x, self_tr_y, child_cb, fcb, in_fixed, child_parent_w, child_parent_h, child_parent_explicit_h, owner, allocator, map);
            cursor_y += cm.box_h;
            widest_w = @max(widest_w, cm.box_w);
            const child_ext_h = if (style_manager.clipsOverflowY(child)) cm.box_h else @max(cm.box_h, cm.scroll_h);
            max_oof_h = @max(max_oof_h, @max(0.0, cm.placed_y - content_y) + child_ext_h);
        }
    }

    cursor_y += line_h;
    if (wrap) |w| {
        cursor_y += @ceil(w.height());
    }

    if (is_contents) {
        if (map) |m| {
            try m.put(allocator, el, .{});
        }
        return .{
            .placed_x = ox,
            .placed_y = oy,
            .box_w = 0,
            .box_h = 0,
            .flow_h = cursor_y,
            .scroll_w = widest_w,
            .scroll_h = @max(cursor_y, max_oof_h),
        };
    }

    if (is_root) {
        const scroll_h = @max(cursor_y, max_oof_h, inline_root_h orelse 0.0);
        const box_h = inline_root_h orelse scroll_h;
        if (deferred_bottom) |b| {
            const final_oy = (ref_cb.y + ref_cb.h - b - box_h) + tr.y;
            const dy = final_oy - oy;
            oy = final_oy;
            if (map) |m| {
                if (dy != 0.0) shiftNonFixedDescendantsY(el, dy, owner, m);
            }
        }
        if (map) |m| {
            try m.put(allocator, el, .{
                .rect = .{ .x = ox, .y = oy, .width = box_w, .height = box_h },
                .scroll_height = scroll_h,
                .untransformed_x = ox - self_tr_x,
                .untransformed_y = oy - self_tr_y,
            });
        }
        return .{
            .placed_x = ox,
            .placed_y = oy,
            .box_w = box_w,
            .box_h = box_h,
            .flow_h = scroll_h,
            .scroll_w = @max(widest_w, inline_root_w orelse 0.0),
            .scroll_h = scroll_h,
        };
    }

    const box_h = if (known_h.explicit) known_h.value else @max(known_h.value, cursor_y);
    const scroll_h = @max(box_h, cursor_y, max_oof_h);
    if (deferred_bottom) |b| {
        const final_oy = (ref_cb.y + ref_cb.h - b - box_h) + tr.y;
        const dy = final_oy - oy;
        oy = final_oy;
        if (map) |m| {
            if (dy != 0.0) shiftNonFixedDescendantsY(el, dy, owner, m);
        }
    }

    if (map) |m| {
        try m.put(allocator, el, .{
            .rect = .{ .x = ox, .y = oy, .width = box_w, .height = box_h },
            .scroll_height = scroll_h,
            .untransformed_x = ox - self_tr_x,
            .untransformed_y = oy - self_tr_y,
        });
    }

    return .{
        .placed_x = ox,
        .placed_y = oy,
        .box_w = box_w,
        .box_h = box_h,
        .flow_h = box_h,
        .scroll_w = @max(box_w, widest_w),
        .scroll_h = scroll_h,
    };
}

pub fn boxHeight(self: *Element, owner: *Frame) f64 {
    if (ensureBoxCache(owner)) |cache| {
        if (cache.get(self)) |b| return b.rect.height;
    } else |_| {}
    if (self.isRootContainer()) {
        return self.getElementAxis(owner, .height).value;
    }
    return 0;
}

pub fn scrollHeight(self: *Element, owner: *Frame) f64 {
    if (ensureBoxCache(owner)) |cache| {
        if (cache.get(self)) |b| return b.scroll_height;
    } else |_| {}
    return 0;
}

pub fn elementClientRect(self: *Element, owner: *Frame) DOMRect.Data {
    if (ensureBoxCache(owner)) |cache| {
        if (cache.get(self)) |b| return b.rect;
    } else |_| {}
    return .{};
}

pub fn elementUntransformedPos(self: *Element, owner: *Frame) struct { x: f64, y: f64 } {
    if (ensureBoxCache(owner)) |cache| {
        if (cache.get(self)) |b| return .{ .x = b.untransformed_x, .y = b.untransformed_y };
    } else |_| {}
    return .{ .x = 0, .y = 0 };
}
