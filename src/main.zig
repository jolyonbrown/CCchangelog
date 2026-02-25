const std = @import("std");
const log = std.log;

// ── Types ───────────────────────────────────────────────────────────────────

const ChangelogEntry = struct {
    text: []const u8,
};

const BlueskySession = struct {
    access_jwt: []const u8,
    did: []const u8,
};

const PostRef = struct {
    uri: []const u8,
    cid: []const u8,
};

// ── HTTP utilities ──────────────────────────────────────────────────────────

fn httpGet(
    client: *std.http.Client,
    allocator: std.mem.Allocator,
    url: []const u8,
    extra_headers: []const std.http.Header,
) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .extra_headers = extra_headers,
        .response_writer = &aw.writer,
    });

    if (result.status != .ok) {
        log.err("HTTP GET {s} returned status {}", .{ url, result.status });
        return error.HttpError;
    }

    return try aw.toOwnedSlice();
}

fn httpPost(
    client: *std.http.Client,
    allocator: std.mem.Allocator,
    url: []const u8,
    payload: []const u8,
    extra_headers: []const std.http.Header,
) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    const result = try client.fetch(.{
        .method = .POST,
        .location = .{ .url = url },
        .payload = payload,
        .extra_headers = extra_headers,
        .response_writer = &aw.writer,
    });

    if (result.status != .ok) {
        log.err("HTTP POST {s} returned status {}", .{ url, result.status });
        log.err("Response body: {s}", .{aw.written()});
        return error.HttpError;
    }

    return try aw.toOwnedSlice();
}

// ── GitHub version detection ────────────────────────────────────────────────

const ReleaseInfo = struct {
    version: []const u8,
    changelog_body: ?[]const u8,
};

fn fetchLatestRelease(client: *std.http.Client, allocator: std.mem.Allocator) !ReleaseInfo {
    const body = try httpGet(
        client,
        allocator,
        "https://api.github.com/repos/anthropics/claude-code/releases/latest",
        &.{
            .{ .name = "User-Agent", .value = "CCchangelog-bot" },
            .{ .name = "Accept", .value = "application/vnd.github+json" },
        },
    );
    defer allocator.free(body);

    const parsed = try std.json.parseFromSlice(
        struct { tag_name: []const u8, body: ?[]const u8 },
        allocator,
        body,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();

    const tag = parsed.value.tag_name;
    // Strip leading "v" from tag_name (e.g. "v1.0.0" -> "1.0.0")
    const version = if (tag.len > 0 and tag[0] == 'v') tag[1..] else tag;

    return .{
        .version = try allocator.dupe(u8, version),
        .changelog_body = if (parsed.value.body) |b| try allocator.dupe(u8, b) else null,
    };
}

// ── State management ────────────────────────────────────────────────────────

fn readLastVersion(allocator: std.mem.Allocator) !?[]const u8 {
    const file = std.fs.cwd().openFile("last_version.txt", .{}) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 1024);
    const trimmed = std.mem.trim(u8, content, " \t\n\r");
    if (trimmed.len == 0) {
        allocator.free(content);
        return null;
    }
    const result = try allocator.dupe(u8, trimmed);
    allocator.free(content);
    return result;
}

fn writeLastVersion(version: []const u8) !void {
    var file = try std.fs.cwd().createFile("last_version.txt", .{});
    defer file.close();
    try file.writeAll(version);
}

// ── Changelog parsing ───────────────────────────────────────────────────────

fn parseChangelog(allocator: std.mem.Allocator, body: []const u8) ![]ChangelogEntry {
    var entries: std.ArrayListUnmanaged(ChangelogEntry) = .{};
    defer entries.deinit(allocator);

    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len >= 2 and trimmed[0] == '-' and trimmed[1] == ' ') {
            const text = try allocator.dupe(u8, trimmed[2..]);
            try entries.append(allocator, .{ .text = text });
        } else if (trimmed.len >= 2 and trimmed[0] == '*' and trimmed[1] == ' ') {
            const text = try allocator.dupe(u8, trimmed[2..]);
            try entries.append(allocator, .{ .text = text });
        }
    }

    return try entries.toOwnedSlice(allocator);
}

