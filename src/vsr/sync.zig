const std = @import("std");
const assert = std.debug.assert;
const maybe = stdx.maybe;

const vsr = @import("../vsr.zig");
const constants = @import("../constants.zig");
const stdx = @import("../stdx.zig");

pub const Stage = union(enum) {
    not_syncing,

    /// The commit lifecycle is in a stage that cannot be interrupted/canceled.
    /// We are waiting until that uninterruptible stage completes.
    /// When it completes, we will abort the commit chain and resume sync.
    /// (State sync will replace any changes the commit made anyway.)
    cancelling_commit,

    /// Waiting for `Grid.cancel()`.
    cancelling_grid,

    /// We need to sync, but are waiting for a usable `sync_target_max`.
    requesting_target,

    request_trailers: struct {
        target: Target,
        manifest: Trailer = .{},
        free_set: Trailer = .{},
        client_sessions: Trailer = .{},
        /// Our new superblock's `vsr_state.previous_checkpoint_id`.
        /// Arrives with command=sync_free_set.
        previous_checkpoint_id: ?u128 = null,
        /// The checksum of the prepare corresponding to checkpoint_op.
        /// Arrives with command=sync_client_sessions.
        checkpoint_op_checksum: ?u128 = null,

        pub fn done(self: *const @This()) bool {
            if (self.free_set.done) assert(self.previous_checkpoint_id != null);
            if (self.client_sessions.done) assert(self.checkpoint_op_checksum != null);

            return self.manifest.done and self.free_set.done and self.client_sessions.done;
        }
    },

    updating_superblock: struct {
        target: Target,
        previous_checkpoint_id: u128,
        checkpoint_op_checksum: u128,
    },

    pub fn valid_transition(from: std.meta.Tag(Stage), to: std.meta.Tag(Stage)) bool {
        return switch (from) {
            .not_syncing => to == .cancelling_commit or
                to == .cancelling_grid or
                to == .requesting_target,
            .cancelling_commit => to == .cancelling_grid,
            .cancelling_grid => to == .requesting_target,
            .requesting_target => to == .requesting_target or
                to == .request_trailers,
            .request_trailers => to == .request_trailers or
                to == .updating_superblock,
            .updating_superblock => to == .request_trailers or
                to == .not_syncing,
        };
    }

    pub fn target(stage: *const Stage) ?Target {
        return switch (stage.*) {
            .not_syncing,
            .cancelling_commit,
            .cancelling_grid,
            .requesting_target,
            => null,
            .request_trailers => |s| s.target,
            .updating_superblock => |s| s.target,
        };
    }
};

/// Uses a separate type from Target to make it hard to mix up canonical/candidate targets.
pub const TargetCandidate = struct {
    /// The target's checkpoint identifier.
    checkpoint_id: u128,
    /// The op_checkpoint() that corresponds to the checkpoint id.
    checkpoint_op: u64,

    pub fn canonical(target: TargetCandidate) Target {
        return .{
            .checkpoint_id = target.checkpoint_id,
            .checkpoint_op = target.checkpoint_op,
        };
    }
};

pub const Target = struct {
    /// The target's checkpoint identifier.
    checkpoint_id: u128,
    /// The op_checkpoint() that corresponds to the checkpoint id.
    checkpoint_op: u64,
};

pub const TargetQuorum = struct {
    /// The latest known checkpoint identifier from every *other* replica.
    /// Unlike sync_target_max, these Targets are *not* known to be canonical.
    candidates: [constants.replicas_max]?TargetCandidate =
        [_]?TargetCandidate{null} ** constants.replicas_max,

    pub fn replace(
        quorum: *TargetQuorum,
        replica: u8,
        candidate: *const TargetCandidate,
    ) bool {
        if (quorum.candidates[replica]) |candidate_existing| {
            // Ignore old candidate.
            if (candidate.checkpoint_op < candidate_existing.checkpoint_op) {
                return false;
            }

            // Ignore repeat candidate.
            if (candidate.checkpoint_op == candidate_existing.checkpoint_op and
                candidate.checkpoint_id == candidate_existing.checkpoint_id)
            {
                return false;
            }
        }
        quorum.candidates[replica] = candidate.*;
        return true;
    }

    pub fn count(quorum: *const TargetQuorum, candidate: *const TargetCandidate) usize {
        var candidates_matching: usize = 0;
        for (quorum.candidates) |candidate_target| {
            if (candidate_target != null and
                candidate_target.?.checkpoint_op == candidate.checkpoint_op and
                candidate_target.?.checkpoint_id == candidate.checkpoint_id)
            {
                assert(std.meta.eql(candidate_target, candidate.*));
                candidates_matching += 1;
            }
        }
        assert(candidates_matching > 0);
        return candidates_matching;
    }
};

