const std = @import("std");
const assert = std.debug.assert;
const Ed25519 = std.crypto.sign.Ed25519;
const testing = std.testing;
const ChannelId = @import("./channel.zig").ChannelId;
const varint = @import("./varint.zig");
const Hash = std.crypto.hash.Gimli;

/// All ȱ packets are the same size
///
/// This number is based on max UDP over IPv4 packet size:
/// - IPv4 mandates a path MTU of at least 576 bytes
/// - IPv4 header is at maximum 60 bytes
/// - UDP header is 8 bytes
/// => 576 - 60 - 8 = 504
const packet_size = 504;

const authentication_tag_length = 16;

pub const MessageId = extern struct {
    pub const len = 6;

    id: [len]u8,

    pub fn initInt(n: u48) MessageId {
        var self: MessageId = undefined;
        std.mem.writeIntBig(u48, &self.id, n);
        return self;
    }

    pub fn asInt(self: MessageId) u48 {
        return std.mem.readIntBig(u48, &self.id);
    }

    pub fn next(self: MessageId) MessageId {
        const n = self.asInt();
        return initInt(n + 1);
    }
};

pub const MessageIdHash = extern struct {
    pub const len = 6;
    pub const magic_string = "ȱ id hash";

    hash: [len]u8,

    pub fn calculate(channel_id: ChannelId, message_id: MessageId) MessageIdHash {
        var self: MessageIdHash = undefined;
        var hash = Hash.init(.{});
        hash.update(magic_string);
        hash.update(&channel_id.id);
        hash.update(&message_id.id);
        hash.final(&self.hash);
        return self;
    }

    pub fn asInteger(self: MessageIdHash) u48 {
        return std.mem.readIntBig(u48, &self.hash);
    }
};

pub const MessageHash = extern struct {
    /// Hash size is selected to be as small as possible while cryptographically collision resistant
    pub const len = 16;

    pub const magic_string = "ȱ message hash";

    hash: [len]u8,

    pub fn calculate(message: Message) MessageHash {
        var self: MessageHash = undefined;
        var hash = Hash.init(.{});
        hash.update(magic_string);
        hash.update(std.mem.asBytes(&message));
        hash.final(&self.hash);
        return self;
    }
};

const IntraChannelReference = extern struct {
    id: MessageId,
    hash: MessageHash,
};

const InReplyTo = IntraChannelReference;

const PayloadType = enum(u2) {
    authorization,
    payload,
    encrypted_payload,
    _,
};

const Conditions = enum(u32) {
    ttl,
    _,
};

const Condition = union(Conditions) {
    pub fn check(
        self: @This(),
        context: Authorization,
        candidate: Envelope,
        candidate_message_id: MessageId,
    ) bool {
        const activeTag = std.meta.activeTag(self);
        inline for (std.meta.fields(@This())) |field_info| {
            if (@field(Conditions, field_info.name) == activeTag) {
                return @field(self, field_info.name).check(context, candidate, candidate_message_id);
            }
        }
        unreachable;
    }

    ttl: struct {
        ttl: u48,

        pub fn check(
            self: @This(),
            context: Authorization,
            candidate: Envelope,
            candidate_message_id: MessageId,
        ) bool {
            return candidate_message_id.asInt() <= (context.message_id.asInt() + self.ttl);
        }
    },
};

pub const Authorization = struct {
    slice: []u8,
    message_id: MessageId,

    const Self = @This();

    pub fn authorizes(self: Self, candidate: Envelope, message_id: MessageId) !bool {
        const public_key = self.slice[0..Ed25519.public_length];
        candidate.verify(public_key.*) catch return false;

        var stack: [@sizeOf(Condition) * (Envelope.varying_space - Ed25519.public_length) / "{\"a\":1}".len]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&stack);

        var tokens = std.json.TokenStream.init(self.slice[Ed25519.public_length..]);
        const json_options = std.json.ParseOptions{
            .allocator = &fba.allocator,
            .allow_trailing_data = true,
        };
        const conditions = try std.json.parse([]Condition, &tokens, json_options);
        defer std.json.parseFree([]Condition, conditions, json_options);

        const unused = self.slice[Ed25519.public_length + tokens.i ..];
        if (!std.mem.allEqual(u8, unused, 0)) return error.InvalidPadding;

        for (conditions) |c| {
            if (!c.check(self, candidate, message_id)) return false;
        }
        return true;
    }
};