fn freeChangelogEntries(allocator: std.mem.Allocator, entries: []ChangelogEntry) void {
    for (entries) |entry| {
        allocator.free(entry.text);
    }
    allocator.free(entries);
}

// ── JSON serialization helpers ──────────────────────────────────────────────

fn jsonStringify(allocator: std.mem.Allocator, value: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(allocator, value, .{});
}

fn jsonEncodeString(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    // JSON-encode a string (with escaping) including quotes
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try std.json.Stringify.encodeJsonString(s, .{}, &aw.writer);
    return try aw.toOwnedSlice();
}

// ── Anthropic API ───────────────────────────────────────────────────────────

fn callAnthropic(
    client: *std.http.Client,
    allocator: std.mem.Allocator,
    api_key: []const u8,
    prompt: []const u8,
    max_tokens: u32,
) ![]const u8 {
    // Build JSON request body manually to avoid issues with anonymous struct serialization
    const escaped_prompt = try jsonEncodeString(allocator, prompt);
    defer allocator.free(escaped_prompt);

    const request_body = try std.fmt.allocPrint(allocator,
        \\{{"model":"claude-haiku-4-5-20251001","max_tokens":{d},"messages":[{{"role":"user","content":{s}}}]}}
    , .{ max_tokens, escaped_prompt });
    defer allocator.free(request_body);

    const response = try httpPost(
        client,
        allocator,
        "https://api.anthropic.com/v1/messages",
        request_body,
        &.{
            .{ .name = "x-api-key", .value = api_key },
            .{ .name = "anthropic-version", .value = "2023-06-01" },
            .{ .name = "Content-Type", .value = "application/json" },
        },
    );
    defer allocator.free(response);

    // Parse content[0].text from the response
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        response,
        .{},
    );
    defer parsed.deinit();

    const content_array = parsed.value.object.get("content") orelse return error.InvalidResponse;
    if (content_array != .array or content_array.array.items.len == 0) return error.InvalidResponse;
    const first = content_array.array.items[0];
    if (first != .object) return error.InvalidResponse;
    const text_val = first.object.get("text") orelse return error.InvalidResponse;
    if (text_val != .string) return error.InvalidResponse;

    return try allocator.dupe(u8, text_val.string);
}

fn generateHeadline(
    client: *std.http.Client,
    allocator: std.mem.Allocator,
    api_key: []const u8,
    version: []const u8,
    entries: []const ChangelogEntry,
) ![]const u8 {
    var prompt_buf: std.ArrayListUnmanaged(u8) = .{};
    defer prompt_buf.deinit(allocator);

    try prompt_buf.appendSlice(allocator,
        "Summarize this Claude Code release in one short line (max 200 chars). " ++
            "Be concise and informative. No quotes. Just the summary line.\n\nChangelog:\n",
    );
    for (entries) |entry| {
        try prompt_buf.appendSlice(allocator, "- ");
        try prompt_buf.appendSlice(allocator, entry.text);
        try prompt_buf.append(allocator, '\n');
    }

    const headline = try callAnthropic(client, allocator, api_key, prompt_buf.items, 100);
    defer allocator.free(headline);

    return try std.fmt.allocPrint(allocator, "Claude Code {s}\n\n{s}", .{ version, headline });
}

fn generateDetailSummaries(
    client: *std.http.Client,
    allocator: std.mem.Allocator,
    api_key: []const u8,
    entries: []const ChangelogEntry,
) ![][]const u8 {
    const batch_size: usize = 4;
    const num_batches = (entries.len + batch_size - 1) / batch_size;

    var summaries: std.ArrayListUnmanaged([]const u8) = .{};
    defer summaries.deinit(allocator);

    var i: usize = 0;
    while (i < num_batches) : (i += 1) {
        const start = i * batch_size;
        const end = @min(start + batch_size, entries.len);
        const batch = entries[start..end];

        var prompt_buf: std.ArrayListUnmanaged(u8) = .{};
        defer prompt_buf.deinit(allocator);

        try prompt_buf.appendSlice(allocator,
            "Summarize these changelog entries into a concise post (max 250 chars). " ++
                "Keep technical details. No quotes. Just the summary.\n\nEntries:\n",
        );
        for (batch) |entry| {
            try prompt_buf.appendSlice(allocator, "- ");
            try prompt_buf.appendSlice(allocator, entry.text);
            try prompt_buf.append(allocator, '\n');
        }

        const summary = try callAnthropic(client, allocator, api_key, prompt_buf.items, 120);
        try summaries.append(allocator, summary);
    }

    return try summaries.toOwnedSlice(allocator);
}

