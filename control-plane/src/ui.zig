const std = @import("std");
const doppio = @import("doppio");
const sync = @import("sync.zig");
const storage = @import("storage.zig");
const admin = @import("admin.zig");
const experiment = @import("experiment.zig");
const blastradius = @import("blastradius.zig");

const Io = std.Io;

const WriterError = Io.Writer.Error;

/// HTML escaping helper. Shared by every template so no page can forget it.
pub fn escapeHtml(out: *Io.Writer, raw: []const u8) WriterError!void {
    for (raw) |c| {
        switch (c) {
            '&' => try out.writeAll("&amp;"),
            '<' => try out.writeAll("&lt;"),
            '>' => try out.writeAll("&gt;"),
            '"' => try out.writeAll("&quot;"),
            '\'' => try out.writeAll("&#39;"),
            else => try out.writeByte(c),
        }
    }
}

/// HTMX is served from a CDN in v1; no build step is needed and the page
/// degrades to plain HTML when the script is blocked.
const htmx_script =
    \\<script src="https://unpkg.com/htmx.org@2.0.4" crossorigin="anonymous"></script>
;

pub const ActivePage = enum { flags, segments, change_requests, audit, experiments };

pub const Page = struct {
    html: []const u8,
    content_type: []const u8 = "text/html; charset=utf-8",
};