test "parse Authorization" {
    const key_pair = try Ed25519.KeyPair.create(null);

    var e = Envelope.init(undefined, MessageHash{ .hash = "abcdef1234567890".* });
    std.mem.copy(u8, e.getPayloadSlice(), &[_]u8{0} ** 378);
    try e.sign(key_pair);

    {
        const slice = try std.mem.concat(testing.allocator, u8, &[_][]const u8{ &key_pair.public_key, "[]trailing junk" });
        defer testing.allocator.free(slice);
        const a = Authorization{ .slice = slice, .message_id = undefined };
        try testing.expectError(error.InvalidPadding, a.authorizes(e, undefined));
    }
    {
        const slice = try std.mem.concat(testing.allocator, u8, &[_][]const u8{ &key_pair.public_key, "[]" });
        defer testing.allocator.free(slice);
        const a = Authorization{ .slice = slice, .message_id = MessageId.initInt(1) };
        try testing.expect(try a.authorizes(e, undefined));
    }
    {
        const slice = try std.mem.concat(testing.allocator, u8, &[_][]const u8{ &key_pair.public_key, "[{\"ttl\":1}]" });
        defer testing.allocator.free(slice);
        const a = Authorization{ .slice = slice, .message_id = MessageId.initInt(1) };
        try testing.expect(try a.authorizes(e, MessageId.initInt(2)));
    }
    {
        const slice = try std.mem.concat(testing.allocator, u8, &[_][]const u8{ &key_pair.public_key, "[{\"ttl\":1}]" });
        defer testing.allocator.free(slice);
        const a = Authorization{ .slice = slice, .message_id = MessageId.initInt(1) };
        try testing.expect(!try a.authorizes(e, MessageId.initInt(4)));
    }
}