// ── Bluesky AT Protocol ─────────────────────────────────────────────────────

fn blueskyAuth(
    client: *std.http.Client,
    allocator: std.mem.Allocator,
    handle: []const u8,
    password: []const u8,
) !BlueskySession {
    const escaped_handle = try jsonEncodeString(allocator, handle);
    defer allocator.free(escaped_handle);
    const escaped_password = try jsonEncodeString(allocator, password);
    defer allocator.free(escaped_password);

    const request_body = try std.fmt.allocPrint(allocator,
        \\{{"identifier":{s},"password":{s}}}
    , .{ escaped_handle, escaped_password });
    defer allocator.free(request_body);

    const response = try httpPost(
        client,
        allocator,
        "https://bsky.social/xrpc/com.atproto.server.createSession",
        request_body,
        &.{.{ .name = "Content-Type", .value = "application/json" }},
    );
    defer allocator.free(response);

    const parsed = try std.json.parseFromSlice(
        struct { accessJwt: []const u8, did: []const u8 },
        allocator,
        response,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();

    return .{
        .access_jwt = try allocator.dupe(u8, parsed.value.accessJwt),
        .did = try allocator.dupe(u8, parsed.value.did),
    };
}

fn blueskyPost(
    client: *std.http.Client,
    allocator: std.mem.Allocator,
    session: BlueskySession,
    text: []const u8,
    reply: ?struct { root: PostRef, parent: PostRef },
    facets_json: ?[]const u8,
) !PostRef {
    const truncated = truncateGraphemes(text, 300);
    const timestamp = getTimestamp();

    const escaped_text = try jsonEncodeString(allocator, truncated);
    defer allocator.free(escaped_text);
    const escaped_did = try jsonEncodeString(allocator, session.did);
    defer allocator.free(escaped_did);

    // Build the record JSON
    var json_buf: std.ArrayListUnmanaged(u8) = .{};
    defer json_buf.deinit(allocator);

    try json_buf.appendSlice(allocator, "{\"repo\":");
    try json_buf.appendSlice(allocator, escaped_did);
    try json_buf.appendSlice(allocator, ",\"collection\":\"app.bsky.feed.post\",\"record\":{");
    try json_buf.appendSlice(allocator, "\"$type\":\"app.bsky.feed.post\",\"text\":");
    try json_buf.appendSlice(allocator, escaped_text);
    try json_buf.appendSlice(allocator, ",\"createdAt\":\"");
    try json_buf.appendSlice(allocator, &timestamp);
    try json_buf.appendSlice(allocator, "\"");

    if (facets_json) |facets| {
        try json_buf.appendSlice(allocator, ",\"facets\":");
        try json_buf.appendSlice(allocator, facets);
    }

    if (reply) |r| {
        const escaped_root_uri = try jsonEncodeString(allocator, r.root.uri);
        defer allocator.free(escaped_root_uri);
        const escaped_root_cid = try jsonEncodeString(allocator, r.root.cid);
        defer allocator.free(escaped_root_cid);
        const escaped_parent_uri = try jsonEncodeString(allocator, r.parent.uri);
        defer allocator.free(escaped_parent_uri);
        const escaped_parent_cid = try jsonEncodeString(allocator, r.parent.cid);
        defer allocator.free(escaped_parent_cid);

        try json_buf.appendSlice(allocator, ",\"reply\":{\"root\":{\"uri\":");
        try json_buf.appendSlice(allocator, escaped_root_uri);
        try json_buf.appendSlice(allocator, ",\"cid\":");
        try json_buf.appendSlice(allocator, escaped_root_cid);
        try json_buf.appendSlice(allocator, "},\"parent\":{\"uri\":");
        try json_buf.appendSlice(allocator, escaped_parent_uri);
        try json_buf.appendSlice(allocator, ",\"cid\":");
        try json_buf.appendSlice(allocator, escaped_parent_cid);
        try json_buf.appendSlice(allocator, "}}");
    }

    try json_buf.appendSlice(allocator, "}}");

    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{session.access_jwt});
    defer allocator.free(auth_header);

    const response = try httpPost(
        client,
        allocator,
        "https://bsky.social/xrpc/com.atproto.repo.createRecord",
        json_buf.items,
        &.{
            .{ .name = "Authorization", .value = auth_header },
            .{ .name = "Content-Type", .value = "application/json" },
        },
    );
    defer allocator.free(response);

    const parsed = try std.json.parseFromSlice(
        struct { uri: []const u8, cid: []const u8 },
        allocator,
        response,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();

    return .{
        .uri = try allocator.dupe(u8, parsed.value.uri),
        .cid = try allocator.dupe(u8, parsed.value.cid),
    };
}

fn postThread(
    client: *std.http.Client,
    allocator: std.mem.Allocator,
    session: BlueskySession,
    headline: []const u8,
    details: []const []const u8,
    version: []const u8,
) !void {
    // Build headline text with changelog link
    const link_text = "View full changelog";
    const release_url = try std.fmt.allocPrint(
        allocator,
        "https://github.com/anthropics/claude-code/releases/tag/v{s}",
        .{version},
    );
    defer allocator.free(release_url);

    const headline_with_link = try std.fmt.allocPrint(
        allocator,
        "{s}\n\n{s}",
        .{ headline, link_text },
    );
    defer allocator.free(headline_with_link);

    // Build facets JSON for the link
    const link_byte_start = headline.len + 2; // +2 for "\n\n"
    const link_byte_end = link_byte_start + link_text.len;

    const escaped_url = try jsonEncodeString(allocator, release_url);
    defer allocator.free(escaped_url);

    const facets = try std.fmt.allocPrint(allocator,
        \\[{{"index":{{"byteStart":{d},"byteEnd":{d}}},"features":[{{"$type":"app.bsky.richtext.facet#link","uri":{s}}}]}}]
    , .{ link_byte_start, link_byte_end, escaped_url });
    defer allocator.free(facets);

    // Post headline with link facet
    const root_ref = try blueskyPost(client, allocator, session, headline_with_link, null, facets);
    defer allocator.free(root_ref.uri);
    defer allocator.free(root_ref.cid);
    log.info("Posted headline: {s}", .{root_ref.uri});

    // Post detail summaries as replies (with delays to avoid spam filters)
    var parent_ref = PostRef{ .uri = root_ref.uri, .cid = root_ref.cid };
    for (details, 0..) |detail, i| {
        // Delay between posts to avoid triggering Bluesky rate limits
        std.Thread.sleep(3 * std.time.ns_per_s);

        // Format: "[1/N] summary text"
        const numbered = try std.fmt.allocPrint(
            allocator,
            "[{d}/{d}] {s}",
            .{ i + 1, details.len, detail },
        );
        defer allocator.free(numbered);

        const new_ref = try blueskyPost(client, allocator, session, numbered, .{
            .root = root_ref,
            .parent = parent_ref,
        }, null);
        if (i > 0) {
            allocator.free(parent_ref.uri);
            allocator.free(parent_ref.cid);
        }
        parent_ref = new_ref;
        log.info("Posted detail {}/{}: {s}", .{ i + 1, details.len, new_ref.uri });
    }
    if (details.len > 0) {
        allocator.free(parent_ref.uri);
        allocator.free(parent_ref.cid);
    }
}

// ── Utilities ───────────────────────────────────────────────────────────────

fn countGraphemes(text: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const byte = text[i];
        if (byte < 0x80) {
            i += 1;
        } else if (byte < 0xC0) {
            i += 1;
            continue;
        } else if (byte < 0xE0) {
            i += 2;
        } else if (byte < 0xF0) {
            i += 3;
        } else {
            i += 4;
        }
        count += 1;
    }
    return count;
}

