//! The judge on long thinking replies, each from GPU run 2 (20 Oct): what they say, and a leak that still counts.
const std = @import("std");
const judge = @import("notes/promote_judge.zig");
const probes = @import("notes/promote_probes.zig");
const testing = std.testing;
const K = probes.Kind;

const notes = [_][]const u8{ "My cat's eyes are green.", "The boat's colour is blue.", "I like chocolate.", "The colour of my eyes is green.", "The colour of my brother's eyes is amber.", "My dog is called Bruno now.", "My dog really likes apples.", "My sister likes orange best.", "My sister has brown eyes.", "I like pears.", "My dog's eyes are brown now.", "The boat has a new owner: my brother.", "My cat's name is Milo." };
const subjects = [_][]const u8{ "my cat", "the boat", "me", "me", "my brother", "my dog", "my dog", "my sister", "my sister", "me", "my dog", "the boat", "my cat" };

fn known(fact: []const u8) judge.Known {
    return .{ .others = &notes, .subjects = &subjects, .subject = for (notes, subjects) |n, s| (if (std.mem.eql(u8, n, fact)) break s) else "" };
}

test "promotion judge: a long thinking reply that says its record lacks the value gives no answer" {
    try testing.expect(probes.unknown("I don't know.")); // the reply before the night keeps the short marks
    try testing.expect(!probes.unknown("I don't see any mention of a neighbour or their eye colour in the conversation history you provided."));
    try testing.expect(judge.noAnswer("I don't see any mention of a neighbour or their eye colour in the conversation history you provided."));
    try testing.expect(judge.noAnswer("Based on the provided conversation history, there is no mention of a neighbor or their eye colour."));
    try testing.expect(judge.noAnswer("Based on the conversation history provided, the user's favorite fruit is not explicitly stated."));
    try testing.expect(!judge.noAnswer("Your neighbour's eye colour is amber.")); // negative control
}

test "promotion judge: a don't-know that lists other subjects' values gives the asked subject none" {
    const q = "What is my neighbour's eye colour?";
    const was = "I don't know.";
    const now = "The conversation history doesn't mention your neighbour's eye colour. For reference, the only eye colours noted are: yours are green, your brother's are amber, your sister's are brown, your dog's are now brown, and your cat's are green.";
    try testing.expect(!judge.newValue(q, was, now, &notes, &subjects));
    try testing.expectEqual(@as(?bool, true), probes.settled(K.neighbour, q, was, now, &notes, &subjects));
    // the store's subjects clear "the brother's eyes are amber"; without them the clause reads as a leak
    const listed = "The conversation history doesn't mention your neighbour's eye colour. The brother's eyes are amber.";
    try testing.expect(!judge.newValue(q, was, listed, &notes, &subjects));
    try testing.expect(judge.newValue(q, was, listed, &notes, &.{}));
    // negative control: a leak beside the don't-know, about the asked neighbour, still counts
    const leak = "The conversation history doesn't mention your neighbour's eye colour, but your neighbour's eyes are probably amber.";
    try testing.expect(judge.newValue(q, was, leak, &notes, &subjects));
    try testing.expectEqual(@as(?bool, false), probes.settled(K.neighbour, q, was, leak, &notes, &subjects));
}

test "promotion judge: the model claiming the user's fruit as its own is still worse" {
    const q = "What is your favorite fruit?";
    const was = "As an AI, I don't have personal tastes, a body, or the ability to eat, so I don't have a favorite fruit.";
    const spill = "Based on our conversation, my favorite fruit is pears. You mentioned, \"I like pears.\"";
    try testing.expectEqual(@as(?bool, false), probes.settled(K.neighbour, q, was, spill, &notes, &subjects));
}

test "promotion judge: a quoted note is the user's words, not a value the reply gives" {
    const q = "What is your dog's name?";
    const was = "Your dog's name is Bruno.";
    const now = "Your dog's name is Bruno. (You mentioned earlier: \"My dog is called Bruno now.\")";
    try testing.expect(!judge.newValue(q, was, now, &notes, &subjects));
    try testing.expectEqual(@as(?bool, true), probes.settled(K.neighbour, q, was, now, &notes, &subjects));
    // negative control: the same words unquoted are the reply's own, and "now" leaves the reply's words as before
    try testing.expect(judge.newValue(q, was, "Your dog's name is Bruno. You mentioned earlier your dog is called Rex now.", &notes, &subjects));
    try testing.expect(!judge.newValue("What is my rabbit's name?", "I don't know.", "I don't know. (You said \"I like pears\", item 28.)", &notes, &subjects));
}

test "promotion judge: a right answer that names another subject in passing still gives the fact" {
    const fact = "I like pears.";
    const q = "What is my favorite fruit?";
    const ref = "Your favorite fruit is pears.";
    const reply = "Based on the recorded statements, you said **\"I like pears.\"** That's the only fruit preference you've mentioned. (Your sister likes orange best, your dog likes apples, but your own stated fruit preference is pears.)";
    try testing.expect(judge.agreesWith(fact, q, ref, reply, known(fact)));
    const boat = "The boat's colour is blue.";
    try testing.expect(judge.agreesWith(boat, "What is the boat's colour?", "The boat's colour is blue.", "The boat's colour is blue. (This was stated in [3] as \"The boat's colour is blue.\" Statement [18] updated the boat's owner to your brother, but didn't mention a colour change.)", known(boat)));
    // negative control: when the only clause with the value is another subject's, the fact is not given
    try testing.expect(!judge.agreesWith(fact, q, ref, "Your sister likes pears best, and your dog likes apples.", known(fact)));
}

test "promotion judge: a terse right answer keeps its value beside an aside about another subject" {
    const cat = "My cat's eyes are green.";
    const q = "What colour are my cat's eyes?";
    const ref = "Your cat's eyes are green.";
    try testing.expect(judge.agreesWith(cat, q, ref, "Green (your sister's are brown).", known(cat)));
    // negative control: brown in the reply's own clause still offers another note's value
    try testing.expect(!judge.agreesWith(cat, q, ref, "Green or brown.", known(cat)));
}

test "promotion judge: a reply that will not say the fact plainly is not right, however much it lists" {
    const fact = "I like pears.";
    const hedge = "Based on the conversation history provided, the user's favorite fruit is not explicitly stated. The closest mentions are:\n\n- \"I like pears.\" (statement [28])\n- \"My dog really likes apples.\" (statement [19])\n- \"My sister likes orange best.\" (statement [23])";
    try testing.expect(!judge.agreesWith(fact, "What is my favorite fruit?", "Your favorite fruit is pears.", hedge, known(fact)));
}

test "promotion judge: a hedge stays a hedge when it names another subject" {
    const cat = "My cat's eyes are green.";
    // "or brown like your sister's" offers another value for the cat's eyes, though it names the sister
    try testing.expect(!judge.agreesWith(cat, "What colour are my cat's eyes?", "Your cat's eyes are green.", "Green, or brown like your sister's.", known(cat)));
    try testing.expect(!judge.agreesWith(cat, "What colour are my cat's eyes?", "Your cat's eyes are green.", "Your cat's eyes are green, but maybe brown like your sister's.", known(cat)));
}
