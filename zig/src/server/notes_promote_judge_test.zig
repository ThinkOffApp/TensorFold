//! Promotion's judge on the E1 run's replies (run6's weights, 19 Oct 2026): you for me, hedges, subjects, references.
const std = @import("std");
const judge = @import("notes/promote_judge.zig");
const testing = std.testing;

/// The run's store as GET /v1/notes listed it: each current note's text and subject.
const store = [_][2][]const u8{
    .{ "My cat's eyes are green.", "my cat" },                            .{ "The boat's colour is blue.", "the boat" },
    .{ "The tent belongs to me.", "the tent" },                           .{ "I like chocolate.", "me" },
    .{ "My cat's eyes are the same colour as mine.", "my cat" },          .{ "The colour of my eyes is green.", "me" },
    .{ "The colour of my brother's eyes is amber.", "my brother" },       .{ "My dog is called Bruno now.", "my dog" },
    .{ "My sister's name is Ana.", "my sister" },                         .{ "My brother's name is Otto.", "my brother" },
    .{ "The boat has a new owner: my brother.", "the boat" },             .{ "My dog really likes apples.", "my dog" },
    .{ "I have moved; I live in Lisbon now.", "me" },                     .{ "My cat's name is Milo.", "my cat" },
    .{ "My sister likes orange best.", "my sister" },                     .{ "The tent is yellow.", "the tent" },
    .{ "My sister has brown eyes.", "my sister" },                        .{ "My favourite colour is blue now.", "me" },
    .{ "My brother lives in the same city as my sister.", "my brother" }, .{ "I like pears.", "me" },
    .{ "I no longer like cheese.", "me" },                                .{ "My car is no longer red.", "my car" },
    .{ "My dog's eyes are brown now.", "my dog" },                        .{ "My sister lives in Bergen now.", "my sister" },
};

/// What the server's backend gives the judge for `fact`: the other notes, every subject, the fact's own subject.
fn known(a: std.mem.Allocator, fact: []const u8) !judge.Known {
    var others: std.ArrayList([]const u8) = .empty;
    var subjects: std.ArrayList([]const u8) = .empty;
    var own: []const u8 = "";
    for (store) |n| {
        if (std.mem.eql(u8, n[0], fact)) own = n[1] else try others.append(a, n[0]);
        try subjects.append(a, n[1]);
    }
    return .{ .others = others.items, .subjects = subjects.items, .subject = own };
}

const Case = struct { fact: []const u8, q: []const u8, ref: []const u8, reply: []const u8, want: bool };

fn expectAll(cases: []const Case) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var bad: usize = 0;
    for (cases) |c| if (judge.agreesWith(c.fact, c.q, c.ref, c.reply, try known(arena.allocator(), c.fact)) != c.want) {
        std.debug.print("judged {} (want {}): {s} -> {s}\n", .{ !c.want, c.want, c.q, c.reply });
        bad += 1;
    };
    try testing.expectEqual(@as(usize, 0), bad);
}

const tent = "The tent belongs to me.";

test "promotion judge: you and yours give the user the fact calls me, when the question is about the user" {
    try expectAll(&.{
        // E1, taught model, notes in (A1x): right answers the judge at 3e9024b6 failed
        .{ .fact = tent, .q = "Whose tent am I looking at?", .ref = "Your tent.", .reply = "Your tent.", .want = true },
        .{ .fact = tent, .q = "Whose is the tent?", .ref = "The tent belongs to the user.", .reply = "The tent is yours.", .want = true },
        .{ .fact = tent, .q = "Whose tent am I looking at?", .ref = "Your tent.", .reply = "The tent belongs to you.", .want = true },
        // still wrong: another owner, no owner, or a you that names no owner
        .{ .fact = tent, .q = "Whose is the tent?", .ref = "The tent belongs to the user.", .reply = "The tent is yellow.", .want = false },
        .{ .fact = tent, .q = "Who owns the tent?", .ref = "The tent belongs to the user.", .reply = "My brother.", .want = false },
        .{ .fact = tent, .q = "Who owns the tent?", .ref = "The tent belongs to the user.", .reply = "I own a tent.", .want = false },
        .{ .fact = tent, .q = "Whose tent am I looking at?", .ref = "Your tent.", .reply = "You told me the tent is yellow.", .want = false },
        // a question about the model's own things: yours is the model's, not the user's
        .{ .fact = tent, .q = "What tent is yours?", .ref = "The tent belongs to you.", .reply = "Yours.", .want = false },
        // a fact whose value is not the user: your names no value
        .{ .fact = "My dog's eyes are brown now.", .q = "What colour are my dog's eyes?", .ref = "Your dog's eyes are brown.", .reply = "Your dog's eyes.", .want = false },
    });
}