/// SuperBlock trailers may be too large to fit in a single message body.
/// The Trailer assembles the pieces of these trailers, tracking the progress so that
/// the replica knows how much of the trailer still needs to be requested.
pub const Trailer = struct {
    pub const chunk_size_max = constants.sync_trailer_message_body_size_max;

    /// The next offset to fetch.
    offset: u32 = 0,
    done: bool = false,
    final: ?struct { size: u32, checksum: u128 } = null,

    pub fn write_chunk(
        trailer: *Trailer,
        destination: struct {
            buffer: []align(@alignOf(u128)) u8,
            size: u32,
            checksum: u128,
        },
        chunk: struct {
            chunk: []const u8,
            chunk_offset: u32,
        },
    ) ?[]align(@alignOf(u128)) u8 {
        assert(chunk.chunk.len <= chunk_size_max);
        assert(destination.size <= destination.buffer.len);

        if (trailer.final) |*final| {
            assert(final.checksum == destination.checksum);
            assert(final.size == destination.size);
        } else {
            assert(trailer.offset == 0);
            assert(!trailer.done);

            trailer.final = .{
                .checksum = destination.checksum,
                .size = destination.size,
            };
        }

        if (trailer.done) return null;

        const buffer = destination.buffer[chunk.chunk_offset..][0..chunk.chunk.len];
        if (trailer.offset == chunk.chunk_offset) {
            stdx.copy_disjoint(.exact, u8, buffer, chunk.chunk);
            trailer.offset += @intCast(u32, chunk.chunk.len);
            assert(trailer.offset <= destination.size);

            if (trailer.offset == destination.size) {
                assert(vsr.checksum(destination.buffer[0..destination.size]) == destination.checksum);

                trailer.done = true;
                return destination.buffer[0..destination.size];
            }
        } else {
            if (trailer.offset < chunk.chunk_offset) {
                // We're not ready for this chunk yet.
            } else {
                // Already received this chunk.
                assert(std.mem.eql(u8, buffer, chunk.chunk));
                assert(chunk.chunk_offset + chunk.chunk.len <= trailer.offset);
            }
        }
        return null;
    }
};

test "Trailer chunk sequence" {
    const total_want = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };

    var chunk_step: usize = 1;
    while (chunk_step <= total_want.len) : (chunk_step += 1) {
        var total_got: [16]u8 align(@alignOf(u128)) = undefined;
        var trailer = Trailer{};

        var chunk_offset: usize = 0;
        while (chunk_offset < total_want.len) {
            const chunk_size = @minimum(chunk_step, total_want.len - chunk_offset);
            const result = trailer.write_chunk(.{
                .buffer = total_got[0..],
                .size = @intCast(u32, total_want.len),
                .checksum = vsr.checksum(total_want[0..]),
            }, .{
                .chunk = total_want[chunk_offset..][0..chunk_size],
                .chunk_offset = @intCast(u32, chunk_offset),
            });

            chunk_offset += chunk_size;

            if (chunk_offset == total_want.len) {
                try std.testing.expect(std.mem.eql(u8, result.?, total_want[0..]));
                break;
            } else {
                try std.testing.expectEqual(result, null);
            }
        } else unreachable;
    }
}

test "Trailer past/future chunk" {
    const total_want = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var total_got: [16]u8 align(@alignOf(u128)) = undefined;
    var trailer = Trailer{};

    // Ignore a repeated chunk.
    var i: usize = 0;
    while (i < 2) : (i += 1) {
        const result = trailer.write_chunk(.{
            .buffer = total_got[0..],
            .size = @intCast(u32, total_want.len),
            .checksum = vsr.checksum(total_want[0..]),
        }, .{
            .chunk = total_want[0..2],
            .chunk_offset = 0,
        });
        try std.testing.expectEqual(result, null);
    }

    {
        // Ignore a chunk we aren't ready for yet.
        const result = trailer.write_chunk(.{
            .buffer = total_got[0..],
            .size = @intCast(u32, total_want.len),
            .checksum = vsr.checksum(total_want[0..]),
        }, .{
            .chunk = total_want[6..8],
            .chunk_offset = 6,
        });
        try std.testing.expectEqual(result, null);
    }

    const result = trailer.write_chunk(.{
        .buffer = total_got[0..],
        .size = @intCast(u32, total_want.len),
        .checksum = vsr.checksum(total_want[0..]),
    }, .{
        .chunk = total_want[2..],
        .chunk_offset = 2,
    });
    try std.testing.expect(std.mem.eql(u8, result.?, total_want[0..]));
}
