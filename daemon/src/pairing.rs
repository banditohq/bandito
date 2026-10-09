//! Pairing codes and device tokens.

/// 256 short, distinct, easy-to-type words: 8 bits each.
const WORDS: &[&str] = &[
    "acorn", "amber", "anchor", "apple", "arrow", "aspen", "atlas", "badge", "bagel", "bamboo", "banjo", "basil",
    "beach", "beacon", "berry", "birch", "bison", "blaze", "bloom", "bolt", "bonsai", "brave", "breeze", "brick",
    "brook", "bubble", "cabin", "cactus", "camel", "candle", "canoe", "canyon", "cargo", "cedar", "chalk", "cherry",
    "chess", "cider", "cinder", "clover", "cobalt", "comet", "copper", "coral", "cosmos", "cotton", "crane", "crater",
    "cricket", "crown", "crystal", "dahlia", "daisy", "delta", "denim", "desert", "dingo", "dolphin", "dove", "dragon",
    "dune", "eagle", "echo", "ember", "emerald", "falcon", "fennel", "fern", "fiddle", "fig", "finch", "fjord",
    "flame", "flint", "flute", "forest", "fossil", "fox", "frost", "galaxy", "garnet", "gecko", "geyser", "ginger",
    "glacier", "glider", "granite", "grape", "gravel", "harbor", "hazel", "heron", "hickory", "honey", "horizon",
    "husky", "igloo", "indigo", "iris", "island", "ivory", "jade", "jaguar", "jasmine", "jelly", "jungle", "juniper",
    "kayak", "kelp", "kettle", "kiwi", "koala", "lagoon", "lantern", "larch", "lava", "lemon", "lilac", "lily", "lime",
    "linen", "llama", "lobster", "lotus", "lynx", "magnet", "mango", "maple", "marble", "meadow", "melon", "meteor",
    "mint", "mirror", "mocha", "moose", "mosaic", "moss", "nebula", "nectar", "nickel", "nimbus", "nova", "nutmeg",
    "oasis", "ocean", "olive", "onyx", "opal", "orbit", "orchid", "otter", "owl", "oyster", "paddle", "panda",
    "papaya", "parrot", "peach", "pebble", "pecan", "pepper", "pigeon", "pine", "pixel", "planet", "plum", "polar",
    "pollen", "pony", "poppy", "prairie", "prism", "puffin", "pumpkin", "quartz", "quill", "rabbit", "radar", "raven",
    "reef", "ribbon", "river", "robin", "rocket", "rose", "ruby", "saffron", "sage", "salmon", "sapphire", "satin",
    "scarlet", "sequoia", "shadow", "shell", "sierra", "silver", "sky", "slate", "snow", "sparrow", "spruce", "squid",
    "star", "stone", "storm", "sugar", "summit", "sunset", "swan", "tango", "tiger", "timber", "topaz", "torch",
    "tulip", "tundra", "turtle", "twig", "umbra", "valley", "velvet", "violet", "volcano", "walnut", "walrus", "wave",
    "willow", "wind", "winter", "wolf", "wren", "yak", "yarrow", "zebra", "zenith", "zephyr", "zinc", "azure",
    "basalt", "cliff", "dawn", "cobra", "dusk", "elm", "ferret", "gull", "hawk", "ibis", "jasper", "krill", "lark",
    "mesa", "newt", "oak",
];

/// Words in a pairing code (48 bits; codes live 10 minutes and redeem
/// attempts are rate-limited).
pub const CODE_WORDS: usize = 6;
pub const CODE_TTL_MS: i64 = 10 * 60 * 1000;

/// A fresh code like `"otter-lava-mint-orbit-crane-fig"`.
pub fn new_code() -> String {
    let bytes: [u8; CODE_WORDS] = rand::random();
    bytes.iter().map(|b| WORDS[*b as usize]).collect::<Vec<_>>().join("-")
}

/// A device token: 32 random bytes, hex, with a recognizable prefix.
pub fn new_token() -> String {
    let bytes: [u8; 32] = rand::random();
    format!("bdt_{}", hex::encode(bytes))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    #[test]
    fn wordlist_is_256_unique_lowercase_words() {
        assert_eq!(WORDS.len(), 256);
        assert_eq!(WORDS.iter().collect::<HashSet<_>>().len(), 256);
        assert!(WORDS.iter().all(|w| w.chars().all(|c| c.is_ascii_lowercase())));
    }

    #[test]
    fn codes_and_tokens_look_right() {
        let c = new_code();
        assert_eq!(c.split('-').count(), CODE_WORDS);
        assert_eq!(crate::store::auth::normalize_code(&c), c);
        let t = new_token();
        assert!(t.starts_with("bdt_"));
        assert_eq!(t.len(), 4 + 64);
        assert_ne!(new_token(), t);
    }
}