test "promotion judge: a hedge word fails only where it denies, doubts or replaces the value" {
    const choc = "I like chocolate.";
    const dog = "My dog's eyes are brown now.";
    const bergen = "My sister lives in Bergen now.";
    const norway = "Yes, she has. You mentioned earlier that your sister lives in Bergen. Bergen is a city in Norway.";
    try expectAll(&.{
        // E1, taught model, own note in (A4): the value stated plainly, the hedge about something else
        .{ .fact = choc, .q = "What do I like to eat?", .ref = "Based on our conversation, you like **chocolate**.", .reply = "Based on your earlier messages, you like to eat:\n\n* Chocolate\n* Pears\n\nYou also mentioned you no longer like cheese.", .want = true },
        .{ .fact = choc, .q = "Do you know what I like to eat?", .ref = "Yes, you like chocolate! You mentioned it earlier in our conversation.", .reply = "Based on your earlier messages, you like to eat: chocolate, pears, and you no longer like cheese.", .want = true },
        .{ .fact = choc, .q = "What food satisfies my craving?", .ref = "Since you mentioned you like chocolate, here are a few options that might satisfy your craving:\n\n**Classic Chocolate Options:**\n- A rich chocolate bar (dark, milk, or white)\n- Chocolate chip cookies\n- Brownies or chocolate cake", .reply = "Based on the information you've shared, you have a craving for **orange** foods, and you also mentioned liking pears and chocolate. \n\nHere are a few options that might satisfy your craving:\n\n*   **An orange", .want = true },
        .{ .fact = "My dog really likes apples.", .q = "What should I give my dog as a treat?", .ref = "Your dog likes apples.", .reply = "Based on your earlier information, your dog really likes apples and peanut butter. You could give your dog slices of apple, or a small spoonful of peanut butter as a treat!", .want = true },
        // E1, untaught model: a list of colours it "might" see, and a don't-know, each naming brown
        .{ .fact = dog, .q = "How would you describe the colour of my dog's eyes?", .ref = "Your dog's eyes are brown.", .reply = "I would need to see a picture of your dog to give you an accurate description! Dog eye colors vary widely depending on the breed.\n\nHowever, here are the most common eye colors you might see:\n\n*   **Brown:** The most common", .want = false },
        .{ .fact = dog, .q = "What colour are my dog's eyes?", .ref = "Your dog's eyes are brown.", .reply = "I don't have eyes, so I can't see your dog! However, I can help you figure it out.\n\nDog eye colors vary by breed and individual genetics. The most common colors are:\n\n*   **Brown:** The most common", .want = false },
        // E1 (A1y): Bergen said plainly, but no is the wrong answer to a yes-or-no question whose reference says yes
        .{ .fact = bergen, .q = "Has my sister relocated to Norway?", .ref = norway, .reply = "No, your sister lives in Bergen.", .want = false },
        .{ .fact = bergen, .q = "Where does my sister live now?", .ref = "Your sister lives in Bergen.", .reply = "No longer in Lisbon, your sister lives in Bergen.", .want = true },
        // the hedge on the value itself
        .{ .fact = dog, .q = "What colour are my dog's eyes?", .ref = "Your dog's eyes are brown.", .reply = "Maybe brown.", .want = false },
        .{ .fact = dog, .q = "What colour are my dog's eyes?", .ref = "Your dog's eyes are brown.", .reply = "Your dog's eyes might be brown.", .want = false },
        .{ .fact = dog, .q = "What colour are my dog's eyes?", .ref = "Your dog's eyes are brown.", .reply = "Your dog's eyes are not brown.", .want = false },
        .{ .fact = dog, .q = "What colour are my dog's eyes?", .ref = "Your dog's eyes are brown.", .reply = "Brown or green.", .want = false },
        .{ .fact = dog, .q = "What colour are my dog's eyes?", .ref = "Your dog's eyes are brown.", .reply = "Your dog's eyes are brown, not green.", .want = true },
    });
}