pub const Envelope = extern struct {
    /// Workaround Zig packed struct bugs
    workaround: packed struct {
        continuation: bool,
        payload_type: PayloadType,
        padding: u4 = 0,
        n_in_reply_to_bytes: u9,
    },
    authorization: IntraChannelReference,
    first_in_reply_to: MessageHash,
    in_reply_to_and_payload: [varying_space]u8,
    signature: [Ed25519.signature_length]u8,

    const varying_space = packet_size -
        // outside of envelope
        (MessageIdHash.len + authentication_tag_length) -

        // info bytes
        2 -
        // authorization
        @sizeOf(IntraChannelReference) -
        // first_in_reply_to
        MessageHash.len -
        // signature
        Ed25519.signature_length;

    const Self = @This();

    pub fn init(authorization: IntraChannelReference, inReplyToHash: MessageHash) Self {
        return Self{
            .workaround = .{
                .continuation = false,
                .payload_type = .payload, // TODO: arg?
                .n_in_reply_to_bytes = 0,
            },
            .authorization = authorization,
            .first_in_reply_to = inReplyToHash,
            .in_reply_to_and_payload = undefined,
            .signature = undefined,
        };
    }

    pub const InReplyToIterator = struct {
        fbs: std.io.FixedBufferStream([]u8),
        message_id: u48,

        pub fn current(it: InReplyToIterator) !IntraChannelReference {
            var fbs_copy = it.fbs;
            const reader = fbs_copy.reader();
            const n = try varint.read(u48, reader);
            return .{
                .id = MessageId.initInt(try std.math.sub(u48, it.message_id, n)),
                .hash = reader.readStruct(MessageHash) catch unreachable,
            };
        }

        pub fn next(it: *InReplyToIterator) !?IntraChannelReference {
            const old_pos = it.fbs.pos;
            errdefer it.fbs.pos = old_pos;

            const reader = it.fbs.reader();
            const n = varint.read(u48, reader) catch |err| switch (err) {
                error.EndOfStream => return null,
                else => return err,
            };
            it.message_id = try std.math.sub(u48, it.message_id, n);
            return IntraChannelReference{
                .id = MessageId.initInt(it.message_id),
                .hash = reader.readStruct(MessageHash) catch unreachable,
            };
        }
    };

    pub fn iterateReplyTo(self: *Self, message_id: MessageId) InReplyToIterator {
        return .{
            .fbs = .{
                .buffer = self.in_reply_to_and_payload[0..self.workaround.n_in_reply_to_bytes],
                .pos = 0,
            },
            .message_id = message_id.asInt() - 1,
        };
    }

    pub fn addInReplyTo(self: *Self, message_id: MessageId, inReplyTo: IntraChannelReference) error{NoSpace}!void {
        assert(inReplyTo.id.asInt() < message_id.asInt());

        var it = self.iterateReplyTo(message_id);

        // find location in sorted list
        // `it` will be at the first occurance that needs to be bumped down (or at the end of the list)
        var previous_message_id: u48 = message_id.asInt() - 1; // first in-reply-to
        var moved_varint_size_diff: usize = 0;
        while (it.next() catch unreachable) |_| { // will break loop if new location is at end
            if (it.message_id < inReplyTo.id.asInt()) {
                // found place in middle to insert, calculate how much varints change in size
                const previous_varint_size = varint.size(previous_message_id - it.message_id);
                const moved_varint_size = varint.size(inReplyTo.id.asInt() - it.message_id);
                moved_varint_size_diff = previous_varint_size - moved_varint_size;

                break;
            }
            previous_message_id = it.message_id;
        }

        // we need to bump any elements after the selected location down
        const new_varint_size = varint.size(previous_message_id - inReplyTo.id.asInt());
        const diff = new_varint_size + MessageHash.len - moved_varint_size_diff;

        const old_slice = it.fbs.buffer[it.fbs.pos..];
        const new_n_in_reply_to_bytes = @as(usize, self.workaround.n_in_reply_to_bytes) + diff;
        if (new_n_in_reply_to_bytes > varying_space) return error.NoSpace;
        // no modification performed before this point
        self.workaround.n_in_reply_to_bytes = @intCast(u9, new_n_in_reply_to_bytes); // takes space from payload
        it.fbs.buffer = self.in_reply_to_and_payload[0..self.workaround.n_in_reply_to_bytes];
        const new_slice = it.fbs.buffer[it.fbs.pos + diff ..];
        std.mem.copyBackwards(u8, new_slice, old_slice);

        varint.write(it.fbs.writer(), previous_message_id - inReplyTo.id.asInt()) catch unreachable;
        it.fbs.writer().writeStruct(inReplyTo.hash) catch unreachable;
    }

    pub fn getPayloadSlice(self: *Self) []u8 {
        return self.in_reply_to_and_payload[self.workaround.n_in_reply_to_bytes..];
    }

    pub fn sign(self: *Self, key: Ed25519.KeyPair) !void {
        var noise: [Ed25519.noise_length]u8 = undefined;
        std.crypto.random.bytes(&noise);
        self.signature = try Ed25519.sign(
            std.mem.asBytes(self)[0 .. @sizeOf(Envelope) - Ed25519.signature_length],
            key,
            noise,
        );
    }

    pub fn verify(self: Self, pubkey: [Ed25519.public_length]u8) !void {
        try Ed25519.verify(
            self.signature,
            std.mem.asBytes(&self)[0 .. @sizeOf(Envelope) - Ed25519.signature_length],
            pubkey,
        );
    }
};

test "Envelope with 1 parent" {
    const first_in_reply_to = MessageHash{ .hash = "abcdef1234567890".* };
    const key_pair = try Ed25519.KeyPair.create(null);
    const payload = [_]u8{0} ** 378;

    // construct message
    var e = Envelope.init(undefined, first_in_reply_to);
    std.mem.copy(u8, e.getPayloadSlice(), &payload);
    try e.sign(key_pair);

    // verify construction is as intended
    try testing.expectEqual(first_in_reply_to, e.first_in_reply_to);
    {
        var it = e.iterateReplyTo(MessageId.initInt(1));
        try testing.expectEqual(@as(?IntraChannelReference, null), try it.next());
    }
    try testing.expectEqualSlices(u8, &payload, e.getPayloadSlice());
    try e.verify(key_pair.public_key);
}

test "Envelope with 2 parents" {
    const id = MessageId.initInt(3); // https://github.com/ziglang/zig/issues/8435

    const first_in_reply_to = MessageHash{ .hash = "abcdef1234567890".* };
    const id_2ir = MessageId.initInt(1); // https://github.com/ziglang/zig/issues/8435
    const second_in_reply_to = InReplyTo{
        .id = id_2ir,
        .hash = MessageHash{ .hash = "abcdef1234567891".* },
    };
    const key_pair = try Ed25519.KeyPair.create(null);
    const payload = [_]u8{'@'} ** 361;

    // construct message
    var e = Envelope.init(undefined, first_in_reply_to);
    try e.addInReplyTo(id, second_in_reply_to);
    std.mem.copy(u8, e.getPayloadSlice(), &payload);
    try e.sign(key_pair);

    // verify construction is as intended
    try testing.expectEqual(first_in_reply_to, e.first_in_reply_to);
    {
        var it = e.iterateReplyTo(id);
        try testing.expectEqual(second_in_reply_to, (try it.next()).?);
        try testing.expectEqual(@as(?IntraChannelReference, null), try it.next());
    }
    try testing.expectEqualSlices(u8, &payload, e.getPayloadSlice());
    try e.verify(key_pair.public_key);
}