fn truncateGraphemes(text: []const u8, max: usize) []const u8 {
    if (max < 4) return text;
    const limit = max - 3; // room for "..."

    var count: usize = 0;
    var i: usize = 0;
    var last_cut: usize = 0;

    while (i < text.len) {
        const byte = text[i];
        if (byte < 0x80) {
            i += 1;
        } else if (byte < 0xC0) {
            i += 1;
            continue;
        } else if (byte < 0xE0) {
            i += 2;
        } else if (byte < 0xF0) {
            i += 3;
        } else {
            i += 4;
        }
        count += 1;
        if (count == limit) {
            last_cut = i;
        }
        if (count > max) {
            return text[0..last_cut];
        }
    }

    return text;
}

fn getTimestamp() [24]u8 {
    const epoch_secs = std.time.timestamp();
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(epoch_secs) };
    const day = epoch.getDaySeconds();
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    var buf: [24]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.000Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day.getHoursIntoDay(),
        day.getMinutesIntoHour(),
        day.getSecondsIntoMinute(),
    }) catch unreachable;
    return buf;
}

fn getEnvVar(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    return std.process.getEnvVarOwned(allocator, name) catch |err| {
        log.err("Missing environment variable: {s}", .{name});
        return err;
    };
}

// ── Main ────────────────────────────────────────────────────────────────────

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    // Check GitHub releases first — no secrets needed for this
    log.info("Checking GitHub releases for latest Claude Code version...", .{});
    const release_info = fetchLatestRelease(&client, allocator) catch |err| {
        log.err("Failed to fetch latest release: {}", .{err});
        std.process.exit(1);
    };
    defer allocator.free(release_info.version);
    defer if (release_info.changelog_body) |b| allocator.free(b);
    const latest_version = release_info.version;
    log.info("Latest release version: {s}", .{latest_version});

    const last_version = readLastVersion(allocator) catch |err| {
        log.err("Failed to read last_version.txt: {}", .{err});
        std.process.exit(1);
    };
    defer if (last_version) |v| allocator.free(v);

    if (last_version) |v| {
        if (std.mem.eql(u8, v, latest_version)) {
            log.info("No new version detected (current: {s}). Exiting.", .{v});
            return;
        }
        log.info("New version detected: {s} -> {s}", .{ v, latest_version });
    } else {
        log.info("No cached version found. Treating {s} as new.", .{latest_version});
    }

    // Only load secrets after confirming there's a new version
    const api_key = getEnvVar(allocator, "ANTHROPIC_API_KEY") catch std.process.exit(1);
    defer allocator.free(api_key);
    const bsky_handle = getEnvVar(allocator, "BLUESKY_HANDLE") catch std.process.exit(1);
    defer allocator.free(bsky_handle);
    const bsky_password = getEnvVar(allocator, "BLUESKY_APP_PASSWORD") catch std.process.exit(1);
    defer allocator.free(bsky_password);

    const changelog_body = release_info.changelog_body orelse "";

    const entries = parseChangelog(allocator, changelog_body) catch |err| {
        log.err("Failed to parse changelog: {}", .{err});
        std.process.exit(1);
    };
    defer freeChangelogEntries(allocator, entries);
    log.info("Parsed {} changelog entries", .{entries.len});

    if (entries.len == 0) {
        log.warn("No changelog entries found. Posting version announcement only.", .{});
    }

    log.info("Generating summaries via Claude Haiku...", .{});
    const headline = if (entries.len > 0)
        generateHeadline(&client, allocator, api_key, latest_version, entries) catch |err| {
            log.err("Failed to generate headline: {}", .{err});
            std.process.exit(1);
        }
    else
        try std.fmt.allocPrint(allocator, "Claude Code {s}", .{latest_version});
    defer allocator.free(headline);

    // Skip detail posts when there are few entries — the headline already covers them,
    // and Haiku tends to produce meta-responses when asked to summarize a single item.
    const details = if (entries.len > 4)
        generateDetailSummaries(&client, allocator, api_key, entries) catch |err| {
            log.err("Failed to generate detail summaries: {}", .{err});
            std.process.exit(1);
        }
    else
        try allocator.alloc([]const u8, 0);
    defer {
        for (details) |d| allocator.free(d);
        allocator.free(details);
    }

    log.info("Authenticating with Bluesky...", .{});
    const session = blueskyAuth(&client, allocator, bsky_handle, bsky_password) catch |err| {
        log.err("Failed to authenticate with Bluesky: {}", .{err});
        std.process.exit(1);
    };
    defer allocator.free(session.access_jwt);
    defer allocator.free(session.did);

    log.info("Posting thread to Bluesky...", .{});
    postThread(&client, allocator, session, headline, details, latest_version) catch |err| {
        log.err("Failed to post thread: {}", .{err});
        std.process.exit(1);
    };

    writeLastVersion(latest_version) catch |err| {
        log.err("Failed to write last_version.txt: {}", .{err});
        std.process.exit(1);
    };

    log.info("Successfully posted changelog for Claude Code {s}", .{latest_version});
}