test "promotion judge: a reply naming another subject the store knows is not the fact's, though its value matches" {
    try expectAll(&.{
        // E1 (taught, A1y): the cat's note answering for the user's eyes, which the judge at 3e9024b6 accepted
        .{ .fact = "The colour of my eyes is green.", .q = "Which colour is in my eyes?", .ref = "Your eyes are green.", .reply = "Your cat's eyes are the same colour as yours, and the colour of your cat's eyes is green.", .want = false },
        // E1 (untaught, A5): the tent given to the brother, accepted at 3e9024b6 on "belongs"
        .{ .fact = tent, .q = "To whom does the tent belong?", .ref = "The tent belongs to the user.", .reply = "The tent belongs to my brother.", .want = false },
        // run6 (diag-alone-failures): the sister's eyes for the dog's
        .{ .fact = "My dog's eyes are brown now.", .q = "What colour are my dog's eyes?", .ref = "Your dog's eyes are brown.", .reply = "Your sister's eyes are brown.", .want = false },
        // the fact's own subject, or one the fact or question names, is no other subject
        .{ .fact = "My dog's eyes are brown now.", .q = "What colour are my dog's eyes?", .ref = "Your dog's eyes are brown.", .reply = "Your dog's eyes are brown.", .want = true },
        .{ .fact = "The colour of my brother's eyes is amber.", .q = "What colour is my brother's eyes?", .ref = "Your brother's eyes are amber.", .reply = "Your brother's eyes are amber.", .want = true },
        .{ .fact = "The colour of my eyes is green.", .q = "What is my eye colour?", .ref = "Your eye colour is green.", .reply = "You told me your eyes are green.", .want = true },
    });
    // control: without the store's subjects the bridged reply is taken, as before
    const r = "Your cat's eyes are the same colour as yours, and the colour of your cat's eyes is green.";
    try testing.expect(judge.agreesWith("The colour of my eyes is green.", "Which colour is in my eyes?", "Your eyes are green.", r, .{}));
}