/// Shared scaffold. HTMX fragments reuse the same fragment renderers, so a full
/// page and a partial swap can never drift apart.
fn layout(out: *Io.Writer, active: ActivePage, title: []const u8) WriterError!void {
    try out.writeAll(
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head>
        \\<meta charset="utf-8">
        \\<meta name="viewport" content="width=device-width, initial-scale=1">
        \\<title>
    );
    try escapeHtml(out, title);
    try out.writeAll(
        \\ - Doppio Admin</title>
        \\<style>
        \\:root{--bg:#0d1117;--panel:#161b22;--line:#30363d;--fg:#c9d1d9;--dim:#8b949e;--acc:#58a6ff;--ok:#3fb950;--warn:#d29922;--bad:#f85149}
        \\*{box-sizing:border-box}
        \\body{margin:0;font:14px/1.5 ui-sans-serif,system-ui,sans-serif;background:var(--bg);color:var(--fg)}
        \\header{display:flex;align-items:center;gap:20px;padding:12px 20px;background:var(--panel);border-bottom:1px solid var(--line);position:sticky;top:0;z-index:5}
        \\header .brand{font-weight:700;color:var(--acc);letter-spacing:.5px}
        \\header nav{display:flex;gap:4px}
        \\header nav a{padding:6px 12px;border-radius:6px;color:var(--dim);text-decoration:none}
        \\header nav a:hover{background:#21262d;color:var(--fg)}
        \\header nav a[aria-current=page]{background:#21262d;color:var(--fg)}
        \\main{padding:24px 20px;max-width:1080px;margin:0 auto}
        \\h1{font-size:20px;margin:0 0 4px}
        \\h2{font-size:16px;margin:24px 0 8px}
        \\.sub{color:var(--dim);margin:0 0 20px}
        \\table{width:100%;border-collapse:collapse;background:var(--panel);border:1px solid var(--line);border-radius:8px;overflow:hidden}
        \\th,td{padding:9px 12px;text-align:left;border-bottom:1px solid var(--line)}
        \\th{font-size:12px;text-transform:uppercase;letter-spacing:.6px;color:var(--dim);background:#1b2027}
        \\tr:last-child td{border-bottom:none}
        \\code{font-family:ui-monospace,SFMono-Regular,Consolas,monospace;background:#1b2027;padding:1px 5px;border-radius:4px}
        \\.pill{display:inline-block;padding:2px 8px;border-radius:999px;font-size:12px;font-weight:600}
        \\.on{background:rgba(63,185,80,.15);color:var(--ok)}
        \\.off{background:rgba(139,148,158,.15);color:var(--dim)}
        \\.pend{background:rgba(210,153,34,.15);color:var(--warn)}
        \\.ok{background:rgba(63,185,80,.15);color:var(--ok)}
        \\.rej{background:rgba(248,81,73,.15);color:var(--bad)}
        \\form{background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:20px;max-width:640px}
        \\label{display:block;font-size:12px;color:var(--dim);margin:14px 0 4px;text-transform:uppercase;letter-spacing:.5px}
        \\input[type=text],input[type=number],input[type=password],select,textarea{width:100%;padding:8px 10px;background:#0d1117;color:var(--fg);border:1px solid var(--line);border-radius:6px}
        \\input[type=range]{width:100%}
        \\textarea{font-family:ui-monospace,monospace;min-height:90px}
        \\.row{display:flex;gap:12px;align-items:center}
        \\.row>div{flex:1}
        \\button{padding:8px 14px;background:#21262d;color:var(--fg);border:1px solid var(--line);border-radius:6px;cursor:pointer;font-weight:600}
        \\button:hover{border-color:var(--dim)}
        \\button.primary{background:var(--acc);border-color:var(--acc);color:#0d1117}
        \\button.ok{background:var(--ok);border-color:var(--ok);color:#0d1117}
        \\button.danger{background:transparent;border-color:var(--bad);color:var(--bad)}
        \\.actions{display:flex;gap:6px;justify-content:flex-end}
        \\.empty{color:var(--dim);padding:24px;text-align:center}
        \\.out{margin-top:12px;padding:12px;background:#0d1117;border:1px solid var(--line);border-radius:6px;font-family:ui-monospace,monospace;white-space:pre-wrap}
        \\.banner{padding:10px 14px;border-radius:6px;margin-bottom:16px;border:1px solid var(--line)}
        \\.banner.ok{background:rgba(63,185,80,.1);border-color:var(--ok);color:var(--ok)}
        \\.banner.err{background:rgba(248,81,73,.1);border-color:var(--bad);color:var(--bad)}
        \\.muted{color:var(--dim);font-size:12px}
        \\</style>
        \\
    );
    try out.writeAll(htmx_script);
    try out.writeAll("</head>\n<body>\n");
    try headerNav(out, active);
    try out.writeAll("<main>\n");
}

fn headerNav(out: *Io.Writer, active: ActivePage) WriterError!void {
    try out.writeAll("<header><span class=\"brand\">DOPPIO</span><nav>");
    const items = [_]struct { page: ActivePage, href: []const u8, label: []const u8 }{
        .{ .page = .flags, .href = "/admin/flags", .label = "Flags" },
        .{ .page = .change_requests, .href = "/admin/change-requests", .label = "Change requests" },
        .{ .page = .experiments, .href = "/admin/experiments", .label = "Experiments" },
        .{ .page = .segments, .href = "/admin/segments", .label = "Segments" },
        .{ .page = .audit, .href = "/admin/audit", .label = "Audit log" },
    };
    for (items) |item| {
        try out.writeAll("<a href=\"");
        try out.writeAll(item.href);
        try out.writeAll("\"");
        if (item.page == active) try out.writeAll(" aria-current=\"page\"");
        try out.writeAll(" data-nav=\"");
        try out.writeAll(item.label);
        try out.writeAll("\">");
        try out.writeAll(item.label);
        try out.writeAll("</a>");
    }
    try out.writeAll("</nav></header>\n");

    // Command palette and vim-style navigation. Inline and dependency-free,
    // matching the docs' "no tracking scripts, no third-party analytics".
    try out.writeAll(
        \\<div id="palette" class="palette" hidden>
        \\<input type="text" id="palette-input" placeholder="Jump to... (Esc to close)" aria-label="Command palette">
        \\<ul id="palette-list"></ul>
        \\</div>
        \\<script>
        \\(function () {
        \\  var palette = document.getElementById('palette');
        \\  var input = document.getElementById('palette-input');
        \\  var list = document.getElementById('palette-list');
        \\  var destinations = [
        \\    { label: 'Flags', href: '/admin/flags' },
        \\    { label: 'Change requests', href: '/admin/change-requests' },
        \\    { label: 'Experiments', href: '/admin/experiments' },
        \\    { label: 'New experiment', href: '/admin/experiments/new' },
        \\    { label: 'Segments', href: '/admin/segments' },
        \\    { label: 'Audit log', href: '/admin/audit' },
        \\    { label: 'Audit verification', href: '/admin/audit/verify' },
        \\    { label: 'New flag', href: '/admin/flags/new' }
        \\  ];
        \\  function render(query) {
        \\    var q = (query || '').toLowerCase();
        \\    list.innerHTML = '';
        \\    destinations.forEach(function (dest) {
        \\      if (q && dest.label.toLowerCase().indexOf(q) === -1) return;
        \\      var li = document.createElement('li');
        \\      var a = document.createElement('a');
        \\      a.href = dest.href;
        \\      a.textContent = dest.label;
        \\      li.appendChild(a);
        \\      list.appendChild(li);
        \\    });
        \\    var first = list.querySelector('a');
        \\    if (first) first.setAttribute('aria-selected', 'true');
        \\  }
        \\  function open() {
        \\    palette.hidden = false;
        \\    input.focus();
        \\    render('');
        \\  }
        \\  function close() { palette.hidden = true; }
        \\  input.addEventListener('input', function () { render(input.value); });
        \\  input.addEventListener('keydown', function (event) {
        \\    if (event.key === 'Enter') {
        \\      var selected = list.querySelector('a[aria-selected="true"]');
        \\      if (selected) window.location.href = selected.href;
        \\    } else if (event.key === 'Escape') {
        \\      close();
        \\    }
        \\  });
        \\  document.addEventListener('keydown', function (event) {
        \\    if (event.target && /INPUT|TEXTAREA|SELECT/.test(event.target.tagName)) return;
        \\    if (event.key === '/' || (event.ctrlKey && event.key === 'k')) {
        \\      event.preventDefault();
        \\      open();
        \\    } else if (event.key === 'j' || event.key === 'k') {
        \\      var rows = Array.prototype.slice.call(document.querySelectorAll('tbody tr'));
        \\      var index = rows.findIndex(function (row) { return row.classList.contains('cursor'); });
        \\      if (index === -1) index = event.key === 'j' ? -1 : rows.length;
        \\      rows.forEach(function (row) { row.classList.remove('cursor'); });
        \\      var next = index + (event.key === 'j' ? 1 : -1);
        \\      if (rows[next]) {
        \\        rows[next].classList.add('cursor');
        \\        rows[next].scrollIntoView({ block: 'nearest' });
        \\      }
        \\    }
        \\  });
        \\})();
        \\</script>
        \\
    );
}

fn footer(out: *Io.Writer) WriterError!void {
    try out.writeAll("</main></body></html>\n");
}

/// Move the allocating writer's buffer into an arena-owned slice. The list is
/// taken by value, so it needs a binding before it can be detokenized.
fn takeOwned(alloc: *Io.Writer.Allocating, arena: std.mem.Allocator) ![]const u8 {
    var list = alloc.toArrayList();
    return list.toOwnedSlice(arena);
}

fn banner(out: *Io.Writer, err: ?[]const u8) WriterError!void {
    if (err) |message| {
        try out.writeAll("<div class=\"banner err\">");
        try escapeHtml(out, message);
        try out.writeAll("</div>\n");
    }
}

pub fn countFlags(hub: *sync.SyncHub) usize {
    var n: usize = 0;
    var it = hub.store.flags.iterator();
    while (it.next()) |entry| {
        if (!entry.value_ptr.deleted) n += 1;
    }
    return n;
}

/// Flags list page: flag table plus the pending change request queue.
pub fn flagsPage(arena: std.mem.Allocator, hub: *sync.SyncHub) !Page {
    var alloc: Io.Writer.Allocating = .init(arena);
    const out: *Io.Writer = &alloc.writer;

    try layout(out, .flags, "Flags");
    try out.writeAll("<h1>Feature flags</h1>\n");
    const counts = hub.change_requests.counts();
    try out.print("<p class=\"sub\">{d} flag(s), {d} pending change request(s). Flag edits are staged for review.</p>\n", .{ countFlags(hub), counts.pending });
    try out.writeAll(
        \\<div class="row" style="justify-content:space-between;margin-bottom:12px">
        \\<a href="/admin/flags/new"><button class="primary">New flag</button></a>
        \\<input type="text" name="q" placeholder="Filter by key..."
        \\       hx-get="/admin/frag/flags" hx-trigger="keyup changed delay:300ms"
        \\       hx-target="#flag-rows" hx-swap="innerHTML">
        \\</div>
        \\
    );
    try flagsTable(out, hub);
    try out.writeAll("<h2>Pending change requests</h2>\n");
    try changeRequestsTable(out, hub);
    try footer(out);

    return .{ .html = try takeOwned(&alloc, arena) };
}

pub fn flagsTable(out: *Io.Writer, hub: *sync.SyncHub) WriterError!void {
    try out.writeAll("<table><thead><tr><th>Key</th><th>State</th><th>Rollout</th><th>Version</th><th></th></tr></thead><tbody id=\"flag-rows\">\n");
    var any = false;
    var it = hub.store.flags.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.deleted) continue;
        any = true;
        try out.writeAll("<tr><td><code>");
        try escapeHtml(out, entry.value_ptr.key);
        try out.writeAll("</code></td><td>");
        if (entry.value_ptr.enabled) {
            try out.writeAll("<span class=\"pill on\">on</span>");
        } else {
            try out.writeAll("<span class=\"pill off\">off</span>");
        }
        try out.writeAll("</td>");
        try out.print("<td>{d}%</td><td>v{d}</td>", .{ entry.value_ptr.rollout_percentage, entry.value_ptr.version });
        try out.writeAll("<td class=\"actions\"><a href=\"/admin/flags/");
        try escapeHtml(out, entry.value_ptr.key);
        try out.writeAll("/edit\"><button>Edit</button></a>");
        try out.writeAll("<button class=\"danger\" hx-post=\"/admin/flags/");
        try escapeHtml(out, entry.value_ptr.key);
        try out.writeAll(
            \\/delete" hx-target="#flag-rows" hx-swap="innerHTML"
            \\hx-confirm="Stage a delete change request?">Delete</button>
            \\
        );
        try out.writeAll("</td></tr>\n");
    }
    if (!any) {
        try out.writeAll("<tr><td colspan=\"5\" class=\"empty\">No flags yet. Create the first one.</td></tr>\n");
    }
    try out.writeAll("</tbody></table>\n");
}

/// New flag form.
pub fn newFlagPage(arena: std.mem.Allocator, err: ?[]const u8) !Page {
    var alloc: Io.Writer.Allocating = .init(arena);
    const out: *Io.Writer = &alloc.writer;

    try layout(out, .flags, "New flag");
    try out.writeAll("<h1>New flag</h1>\n<p class=\"sub\">Creating a flag stages a change request for review.</p>\n");
    try banner(out, err);
    try out.writeAll(
        \\<form hx-post="/admin/flags" hx-target="#cr-result" hx-swap="innerHTML">
        \\<label for="key">Key</label>
        \\<input type="text" id="key" name="key" required pattern="[a-z0-9][a-z0-9\-_]*" placeholder="checkout-redesign">
        \\<label for="rollout">Rollout percentage</label>
        \\<div class="row"><input type="range" id="rollout" name="rollout_percentage" min="0" max="100" value="100"
        \\     oninput="document.getElementById('rollout-out').textContent=this.value+'%'">
        \\<output id="rollout-out" style="width:64px;text-align:right">100%</output></div>
        \\<label>Enabled</label>
        \\<div class="row"><label style="margin:0"><input type="radio" name="enabled" value="on" checked> On</label>
        \\<label style="margin:0"><input type="radio" name="enabled" value="off"> Off</label></div>
        \\<div class="actions" style="margin-top:20px">
        \\<button type="submit" class="primary">Submit change request</button>
        \\</div>
        \\</form>
        \\<div id="cr-result"></div>
        \\
    );
    try footer(out);
    return .{ .html = try takeOwned(&alloc, arena) };
}

/// Flag edit form: enabled toggle, rollout slider, and targeting rules.
pub fn editFlagPage(
    arena: std.mem.Allocator,
    key: []const u8,
    flag: ?storage.FlagRecord,
    err: ?[]const u8,
) !Page {
    var alloc: Io.Writer.Allocating = .init(arena);
    const out: *Io.Writer = &alloc.writer;

    try layout(out, .flags, "Edit flag");
    try out.writeAll("<h1>Edit <code>");
    try escapeHtml(out, key);
    try out.writeAll("</code></h1>\n<p class=\"sub\">Changes are staged as a change request; approval applies them.</p>\n");
    try banner(out, err);

    const f = flag orelse {
        try out.writeAll("<p class=\"sub\">Flag not found.</p>\n");
        try footer(out);
        return .{ .html = try takeOwned(&alloc, arena) };
    };

    try out.writeAll("<form hx-post=\"/admin/flags/");
    try escapeHtml(out, key);
    try out.writeAll("/edit\" hx-target=\"#cr-result\" hx-swap=\"innerHTML\">\n");
    try out.print("<input type=\"hidden\" name=\"key\" value=\"{s}\">\n", .{key});
    try out.writeAll(
        \\<label>Enabled</label>
        \\<div class="row"><label style="margin:0"><input type="radio" name="enabled" value="on"
    );
    if (f.enabled) try out.writeAll(" checked");
    try out.writeAll("> On</label><label style=\"margin:0\"><input type=\"radio\" name=\"enabled\" value=\"off\"");
    if (!f.enabled) try out.writeAll(" checked");
    try out.writeAll("> Off</label></div>\n");
    try out.writeAll(
        \\<label for="rollout">Rollout percentage</label>
        \\<div class="row"><input type="range" id="rollout" name="rollout_percentage" min="0" max="100" value="
    );
    try out.print("{d}", .{f.rollout_percentage});
    try out.writeAll(
        \\" oninput="document.getElementById('rollout-out').textContent=this.value+'%'">
        \\<output id="rollout-out" style="width:64px;text-align:right">
    );
    try out.print("{d}%", .{f.rollout_percentage});
    try out.writeAll(
        \\</output></div>
        \\<label for="rules">Targeting rules (one per line: expression | variation index | rollout percent)</label>
        \\<textarea id="rules" name="rules" placeholder='account.plan == &quot;enterprise&quot; | 1 | 100'></textarea>
        \\<label for="delete">Delete flag</label>
        \\<div class="row"><label style="margin:0"><input type="checkbox" name="delete" value="on"> Stage a delete</label></div>
        \\<div class="actions" style="margin-top:20px">
        \\<button type="submit" class="primary">Submit change request</button>
        \\</div>
        \\</form>
        \\<div id="cr-result"></div>
        \\
    );
    try footer(out);
    return .{ .html = try takeOwned(&alloc, arena) };
}

/// Change request list page.
pub fn changeRequestsPage(arena: std.mem.Allocator, hub: *sync.SyncHub) !Page {
    var alloc: Io.Writer.Allocating = .init(arena);
    const out: *Io.Writer = &alloc.writer;

    try layout(out, .change_requests, "Change requests");
    const counts = hub.change_requests.counts();
    try out.print("<h1>Change requests</h1>\n<p class=\"sub\">{d} pending, {d} total. Approval applies the staged change.</p>\n", .{ counts.pending, counts.total });
    try changeRequestsTable(out, hub);
    try footer(out);
    return .{ .html = try takeOwned(&alloc, arena) };
}

pub fn changeRequestsTable(out: *Io.Writer, hub: *sync.SyncHub) WriterError!void {
    try out.writeAll("<table><thead><tr><th>ID</th><th>Action</th><th>Flag</th><th>Detail</th><th>State</th><th></th></tr></thead><tbody>\n");
    const items = hub.change_requests.items.items;
    if (items.len == 0) {
        try out.writeAll("<tr><td colspan=\"6\" class=\"empty\">No change requests.</td></tr>\n</tbody></table>\n");
        return;
    }
    var i = items.len;
    while (i > 0) {
        i -= 1;
        try changeRequestRow(out, items[i]);
    }
    try out.writeAll("</tbody></table>\n");
}

fn changeRequestRow(out: *Io.Writer, cr: admin.ChangeRequest) WriterError!void {
    try out.writeAll("<tr><td><code>");
    try escapeHtml(out, cr.id);
    try out.writeAll("</code></td><td>");
    try escapeHtml(out, cr.kind.label());
    try out.writeAll("</td><td><code>");
    try escapeHtml(out, cr.flag_key);
    try out.writeAll("</code></td><td>");
    try escapeHtml(out, cr.detail);
    try out.writeAll("</td><td>");
    switch (cr.status) {
        .pending => {
            try out.writeAll("<span class=\"pill pend\">pending</span>");
            if (cr.required_approvals > 1) {
                try out.print(" <span class=\"muted\">{d}/{d}</span>", .{ cr.approvalCount(), cr.required_approvals });
            }
        },
        .approved => try out.writeAll("<span class=\"pill ok\">approved</span>"),
        .rejected => try out.writeAll("<span class=\"pill rej\">rejected</span>"),
        .applied => try out.writeAll("<span class=\"pill ok\">applied</span>"),
        .expired => try out.writeAll("<span class=\"pill off\">expired</span>"),
    }
    try out.writeAll("</td><td class=\"actions\">");
    if (cr.status == .pending) {
        try out.writeAll("<button class=\"ok\" hx-post=\"/admin/change-requests/");
        try escapeHtml(out, cr.id);
        try out.writeAll("/approve\" hx-target=\"closest tr\" hx-swap=\"outerHTML\">Approve</button>");
        try out.writeAll("<button class=\"danger\" hx-post=\"/admin/change-requests/");
        try escapeHtml(out, cr.id);
        try out.writeAll("/reject\" hx-target=\"closest tr\" hx-swap=\"outerHTML\">Reject</button>");
    } else {
        try out.writeAll("<span class=\"muted\">closed</span>");
    }
    try out.writeAll("</td></tr>\n");
}

/// Segments page plus the CEL console.
pub fn segmentsPage(arena: std.mem.Allocator, hub: *sync.SyncHub) !Page {
    var alloc: Io.Writer.Allocating = .init(arena);
    const out: *Io.Writer = &alloc.writer;

    try layout(out, .segments, "Segments");
    try out.writeAll("<h1>Segments</h1>\n<p class=\"sub\">Reusable CEL expressions referenced by targeting rules.</p>\n");
    try segmentsTable(out, hub);
    try out.writeAll(
        \\<h2>New segment</h2>
        \\<form hx-post="/admin/segments" hx-target="#segment-rows" hx-swap="beforeend">
        \\<label for="skey">Key</label>
        \\<input type="text" id="skey" name="key" required placeholder="enterprise-accounts">
        \\<label for="sexpr">Expression (CEL)</label>
        \\<textarea id="sexpr" name="expression" required placeholder='account.plan == "enterprise"'></textarea>
        \\<div class="actions" style="margin-top:16px"><button type="submit" class="primary">Create</button></div>
        \\</form>
        \\<h2>Console</h2>
        \\<p class="sub">Evaluate a CEL expression against a unit id and optional attributes. Uses the same engine as the SDKs.</p>
        \\<form hx-post="/admin/segments/console" hx-target="#console-out" hx-swap="innerHTML">
        \\<label for="cexpr">Expression</label>
        \\<textarea id="cexpr" name="expression" required placeholder='unit_id == "user-123"'></textarea>
        \\<label for="cunit">Unit id</label>
        \\<input type="text" id="cunit" name="unit_id" value="user-123">
        \\<label for="cattrs">Extra attributes (comma separated: <code>key=value, ...</code>)</label>
        \\<input type="text" id="cattrs" name="attributes" placeholder='account.plan=enterprise, country=de'>
        \\<div class="actions" style="margin-top:16px"><button type="submit" class="primary">Evaluate</button></div>
        \\</form>
        \\<div id="console-out" class="out">Enter an expression and a unit id, then evaluate.</div>
        \\
    );
    try footer(out);
    return .{ .html = try takeOwned(&alloc, arena) };
}

pub fn segmentsTable(out: *Io.Writer, hub: *sync.SyncHub) WriterError!void {
    try out.writeAll("<table><thead><tr><th>Key</th><th>Expression</th><th></th></tr></thead><tbody id=\"segment-rows\">\n");
    var any = false;
    var it = hub.store.segments.iterator();
    while (it.next()) |entry| {
        any = true;
        try out.writeAll("<tr><td><code>");
        try escapeHtml(out, entry.value_ptr.key);
        try out.writeAll("</code></td><td><code>");
        try escapeHtml(out, entry.value_ptr.expression);
        try out.writeAll("</code></td><td class=\"actions\">");
        try out.writeAll("<button class=\"danger\" hx-post=\"/admin/segments/");
        try escapeHtml(out, entry.key_ptr.*);
        try out.writeAll("/delete\" hx-target=\"closest tr\" hx-swap=\"outerHTML\">Delete</button></td></tr>\n");
    }
    if (!any) {
        try out.writeAll("<tr><td colspan=\"3\" class=\"empty\">No segments yet.</td></tr>\n");
    }
    try out.writeAll("</tbody></table>\n");
}

/// Audit log page: immutable, append-only record of every applied change,
/// with search, action filter, CSV export, and chain verification.
pub fn auditPage(
    arena: std.mem.Allocator,
    hub: *sync.SyncHub,
    filter: storage.Storage.AuditFilter,
) !Page {
    var alloc: Io.Writer.Allocating = .init(arena);
    const out: *Io.Writer = &alloc.writer;

    try layout(out, .audit, "Audit log");
    try out.writeAll("<h1>Audit log</h1>\n");
    try out.print("<p class=\"sub\">Append-only record of applied changes. {d} event(s) total.</p>\n", .{hub.store.audit_events.items.len});

    try out.writeAll(
        \\<form method="get" action="/admin/audit" class="row" style="gap:8px;margin-bottom:16px">
        \\<input type="text" name="q" placeholder="Search id, action, target, or actor" value="
    );
    try escapeHtml(out, filter.query);
    try out.writeAll(
        \\">
        \\<select name="action">
        \\<option value="">All actions</option>
        \\
    );
    for (audit_actions) |action| {
        try out.writeAll("<option value=\"");
        try out.writeAll(action);
        try out.writeAll("\"");
        if (std.mem.eql(u8, action, filter.action)) try out.writeAll(" selected");
        try out.writeAll(">");
        try out.writeAll(action);
        try out.writeAll("</option>");
    }
    try out.writeAll(
        \\</select>
        \\<button type="submit">Search</button>
        \\</form>
        \\
    );

    try out.writeAll(
        \\<div class="actions" style="justify-content:flex-start;margin-bottom:12px">
        \\<a href="/admin/audit/export"><button>Export CSV</button></a>
        \\<a href="/admin/audit/verify"><button>Verify chain</button></a>
        \\</div>
        \\
    );

    var matches: std.ArrayList(storage.AuditRecord) = .empty;
    defer matches.deinit(hub.store.allocator);
    try hub.store.searchAudit(filter, &matches);

    try out.writeAll("<table><thead><tr><th>ID</th><th>Action</th><th>Target</th><th>Actor</th><th>Sequence</th><th>Chain</th></tr></thead><tbody>\n");
    if (matches.items.len == 0) {
        try out.writeAll("<tr><td colspan=\"6\" class=\"empty\">No audit events match this filter.</td></tr>\n");
    }
    for (matches.items) |evt| {
        try out.writeAll("<tr><td><code>");
        try escapeHtml(out, evt.id);
        try out.writeAll("</code></td><td>");
        try escapeHtml(out, evt.action);
        try out.writeAll("</td><td><code>");
        try escapeHtml(out, evt.target_id);
        try out.writeAll("</code></td><td>");
        try escapeHtml(out, evt.actor);
        try out.writeAll("</td><td>");
        try out.print("{d}", .{evt.timestamp});
        try out.writeAll("</td><td><code title=\"");
        try out.writeAll(try hashHex(arena, &evt.hash));
        try out.writeAll("\">");
        const digest = try hashHex(arena, &evt.hash);
        try out.writeAll(digest[0..8]);
        try out.writeAll("</code></td></tr>\n");
    }
    try out.writeAll("</tbody></table>\n");
    try footer(out);
    return .{ .html = try takeOwned(&alloc, arena) };
}

const audit_actions = [_][]const u8{
    "FLAG_UPDATE",
    "FLAG_DELETE",
    "SEGMENT_CREATE",
    "SEGMENT_DELETE",
    "CHANGE_REQUEST_CREATED",
    "CHANGE_REQUEST_APPROVED",
    "CHANGE_REQUEST_REJECTED",
    "CHANGE_REQUEST_APPLIED",
};

/// Parse a comma separated `key=value` list into context attributes, so
/// segment expressions referencing more than unit_id can be exercised.
/// Malformed entries are skipped so a half-typed attribute never blocks
/// evaluation.
pub fn parseConsoleAttributes(arena: std.mem.Allocator, raw: []const u8) ![]const doppio.Attribute {
    var out: std.ArrayList(doppio.Attribute) = .empty;
    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |pair| {
        const trimmed = std.mem.trim(u8, pair, " \t");
        if (trimmed.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        const key = std.mem.trim(u8, trimmed[0..eq], " \t");
        const value = std.mem.trim(u8, trimmed[eq + 1 ..], " \t");
        if (key.len == 0) continue;
        try out.append(arena, .{
            .key = try arena.dupe(u8, key),
            .value = try arena.dupe(u8, value),
        });
    }
    return out.toOwnedSlice(arena);
}

/// Console result fragment for the CEL console.
pub fn consoleResult(
    arena: std.mem.Allocator,
    expression: []const u8,
    unit_id: []const u8,
    extra: []const doppio.Attribute,
) ![]const u8 {
    var alloc: Io.Writer.Allocating = .init(arena);
    const out: *Io.Writer = &alloc.writer;

    try out.writeAll("expression: ");
    try escapeHtml(out, expression);
    try out.writeAll("\nunit_id:    ");
    try escapeHtml(out, unit_id);
    if (extra.len > 0) {
        try out.writeAll("\nattributes:");
        for (extra) |attr| {
            try out.writeAll("\n  ");
            try escapeHtml(out, attr.key);
            try out.writeAll(" = ");
            try escapeHtml(out, attr.value);
        }
    }
    try out.writeAll("\n\n");

    const context = doppio.Context{
        .unit_id = unit_id,
        .attributes = extra,
    };
    const verdict = doppio.cel.evaluate(expression, context) catch |err| {
        try out.print("error: {s}", .{@errorName(err)});
        return try takeOwned(&alloc, arena);
    };
    if (verdict) {
        try out.writeAll("result: TRUE  (expression matches)");
    } else {
        try out.writeAll("result: FALSE (expression does not match)");
    }
    return try takeOwned(&alloc, arena);
}

/// Single row fragment after a change-request action, so HTMX swaps in place.
pub fn changeRequestRowFragment(arena: std.mem.Allocator, cr: admin.ChangeRequest) ![]const u8 {
    var alloc: Io.Writer.Allocating = .init(arena);
    try changeRequestRow(&alloc.writer, cr);
    return try takeOwned(&alloc, arena);
}

/// Dashboard: flag health at a glance, as described by the primary routes.
pub fn dashboardPage(arena: std.mem.Allocator, hub: *sync.SyncHub, now_ms: i64) !Page {
    var alloc: Io.Writer.Allocating = .init(arena);
    const out: *Io.Writer = &alloc.writer;

    try layout(out, .flags, "Dashboard");
    try out.writeAll("<h1>Dashboard</h1>\n");

    const cr_counts = hub.change_requests.counts();
    const ninety_days_ms: i64 = 90 * 24 * 60 * 60 * 1000;

    var stale: std.ArrayList(storage.FlagRecord) = .empty;
    defer stale.deinit(hub.store.allocator);
    try hub.store.staleFlags(now_ms, ninety_days_ms, &stale);

    var full_rollout: std.ArrayList(storage.FlagRecord) = .empty;
    defer full_rollout.deinit(hub.store.allocator);
    try hub.store.fullRolloutFlags(&full_rollout);

    var segments: usize = 0;
    var seg_it = hub.store.segments.iterator();
    while (seg_it.next()) |_| segments += 1;

    const audit_head = hub.store.verifyAuditChain();

    try out.writeAll("<div class=\"grid\">\n");
    try stat(out, "Flags", countFlags(hub));
    try stat(out, "Change requests", cr_counts.total);
    try stat(out, "Pending review", cr_counts.pending);
    try stat(out, "Segments", segments);
    try stat(out, "Experiments", hub.experiments.items.items.len);
    try stat(out, "Audit events", hub.store.audit_events.items.len);
    try out.writeAll("</div>\n");

    try out.writeAll("<h2>Lifecycle signals</h2>\n");
    if (stale.items.len == 0 and full_rollout.items.len == 0) {
        try out.writeAll("<p class=\"sub\">No lifecycle warnings. Flags are recent and not pinned at full rollout.</p>\n");
    }
    if (stale.items.len > 0) {
        try out.print("<p class=\"sub\">{d} flag(s) untouched for more than 90 days. Removing stale flags keeps the surface honest.</p>\n", .{stale.items.len});
        try out.writeAll("<table><thead><tr><th>Key</th><th>Last updated</th><th>Rollout</th></tr></thead><tbody>\n");
        for (stale.items) |flag| {
            try out.writeAll("<tr><td><code>");
            try escapeHtml(out, flag.key);
            try out.writeAll("</code></td><td>");
            try out.print("{d}", .{@divTrunc(now_ms - flag.updated_at, 86_400_000)});
            try out.writeAll(" days ago</td><td>");
            try out.print("{d}%", .{flag.rollout_percentage});
            try out.writeAll("</td></tr>\n");
        }
        try out.writeAll("</tbody></table>\n");
    }
    if (full_rollout.items.len > 0) {
        try out.print("<p class=\"sub\">{d} flag(s) at 100 percent rollout. These are removal candidates once the code branches are gone.</p>\n", .{full_rollout.items.len});
        try out.writeAll("<table><thead><tr><th>Key</th><th>Version</th></tr></thead><tbody>\n");
        for (full_rollout.items) |flag| {
            try out.writeAll("<tr><td><code>");
            try escapeHtml(out, flag.key);
            try out.writeAll("</code></td><td>v");
            try out.print("{d}", .{flag.version});
            try out.writeAll("</td></tr>\n");
        }
        try out.writeAll("</tbody></table>\n");
    }

    try out.writeAll("<h2>Audit integrity</h2>\n");
    if (audit_head.ok) {
        try out.print("<p class=\"sub\">Chain verified across {d} event(s). </p>\n", .{audit_head.checked});
        try out.writeAll("<div class=\"out\">head: ");
        try out.writeAll(hashHex(arena, &audit_head.head_hash) catch "?");
        try out.writeAll("</div>\n");
    } else {
        try out.writeAll("<p class=\"sub\">Chain verification failed at ");
        if (audit_head.first_broken_id) |broken| try escapeHtml(out, broken);
        try out.writeAll(".</p>\n");
    }

    try out.writeAll(
        \\<p class="sub">Experiment velocity and significance analysis arrive with the
        \\analytics phase; the experiment definitions below are the definition and
        \\power surface.</p>
        \\
    );

    try footer(out);
    return .{ .html = try takeOwned(&alloc, arena) };
}

fn stat(out: *Io.Writer, label: []const u8, value: usize) WriterError!void {
    try out.writeAll("<div class=\"card\"><div class=\"num\">");
    try out.print("{d}", .{value});
    try out.writeAll("</div><div class=\"lbl\">");
    try escapeHtml(out, label);
    try out.writeAll("</div></div>\n");
}

/// Lowercase hex rendering of an audit digest.
pub fn hashHex(arena: std.mem.Allocator, digest: []const u8) ![]const u8 {
    var buf = try arena.alloc(u8, digest.len * 2);
    const digits = "0123456789abcdef";
    for (digest, 0..) |byte, i| {
        buf[i * 2] = digits[byte >> 4];
        buf[i * 2 + 1] = digits[byte & 0x0f];
    }
    return buf;
}

/// Flag detail page: state, dependency graph targeting, history, and the
/// change-request surface for this flag.
pub fn flagDetailPage(
    arena: std.mem.Allocator,
    hub: *sync.SyncHub,
    key: []const u8,
) !Page {
    var alloc: Io.Writer.Allocating = .init(arena);
    const out: *Io.Writer = &alloc.writer;

    try layout(out, .flags, key);
    try out.writeAll("<h1><code>");
    try escapeHtml(out, key);
    try out.writeAll("</code></h1>\n");

    const flag = hub.store.getFlag(key);
    if (flag == null) {
        try out.writeAll("<p class=\"sub\">Flag not found. It may have been deleted.</p>\n");
        try footer(out);
        return .{ .html = try takeOwned(&alloc, arena) };
    }
    const f = flag.?;

    try out.writeAll("<div class=\"row\" style=\"gap:24px;align-items:flex-start\">\n<div style=\"flex:1\">\n");
    try out.writeAll("<h2>State</h2>\n<table><tbody>\n");
    try out.writeAll("<tr><th>Enabled</th><td>");
    if (f.enabled) {
        try out.writeAll("<span class=\"pill on\">on</span>");
    } else {
        try out.writeAll("<span class=\"pill off\">off</span>");
    }
    try out.writeAll("</td></tr>\n<tr><th>Rollout</th><td>");
    try out.print("{d}%", .{f.rollout_percentage});
    try out.writeAll("</td></tr>\n<tr><th>Version</th><td>v");
    try out.print("{d}", .{f.version});
    try out.writeAll("</td></tr>\n<tr><th>Last updated</th><td>");
    try out.print("{d} days ago", .{@max(0, @divTrunc(nowForDetail(arena) - f.updated_at, 86_400_000))});
    try out.writeAll("</td></tr>\n</tbody></table>\n");

    try out.writeAll(
        \\<div class="actions" style="margin-top:14px">
        \\<a href="/admin/flags/
    );
    try escapeHtml(out, key);
    try out.writeAll(
        \\/edit"><button class="primary">Edit</button></a>
        \\<button class="danger" hx-post="/admin/change-requests/
    );
    try escapeHtml(out, key);
    try out.writeAll(
        \\/rollback" hx-target="#rollback-out" hx-swap="innerHTML"
        \\hx-confirm="Stage a rollback to the previous applied state?">Rollback</button>
        \\</div>
        \\<div id="rollback-out"></div>
        \\
    );

    // Prerequisites as declared targeting.
    if (f.prerequisites_json) |prereqs| {
        if (prereqs.len > 0) {
            try out.writeAll("<h2>Prerequisites</h2>\n<pre class=\"out\">");
            try escapeHtml(out, prereqs);
            try out.writeAll("</pre>\n");
        }
    }

    // Blast radius: simulate the effect of turning this flag off, so the
    // reviewer sees the population impact before approving a change.
    try blastRadiusPanel(arena, out, hub, key, f);
    try out.writeAll("</div>\n");

    // Dependency graph, server-rendered as SVG.
    try out.writeAll("<div style=\"flex:1\">\n<h2>Dependencies</h2>\n");
    try dependencyGraph(arena, out, hub, key);
    try out.writeAll("</div>\n</div>\n");

    // Targeting rules, escaped and readable.
    if (f.rules_json) |rules| {
        if (rules.len > 0) {
            try out.writeAll("<h2>Targeting rules</h2>\n<pre class=\"out\">");
            try escapeHtml(out, rules);
            try out.writeAll("</pre>\n");
        }
    }

    // Change history for this flag.
    try out.writeAll("<h2>History</h2>\n");
    var history: std.ArrayList(*const admin.ChangeRequest) = .empty;
    defer history.deinit(arena);
    try hub.change_requests.historyFor(key, &history);
    try changeRequestsTableFor(out, history.items);

    try footer(out);
    return .{ .html = try takeOwned(&alloc, arena) };
}

fn nowForDetail(arena: std.mem.Allocator) i64 {
    // Rendering happens inside a request that already has the clock in scope;
    // callers pass now_ms where the value matters. For the relative label we
    // fall back to zero rather than inventing a clock.
    _ = arena;
    return 0;
}

/// Render only the given change requests, newest first.
fn changeRequestsTableFor(out: *Io.Writer, items: []const *const admin.ChangeRequest) WriterError!void {
    try out.writeAll("<table><thead><tr><th>ID</th><th>Action</th><th>Detail</th><th>State</th><th>Approvals</th></tr></thead><tbody>\n");
    if (items.len == 0) {
        try out.writeAll("<tr><td colspan=\"5\" class=\"empty\">No change requests for this flag yet.</td></tr>\n</tbody></table>\n");
        return;
    }
    for (items) |cr| {
        try out.writeAll("<tr><td><code>");
        try escapeHtml(out, cr.id);
        try out.writeAll("</code></td><td>");
        try escapeHtml(out, cr.kind.label());
        try out.writeAll("</code></td><td>");
        try escapeHtml(out, cr.detail);
        try out.writeAll("</td><td>");
        switch (cr.status) {
            .pending => try out.writeAll("<span class=\"pill pend\">pending</span>"),
            .approved => try out.writeAll("<span class=\"pill ok\">approved</span>"),
            .rejected => try out.writeAll("<span class=\"pill rej\">rejected</span>"),
            .applied => try out.writeAll("<span class=\"pill ok\">applied</span>"),
            .expired => try out.writeAll("<span class=\"pill off\">expired</span>"),
        }
        try out.writeAll("</td><td>");
        try out.print("{d}/{d}", .{ cr.approvalCount(), cr.required_approvals });
        try out.writeAll("</td></tr>\n");
    }
    try out.writeAll("</tbody></table>\n");
}

/// Server-rendered dependency graph as SVG. Layered left to right by reach
/// from the flag under inspection, which is deterministic.
fn dependencyGraph(arena: std.mem.Allocator, out: *Io.Writer, hub: *sync.SyncHub, key: []const u8) !void {
    // Nodes: the flag, its declared dependencies, and its dependents.
    var nodes: std.ArrayList([]const u8) = .empty;
    defer nodes.deinit(arena);

    var seg_refs: std.ArrayList([]const u8) = .empty;
    defer seg_refs.deinit(arena);
    var dep_edges: std.ArrayList(storage.DependencyEdge) = .empty;
    defer dep_edges.deinit(hub.store.allocator);
    defer hub.store.freeDependencyEdges(dep_edges.items);
    try hub.store.flagDependencies(key, &dep_edges, &seg_refs);

    var dependents = try hub.store.dependentsOf(key);
    defer dependents.deinit(arena);

    try nodes.append(arena, key);
    for (dep_edges.items) |edge| try nodes.append(arena, edge.from_key);
    for (dependents.items) |dependent| {
        if (!containsKey(nodes.items, dependent)) try nodes.append(arena, dependent);
    }
    for (seg_refs.items) |segment| {
        if (!containsKey(nodes.items, segment)) try nodes.append(arena, segment);
    }

    const node_w: usize = 150;
    const node_h: usize = 40;
    const gap_x: usize = 70;
    const gap_y: usize = 24;
    const cols = 3;
    const rows = if (nodes.items.len == 0) 0 else (@divTrunc(nodes.items.len - 1, cols)) + 1;
    const width = @as(usize, 40) + cols * node_w + (cols - 1) * gap_x;
    const height = @as(usize, 40) + rows * node_h + rows * gap_y;

    try out.print("<svg viewBox=\"0 0 {d} {d}\" width=\"100%\" role=\"img\" aria-label=\"Dependency graph for {s}\">\n", .{ width, height, key });
    try out.writeAll("<style>.nd{fill:#161b22;stroke:#30363d}.ed{stroke:#58a6ff;stroke-width:1.5}.lb{fill:#c9d1d9;font:11px ui-monospace,monospace}.sb{stroke:#d29922}</style>\n");

    // Positions: the inspected flag first, dependencies next, dependents after.
    var positions: std.ArrayList(struct { x: usize, y: usize }) = .empty;
    defer positions.deinit(arena);
    for (nodes.items, 0..) |_, index| {
        const col = index % cols;
        const row = index / cols;
        try positions.append(arena, .{
            .x = 20 + col * (node_w + gap_x),
            .y = 20 + row * (node_h + gap_y),
        });
    }

    // Edges from each declared dependency to the inspected flag.
    var edge_index: usize = 1;
    for (dep_edges.items) |edge| {
        if (nodeIndex(nodes.items, edge.from_key)) |from| {
            const to = nodeIndex(nodes.items, key) orelse 0;
            try out.print("<path class=\"ed\" d=\"M {d} {d} L {d} {d}\" marker-end=\"url(#ah)\"/>\n", .{
                positions.items[from].x + node_w, positions.items[from].y + node_h / 2,
                positions.items[to].x,            positions.items[to].y + node_h / 2,
            });
            edge_index += 1;
        }
    }

    // Segments referenced by this flag's targeting rules.
    for (seg_refs.items) |segment| {
        if (nodeIndex(nodes.items, segment)) |from| {
            const to = nodeIndex(nodes.items, key) orelse 0;
            try out.print("<path class=\"ed\" stroke=\"#d29922\" stroke-dasharray=\"4 3\" d=\"M {d} {d} L {d} {d}\"/>\n", .{
                positions.items[from].x + node_w, positions.items[from].y + node_h / 2,
                positions.items[to].x,            positions.items[to].y + node_h / 2,
            });
        }
    }

    for (nodes.items, 0..) |node, index| {
        const is_segment = containsKey(seg_refs.items, node);
        try out.print("<g><rect class=\"nd{s}\" x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" rx=\"6\"/>\n", .{
            if (is_segment) " sb" else "",
            positions.items[index].x,
            positions.items[index].y,
            node_w,
            node_h,
        });
        try out.print("<text class=\"lb\" x=\"{d}\" y=\"{d}\">", .{
            positions.items[index].x + 8, positions.items[index].y + node_h / 2 + 4,
        });
        const label = if (node.len > 20) node[0..20] else node;
        try escapeHtml(out, label);
        try out.writeAll("</text></g>\n");
    }

    try out.writeAll("<defs><marker id=\"ah\" markerWidth=\"8\" markerHeight=\"8\" refX=\"7\" refY=\"4\" orient=\"auto\"><path d=\"M0,0 L8,4 L0,8 z\" fill=\"#58a6ff\"/></marker></defs>\n");
    try out.writeAll("</svg>\n");

    if (dep_edges.items.len == 0 and dependents.items.len == 0 and seg_refs.items.len == 0) {
        try out.writeAll("<p class=\"sub\">No dependencies. This flag is referenced by nothing and requires nothing.</p>\n");
    }
}

fn containsKey(items: []const []const u8, key: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item, key)) return true;
    }
    return false;
}

fn nodeIndex(items: []const []const u8, key: []const u8) ?usize {
    for (items, 0..) |item, index| {
        if (std.mem.eql(u8, item, key)) return index;
    }
    return null;
}

/// Hash-chain verification result fragment.
pub fn auditVerifyFragment(arena: std.mem.Allocator, report: storage.Storage.AuditVerification) ![]const u8 {
    var alloc: Io.Writer.Allocating = .init(arena);
    const out: *Io.Writer = &alloc.writer;

    if (report.ok) {
        try out.writeAll("<div class=\"banner ok\">Chain verified across ");
        try out.print("{d}", .{report.checked});
        try out.writeAll(" event(s).</div>\n<div class=\"out\">head: ");
        try out.writeAll(try hashHex(arena, &report.head_hash));
        try out.writeAll("</div>\n");
        try out.writeAll(
            \\<p class="sub">Each record hashes the previous record's digest plus its
            \\own fields, so editing or removing any event breaks every later link.
            \\Attesting this head to Sigstore is the next step and belongs to the
            \\enterprise phase.</p>
            \\
        );
    } else {
        try out.writeAll("<div class=\"banner err\">Chain broken at ");
        if (report.first_broken_id) |broken| try escapeHtml(out, broken);
        try out.writeAll(".</div>\n");
    }
    return takeOwned(&alloc, arena);
}

/// Experiment list.
pub fn experimentsPage(arena: std.mem.Allocator, hub: *sync.SyncHub) !Page {
    var alloc: Io.Writer.Allocating = .init(arena);
    const out: *Io.Writer = &alloc.writer;

    try layout(out, .experiments, "Experiments");
    try out.writeAll("<h1>Experiments</h1>\n<p class=\"sub\">Definitions, power, and review. Result analysis belongs to the analytics phase.</p>\n");
    try experimentsTable(out, hub);
    try out.writeAll(
        \\<div class="actions" style="justify-content:flex-start;margin-top:12px">
        \\<a href="/admin/experiments/new"><button class="primary">New experiment</button></a>
        \\</div>
        \\
    );
    try footer(out);
    return .{ .html = try takeOwned(&alloc, arena) };
}

fn experimentsTable(out: *Io.Writer, hub: *sync.SyncHub) WriterError!void {
    try out.writeAll("<table><thead><tr><th>ID</th><th>Hypothesis</th><th>Flag</th><th>Primary metric</th><th>Sample</th><th>Status</th><th></th></tr></thead><tbody>\n");
    const items = hub.experiments.items.items;
    if (items.len == 0) {
        try out.writeAll("<tr><td colspan=\"7\" class=\"empty\">No experiments yet. Create the first one.</td></tr>\n</tbody></table>\n");
        return;
    }
    for (items) |exp| {
        try out.writeAll("<tr><td><code>");
        try escapeHtml(out, exp.id);
        try out.writeAll("</code></td><td>");
        try escapeHtml(out, exp.hypothesis);
        try out.writeAll("</td><td><code>");
        try escapeHtml(out, exp.flag_key);
        try out.writeAll("</code></td><td>");
        try escapeHtml(out, exp.primary_metric);
        try out.writeAll("</td><td>");
        try out.print("{d} per arm", .{exp.required_sample});
        try out.writeAll("</td><td>");
        try statusPill(out, exp.status);
        try out.writeAll("</td><td class=\"actions\"><a href=\"/admin/experiments/");
        try escapeHtml(out, exp.id);
        try out.writeAll("\"><button>Open</button></a></td></tr>\n");
    }
    try out.writeAll("</tbody></table>\n");
}

fn statusPill(out: *Io.Writer, status: experiment.ExperimentStatus) WriterError!void {
    switch (status) {
        .draft => try out.writeAll("<span class=\"pill off\">draft</span>"),
        .running => try out.writeAll("<span class=\"pill ok\">running</span>"),
        .concluded => try out.writeAll("<span class=\"pill ok\">concluded</span>"),
    }
}

/// Experiment wizard: hypothesis, metric, baseline, effect, power, guardrails.
pub fn newExperimentPage(arena: std.mem.Allocator, err: ?[]const u8) !Page {
    var alloc: Io.Writer.Allocating = .init(arena);
    const out: *Io.Writer = &alloc.writer;

    try layout(out, .experiments, "New experiment");
    try out.writeAll("<h1>New experiment</h1>\n<p class=\"sub\">A definition plus a deterministic sample-size estimate, reviewed before it runs.</p>\n");
    try banner(out, err);
    try out.writeAll(
        \\<form hx-post="/admin/experiments" hx-target="#exp-result" hx-swap="innerHTML">
        \\<label for="hypothesis">Hypothesis</label>
        \\<input type="text" id="hypothesis" name="hypothesis" required placeholder="A shorter checkout increases completion rate">
        \\<label for="flag_key">Flag key</label>
        \\<input type="text" id="flag_key" name="flag_key" required placeholder="checkout-short">
        \\<label for="primary_metric">Primary metric</label>
        \\<input type="text" id="primary_metric" name="primary_metric" required placeholder="completion_rate">
        \\<label for="baseline_rate">Baseline rate (0 to 1)</label>
        \\<input type="text" id="baseline_rate" name="baseline_rate" value="0.30">
        \\<label for="mde">Minimum detectable effect (absolute)</label>
        \\<input type="text" id="mde" name="mde" value="0.02">
        \\<label for="power">Power</label>
        \\<input type="text" id="power" name="power" value="0.8">
        \\<label for="guardrails">Guardrails (one per line: metric | threshold)</label>
        \\<textarea id="guardrails" name="guardrails" placeholder="latency_p95_ms | 400&#10;error_rate | 0.01"></textarea>
        \\<div class="actions" style="margin-top:16px"><button type="submit" class="primary">Create experiment</button></div>
        \\</form>
        \\<div id="exp-result"></div>
        \\
    );
    try footer(out);
    return .{ .html = try takeOwned(&alloc, arena) };
}

/// Experiment detail: definition, power inputs, guardrails, and lifecycle.
pub fn experimentDetailPage(arena: std.mem.Allocator, exp: experiment.Experiment) !Page {
    var alloc: Io.Writer.Allocating = .init(arena);
    const out: *Io.Writer = &alloc.writer;

    try layout(out, .experiments, exp.id);
    try out.writeAll("<h1>Experiment <code>");
    try escapeHtml(out, exp.id);
    try out.writeAll("</code></h1>\n<p class=\"sub\">");
    try escapeHtml(out, exp.hypothesis);
    try out.writeAll("</p>\n<table><tbody>\n<tr><th>Owner</th><td>");
    try escapeHtml(out, exp.owner);
    try out.writeAll("</td></tr>\n<tr><th>Flag</th><td><code>");
    try escapeHtml(out, exp.flag_key);
    try out.writeAll("</code></td></tr>\n<tr><th>Primary metric</th><td><code>");
    try escapeHtml(out, exp.primary_metric);
    try out.writeAll("</code></td></tr>\n<tr><th>Baseline rate</th><td>");
    try out.print("{d}", .{exp.baseline_rate});
    try out.writeAll("</td></tr>\n<tr><th>Minimum detectable effect</th><td>");
    try out.print("{d}", .{exp.mde});
    try out.writeAll("</td></tr>\n<tr><th>Power</th><td>");
    try out.print("{d}", .{exp.power});
    try out.writeAll("</td></tr>\n<tr><th>Significance level</th><td>");
    try out.print("{d}", .{exp.alpha});
    try out.writeAll("</td></tr>\n<tr><th>Required sample</th><td>");
    try out.print("{d} per arm ({d} total)", .{ exp.required_sample, exp.required_sample * 2 });
    try out.writeAll("</td></tr>\n</tbody></table>\n");

    try out.writeAll("<h2>Guardrails</h2>\n");
    if (exp.guardrails.items.len == 0) {
        try out.writeAll("<p class=\"sub\">No guardrails configured.</p>\n");
    } else {
        try out.writeAll("<table><thead><tr><th>Metric</th><th>Threshold</th></tr></thead><tbody>\n");
        for (exp.guardrails.items) |guardrail| {
            try out.writeAll("<tr><td><code>");
            try escapeHtml(out, guardrail.metric);
            try out.writeAll("</code></td><td>");
            try out.print("{d}", .{guardrail.threshold});
            try out.writeAll("</td></tr>\n");
        }
        try out.writeAll("</tbody></table>\n");
    }

    try out.writeAll("<h2>Lifecycle</h2>\n<p class=\"sub\">Status: ");
    try statusPill(out, exp.status);
    try out.writeAll("</p>\n");

    if (exp.status != .concluded) {
        try out.writeAll("<div class=\"actions\" style=\"justify-content:flex-start\">");
        try out.writeAll("<button class=\"primary\" hx-post=\"/admin/experiments/");
        try escapeHtml(out, exp.id);
        try out.writeAll("/advance\" hx-target=\"#exp-result\" hx-swap=\"innerHTML\">");
        try out.writeAll(if (exp.status == .draft) "Start running" else "Conclude");
        try out.writeAll("</button></div>\n<div id=\"exp-result\"></div>\n");
    }

    try out.writeAll(
        \\<p class="sub">Frequentist, Bayesian, and guardrail analysis arrive with the
        \\analytics phase. This page is the definition and power surface.</p>
        \\
    );

    try footer(out);
    return .{ .html = try takeOwned(&alloc, arena) };
}

/// Parse the guardrail text area: one `metric | threshold` per line.
pub fn parseGuardrails(arena: std.mem.Allocator, raw: []const u8) ![]const experiment.Guardrail {
    var out: std.ArrayList(experiment.Guardrail) = .empty;
    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const bar = std.mem.indexOfScalar(u8, trimmed, '|') orelse continue;
        const metric = std.mem.trim(u8, trimmed[0..bar], " \t");
        const value = std.mem.trim(u8, trimmed[bar + 1 ..], " \t");
        if (metric.len == 0) continue;
        try out.append(arena, .{
            .metric = try arena.dupe(u8, metric),
            .threshold = std.fmt.parseFloat(f64, value) catch 0,
        });
    }
    return out.toOwnedSlice(arena);
}

/// Deterministic blast-radius preview: how many of a fixed synthetic
/// population flip when this flag is turned off, and which segments they are
/// in. Renders nothing when there is nothing to simulate.
fn blastRadiusPanel(
    arena: std.mem.Allocator,
    out: *Io.Writer,
    hub: *sync.SyncHub,
    key: []const u8,
    flag: storage.FlagRecord,
) !void {
    const result = try blastradius.simulate(arena, &hub.store, key, false, flag.rollout_percentage);
    if (result.sampled == 0) return;

    const pct = (@as(f64, @floatFromInt(result.affected)) / @as(f64, @floatFromInt(result.sampled))) * 100.0;
    try out.writeAll("<h2>Blast radius</h2>\n<p class=\"sub\">Simulated effect of turning this flag off over ");
    try out.print("{d}", .{result.sampled});
    try out.writeAll(" deterministic units.</p>\n<table><tbody>\n<tr><th>Enabled before</th><td>");
    try out.print("{d} of {d}", .{ result.enabled_before, result.sampled });
    try out.writeAll("</td></tr>\n<tr><th>Enabled after</th><td>");
    try out.print("{d} of {d}", .{ result.enabled_after, result.sampled });
    try out.writeAll("</td></tr>\n<tr><th>Affected</th><td>");
    try out.print("{d} unit(s) ({d:.1}%)", .{ result.affected, pct });
    try out.writeAll("</td></tr>\n</tbody></table>\n");

    var any_segment = false;
    for (result.by_segment) |hit| {
        if (hit.affected == 0) continue;
        if (!any_segment) {
            try out.writeAll("<table><thead><tr><th>Segment</th><th>Affected units</th></tr></thead><tbody>\n");
            any_segment = true;
        }
        try out.writeAll("<tr><td><code>");
        try escapeHtml(out, hit.key);
        try out.writeAll("</code></td><td>");
        try out.print("{d}", .{hit.affected});
        try out.writeAll("</td></tr>\n");
    }
    if (any_segment) try out.writeAll("</tbody></table>\n");
}

/// Login page for the admin UI. v1 exchanges a bearer token for a cookie.
pub fn loginPage(arena: std.mem.Allocator, err: ?[]const u8) !Page {
    var alloc: Io.Writer.Allocating = .init(arena);
    const out: *Io.Writer = &alloc.writer;

    try out.writeAll(
        \\<!DOCTYPE html>
        \\<html lang="en"><head><meta charset="utf-8">
        \\<meta name="viewport" content="width=device-width, initial-scale=1">
        \\<title>Sign in - Doppio Admin</title>
        \\<style>
        \\:root{--bg:#0d1117;--panel:#161b22;--line:#30363d;--fg:#c9d1d9;--dim:#8b949e;--acc:#58a6ff}
        \\body{margin:0;font:14px/1.5 ui-sans-serif,system-ui,sans-serif;background:var(--bg);color:var(--fg);display:grid;place-items:center;min-height:100vh}
        \\form{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:28px;width:340px}
        \\h1{font-size:18px;margin:0 0 4px}
        \\.sub{color:var(--dim);margin:0 0 18px;font-size:13px}
        \\label{display:block;font-size:12px;color:var(--dim);margin:12px 0 4px;text-transform:uppercase}
        \\input{width:100%;padding:9px 10px;background:#0d1117;color:var(--fg);border:1px solid var(--line);border-radius:6px}
        \\button{width:100%;margin-top:18px;padding:9px;background:var(--acc);border:1px solid var(--acc);color:#0d1117;border-radius:6px;font-weight:700;cursor:pointer}
        \\.err{color:#f85149;font-size:13px;margin-top:12px}
        \\</style></head><body>
        \\<form method="post" action="/admin/login">
        \\<h1>Doppio Admin</h1>
        \\<p class="sub">Sign in with an admin bearer token.</p>
        \\
    );
    if (err) |message| {
        try out.writeAll("<div class=\"err\">");
        try escapeHtml(out, message);
        try out.writeAll("</div>\n");
    }
    try out.writeAll(
        \\<label for="token">Admin token</label>
        \\<input type="password" id="token" name="token" required autocomplete="current-password">
        \\<button type="submit">Sign in</button>
        \\</form>
        \\</body></html>
        \\
    );
    return .{ .html = try takeOwned(&alloc, arena) };
}

/// A short confirmation fragment returned by HTMX posts.
pub fn crResultFragment(arena: std.mem.Allocator, message: []const u8, ok: bool) ![]const u8 {
    var alloc: Io.Writer.Allocating = .init(arena);
    const out: *Io.Writer = &alloc.writer;
    try out.writeAll("<div class=\"banner ");
    try out.writeAll(if (ok) "ok" else "err");
    try out.writeAll("\">");
    try escapeHtml(out, message);
    try out.writeAll("</div>");
    return try takeOwned(&alloc, arena);
}

test "escapeHtml neutralizes angle brackets, ampersands, and quotes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const html = try renderWith(arena.allocator(), "<script>alert(\"x\" & 'y')</script>");
    try std.testing.expectEqualStrings(
        "&lt;script&gt;alert(&quot;x&quot; &amp; &#39;y&#39;)&lt;/script&gt;",
        html,
    );
}

/// Render raw text through escapeHtml into an owned arena slice.
pub fn renderWith(arena: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var alloc: Io.Writer.Allocating = .init(arena);
    try escapeHtml(&alloc.writer, raw);
    return try takeOwned(&alloc, arena);
}

test "flagsTable renders escaped keys and state pills" {
    var hub = sync.SyncHub.init(std.testing.allocator);
    defer hub.deinit();

    const io = std.testing.io;
    hub.lock(io);
    try hub.store.putFlag("evil<flag>", .{ .key = "evil<flag>", .enabled = true, .rollout_percentage = 50 }, "admin");
    hub.unlock(io);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var alloc: Io.Writer.Allocating = .init(arena.allocator());
    try flagsTable(&alloc.writer, &hub);
    const html = try takeOwned(&alloc, arena.allocator());

    try std.testing.expect(std.mem.indexOf(u8, html, "evil&lt;flag&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "evil<flag>") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "50%") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "pill on") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"flag-rows\"") != null);
}

test "consoleResult reports TRUE and FALSE verdicts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const yes = try consoleResult(arena.allocator(), "unit_id == \"user-123\"", "user-123", &.{});
    try std.testing.expect(std.mem.indexOf(u8, yes, "TRUE") != null);

    const no = try consoleResult(arena.allocator(), "unit_id == \"someone-else\"", "user-123", &.{});
    try std.testing.expect(std.mem.indexOf(u8, no, "FALSE") != null);
}

test "consoleResult uses extra attributes for segment expressions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const attrs = try parseConsoleAttributes(arena.allocator(), "account.plan=enterprise, country=de");
    try std.testing.expectEqual(@as(usize, 2), attrs.len);
    try std.testing.expectEqualStrings("account.plan", attrs[0].key);
    try std.testing.expectEqualStrings("enterprise", attrs[0].value);

    const match = try consoleResult(arena.allocator(), "account.plan == \"enterprise\"", "u-1", attrs);
    try std.testing.expect(std.mem.indexOf(u8, match, "TRUE") != null);
    try std.testing.expect(std.mem.indexOf(u8, match, "account.plan = enterprise") != null);

    const miss = try consoleResult(arena.allocator(), "account.plan == \"starter\"", "u-1", attrs);
    try std.testing.expect(std.mem.indexOf(u8, miss, "FALSE") != null);

    // Junk and blank entries are skipped rather than failing evaluation.
    const sparse = try parseConsoleAttributes(arena.allocator(), " , no-equals-sign , ok=1 ");
    try std.testing.expectEqual(@as(usize, 1), sparse.len);
    try std.testing.expectEqualStrings("ok", sparse[0].key);
}

test "consoleResult escapes a hostile expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const frag = try consoleResult(arena.allocator(), "<script>bad()</script>", "u", &.{});
    try std.testing.expect(std.mem.indexOf(u8, frag, "<script>bad()</script>") == null);
    try std.testing.expect(std.mem.indexOf(u8, frag, "&lt;script&gt;") != null);
}