// ── Tests ───────────────────────────────────────────────────────────────────

test "parseChangelog extracts dash-prefixed entries" {
    const allocator = std.testing.allocator;
    const body =
        \\# Release Notes
        \\
        \\## Changes
        \\
        \\- Added new feature X
        \\- Fixed bug in Y
        \\- Improved performance of Z
        \\
        \\Some other text
    ;

    const entries = try parseChangelog(allocator, body);
    defer freeChangelogEntries(allocator, entries);

    try std.testing.expectEqual(@as(usize, 3), entries.len);
    try std.testing.expectEqualStrings("Added new feature X", entries[0].text);
    try std.testing.expectEqualStrings("Fixed bug in Y", entries[1].text);
    try std.testing.expectEqualStrings("Improved performance of Z", entries[2].text);
}

test "parseChangelog extracts asterisk-prefixed entries" {
    const allocator = std.testing.allocator;
    const body =
        \\* First item
        \\* Second item
    ;

    const entries = try parseChangelog(allocator, body);
    defer freeChangelogEntries(allocator, entries);

    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("First item", entries[0].text);
    try std.testing.expectEqualStrings("Second item", entries[1].text);
}

test "parseChangelog handles empty input" {
    const allocator = std.testing.allocator;
    const entries = try parseChangelog(allocator, "");
    defer freeChangelogEntries(allocator, entries);
    try std.testing.expectEqual(@as(usize, 0), entries.len);
}