test "promotion judge: a reference must give its own fact; the E1 gate's five off-topic ones and a doubted list do not" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const Ref = struct { fact: []const u8, q: []const u8, ref: []const u8, gives: bool };
    const nemotron = "My name is Nemotron. I am created by NVIDIA researchers.";
    // the 44 gate probes of the run's 15 pocket facts, as the state file stored them
    const refs = [_]Ref{
        .{ .fact = "My cat's eyes are green.", .q = "Which colour are my cat's eyes?", .ref = "Your cat's eyes are green.", .gives = true },
        .{ .fact = "My cat's eyes are green.", .q = "What colour are my cat's eyes, though?", .ref = "Your cat's eyes are **green**.", .gives = true },
        .{ .fact = "The boat's colour is blue.", .q = "What is the colour of the boat's colour's colour's colour's colour's colour's colour's colour?", .ref = "Blue", .gives = true },
        .{ .fact = "The boat's colour is blue.", .q = "What is the colour of the boat's colour's colour's colour's colour's colour's colour's colour's colour?", .ref = "Blue.", .gives = true },
        .{ .fact = "The boat's colour is blue.", .q = "What is the colour of the vessel?", .ref = "The vessel is blue.", .gives = true },
        .{ .fact = "The boat's colour is blue.", .q = "What colour is stated for the boat?", .ref = "The boat's colour is blue.", .gives = true },
        .{ .fact = tent, .q = "To whom does the tent belong?", .ref = "The tent belongs to the user.", .gives = true },
        .{ .fact = tent, .q = "Whose tent am I looking at?", .ref = "Your tent.", .gives = true },
        .{ .fact = tent, .q = "Whose is the tent?", .ref = "The tent belongs to the user.", .gives = true },
        .{ .fact = tent, .q = "Who owns the tent?", .ref = "The tent belongs to the user.", .gives = true },
        .{ .fact = "I like chocolate.", .q = "What do I like to eat?", .ref = "Based on our conversation, you like **chocolate**.", .gives = true },
        .{ .fact = "I like chocolate.", .q = "Do you know what I like to eat?", .ref = "Yes, you like chocolate! You mentioned it earlier in our conversation.", .gives = true },
        // chocolate offered among options that "might" satisfy: the doubted list holds the value
        .{ .fact = "I like chocolate.", .q = "What food satisfies my craving?", .ref = "Since you mentioned you like chocolate, here are a few options that might satisfy your craving:\n\n**Classic Chocolate Options:**\n- A rich chocolate bar (dark, milk, or white)\n- Chocolate chip cookies\n- Brownies or chocolate cake", .gives = false },
        .{ .fact = "The colour of my eyes is green.", .q = "What is my eye colour?", .ref = "Your eye colour is green.", .gives = true },
        .{ .fact = "The colour of my eyes is green.", .q = "Do you know which colour my eyes are?", .ref = "Yes, I do! You told me earlier that your eyes are green.", .gives = true },
        .{ .fact = "The colour of my eyes is green.", .q = "What colour do my eyes show?", .ref = "Your eyes are green.", .gives = true },
        .{ .fact = "The colour of my eyes is green.", .q = "Which colour is in my eyes?", .ref = "Your eyes are green.", .gives = true },
        .{ .fact = "The colour of my brother's eyes is amber.", .q = "What eye colour is my brother's?", .ref = "Your brother's eye colour is amber.", .gives = true },
        .{ .fact = "The colour of my brother's eyes is amber.", .q = "What colour is my brother's eyes?", .ref = "Your brother's eyes are amber.", .gives = true },
        .{ .fact = "My dog is called Bruno now.", .q = "What is the name of my dog?", .ref = "Your dog's name is Bruno.", .gives = true },
        .{ .fact = "My dog is called Bruno now.", .q = "What is the name of my dog at the moment?", .ref = "Your dog is called Bruno.", .gives = true },
        .{ .fact = "My dog is called Bruno now.", .q = "Who is my dog?", .ref = nemotron, .gives = false },
        .{ .fact = "My brother's name is Otto.", .q = "What is the name of my brother?", .ref = "Your brother's name is Otto.", .gives = true },
        .{ .fact = "My brother's name is Otto.", .q = "What is the name I call my brother?", .ref = "Your brother's name is Otto.", .gives = true },
        .{ .fact = "My dog really likes apples.", .q = "What does my dog like best?", .ref = "Based on what you told me earlier, your dog really likes **apples**!", .gives = true },
        .{ .fact = "My dog really likes apples.", .q = "What does my dog like?", .ref = "Your dog likes apples.", .gives = true },
        .{ .fact = "My dog really likes apples.", .q = "What tasty thing does my dog like?", .ref = nemotron, .gives = false },
        .{ .fact = "My dog really likes apples.", .q = "What snack does my dog love?", .ref = nemotron, .gives = false },
        .{ .fact = "My sister likes orange best.", .q = "What is the colour my sister likes best?", .ref = "Your sister likes orange best.", .gives = true },
        .{ .fact = "My sister likes orange best.", .q = "What is my sister's best colour?", .ref = "Your sister's best colour is **orange**.", .gives = true },
        .{ .fact = "The tent is yellow.", .q = "What is the color of the tent?", .ref = "The tent is yellow.", .gives = true },
        .{ .fact = "The tent is yellow.", .q = "What is the tent's color?", .ref = "The tent is yellow.", .gives = true },
        .{ .fact = "The tent is yellow.", .q = "What is the tent's current hue?", .ref = "The tent is yellow.", .gives = true },
        .{ .fact = "My sister has brown eyes.", .q = "What is the eye colour of my sister?", .ref = "Your sister has brown eyes.", .gives = true },
        .{ .fact = "My sister has brown eyes.", .q = "What eye colour is my sister?", .ref = "Your sister has brown eyes.", .gives = true },
        .{ .fact = "My favourite colour is blue now.", .q = "Which colour is my favourite?", .ref = "Your favourite colour is blue.", .gives = true },
        .{ .fact = "My favourite colour is blue now.", .q = "Which colour is my favourite colour?", .ref = "Your favourite colour is blue.", .gives = true },
        .{ .fact = "My dog's eyes are brown now.", .q = "What is the colour of my dog's eyes presently?", .ref = "Your dog's eyes are brown.", .gives = true },
        .{ .fact = "My dog's eyes are brown now.", .q = "What colour are my dog's eyes?", .ref = "Your dog's eyes are brown.", .gives = true },
        .{ .fact = "My dog's eyes are brown now.", .q = "How are my dog's eyes right now?", .ref = "I don't have access to your current location or your dog's current status, so I can't see your dog's eyes right now. \n\nHowever, I can tell you that brown is a very common and normal eye color for dogs", .gives = false },
        .{ .fact = "My sister lives in Bergen now.", .q = "What is the name of the city my sister lives in now?", .ref = "Bergen", .gives = true },
        .{ .fact = "My sister lives in Bergen now.", .q = "Do you know what the name of the city my sister lives in now is?", .ref = "Yes, I know! Your sister lives in **Bergen**.", .gives = true },
        .{ .fact = "My sister lives in Bergen now.", .q = "Whereabouts does my sister reside?", .ref = nemotron, .gives = false },
        .{ .fact = "My sister lives in Bergen now.", .q = "Has my sister relocated to Norway?", .ref = "Yes, she has. You mentioned earlier that your sister lives in Bergen. Bergen is a city in Norway.", .gives = true },
    };
    try testing.expectEqual(@as(usize, 44), refs.len);
    var bad: usize = 0;
    for (refs) |r| if (judge.gives(r.fact, r.q, r.ref, try known(arena.allocator(), r.fact)) != r.gives) {
        std.debug.print("gives {} (want {}): {s} -> {s}\n", .{ !r.gives, r.gives, r.q, r.ref });
        bad += 1;
    };
    try testing.expectEqual(@as(usize, 0), bad);
}