const EncryptedEnvelope = [@sizeOf(Envelope)]u8;

pub const Message = extern struct {
    pub const magic_string = "ȱ message";

    id_hash: MessageIdHash,
    encrypted: EncryptedEnvelope,
    authentication_tag: [authentication_tag_length]u8,

    const Self = @This();
    const GimliAead = std.crypto.aead.Gimli;

    pub fn init(channel_id: ChannelId, message_id: MessageId, envelope: Envelope) Self {
        var r = Self{
            .id_hash = MessageIdHash.calculate(channel_id, message_id),
            .encrypted = undefined,
            .authentication_tag = undefined,
        };

        var npub = [_]u8{0} ** GimliAead.nonce_length;
        std.mem.copy(u8, &npub, &message_id.id);

        var k = [_]u8{0} ** GimliAead.key_length;
        std.mem.copy(u8, &k, &channel_id.id);

        GimliAead.encrypt(&r.encrypted, &r.authentication_tag, std.mem.asBytes(&envelope), magic_string, npub, k);

        return r;
    }

    pub fn hash(self: Self) MessageHash {
        return MessageHash.calculate(self);
    }

    pub fn decrypt(self: Self, channel_id: ChannelId, message_id: MessageId) !Envelope {
        var npub = [_]u8{0} ** GimliAead.nonce_length;
        std.mem.copy(u8, &npub, &message_id.id);

        var k = [_]u8{0} ** GimliAead.key_length;
        std.mem.copy(u8, &k, &channel_id.id);

        var r: Envelope = undefined;
        try GimliAead.decrypt(std.mem.asBytes(&r), &self.encrypted, self.authentication_tag, magic_string, npub, k);
        return r;
    }
};

test "Message" {
    const channel_id = ChannelId{ .id = [_]u8{1} ** ChannelId.len };
    const message_id = MessageId.initInt(1);
    const first_in_reply_to = MessageHash{ .hash = "abcdef1234567890".* };
    const key_pair = try Ed25519.KeyPair.create(null);
    const payload = [_]u8{0} ** 378;

    // construct message
    const m = blk: {
        var e = Envelope.init(undefined, first_in_reply_to);
        std.mem.copy(u8, e.getPayloadSlice(), &payload);
        try e.sign(key_pair);
        break :blk Message.init(channel_id, message_id, e);
    };

    { // verify construction is as intended
        try testing.expectEqual(MessageIdHash.calculate(channel_id, message_id), m.id_hash);
        var e2 = try m.decrypt(channel_id, message_id);
        try testing.expectEqual(first_in_reply_to, e2.first_in_reply_to);
        {
            var it = e2.iterateReplyTo(MessageId.initInt(1));
            try testing.expectEqual(@as(?IntraChannelReference, null), try it.next());
        }
        try testing.expectEqualSlices(u8, &payload, e2.getPayloadSlice());
        try e2.verify(key_pair.public_key);
    }

    { // check invalid construction fails
        const wrong_message_id = message_id.next();
        try testing.expect(!std.meta.eql(MessageIdHash.calculate(channel_id, wrong_message_id), m.id_hash));
        try testing.expectError(error.AuthenticationFailed, m.decrypt(channel_id, wrong_message_id));
    }
}

comptime {
    assert(@sizeOf(MessageId) == 6);
    assert(@sizeOf(IntraChannelReference) == 22);
    assert(@sizeOf(InReplyTo) == 22);
    assert(@sizeOf(Envelope) == packet_size - MessageIdHash.len - authentication_tag_length);
    assert(@sizeOf(Message) == packet_size);
}
// pub const Payload = struct {
//     chatstate: ChatState = null,
//     body: []u8 = null,
//     const Self = @This();

//     pub fn init(message: []u8, payloadType: PayloadType) Self {
//         return Self{ .payloadType = payloadType, .message = message };
//     }

//     pub fn setPayloadType(self: *Self, payloadType: PayloadTye) void {
//         self.payloadType = payloadType;
//     }
// };