test "countGraphemes ASCII" {
    try std.testing.expectEqual(@as(usize, 5), countGraphemes("hello"));
    try std.testing.expectEqual(@as(usize, 0), countGraphemes(""));
}

test "countGraphemes multibyte" {
    try std.testing.expectEqual(@as(usize, 4), countGraphemes("caf\xC3\xA9"));
    try std.testing.expectEqual(@as(usize, 1), countGraphemes("\xF0\x9F\x98\x80"));
}

test "truncateGraphemes short text unchanged" {
    const text = "hello world";
    try std.testing.expectEqualStrings(text, truncateGraphemes(text, 300));
}

test "truncateGraphemes long text truncated" {
    const text = "a" ** 310;
    const result = truncateGraphemes(text, 300);
    try std.testing.expectEqual(@as(usize, 297), result.len);
}

test "getTimestamp format" {
    const ts = getTimestamp();
    try std.testing.expect(ts[4] == '-');
    try std.testing.expect(ts[7] == '-');
    try std.testing.expect(ts[10] == 'T');
    try std.testing.expect(ts[13] == ':');
    try std.testing.expect(ts[16] == ':');
    try std.testing.expect(ts[23] == 'Z');
}

test "jsonEncodeString escapes properly" {
    const allocator = std.testing.allocator;
    const result = try jsonEncodeString(allocator, "hello \"world\"\nnewline");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("\"hello \\\"world\\\"\\nnewline\"", result);
}
