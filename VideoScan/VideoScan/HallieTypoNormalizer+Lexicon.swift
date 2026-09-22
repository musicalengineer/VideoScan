// HallieTypoNormalizer+Lexicon.swift
// The closed word tables behind HallieTypoNormalizer (Rick 2026-09-21:
// "My users will be making typos and we can't have Hallie freaking out").
// Every rewrite the normalizer makes comes from one of these tables; a
// token that is not in them — a name, a place, a rare word — is left
// exactly as typed. Keep additions table-shaped: one row, one reason.
//
// C++ analogy: a set of `static const` lookup tables in their own
// translation unit; `static let` here is initialised once, lazily and
// thread-safely (like a function-local static in C++11).

import Foundation

extension HallieTypoNormalizer {
    // MARK: - Fixed rewrites (run-together pairs, missing apostrophes, texting)

    /// Whole-token rewrites. Keys are lower-case; values keep their own
    /// case ("I'm"). The rules for the ambiguous single letters ("u", "r",
    /// "ur") live in the normalizer, not here.
    static let fixedRewrites: [String: (text: String, kind: Correction.Kind)] = {
        var table: [String: (text: String, kind: Correction.Kind)] = [:]
        let runTogether: [String: String] = [
            // The live miss of 2026-09-21 18:52 and its cousins.
            "areyou": "are you", "areu": "are you", "howare": "how are",
            "howareyou": "how are you", "howru": "how are you", "hru": "how are you",
            "howareu": "how are you", "howr": "how are", "howdoyou": "how do you",
            "thankyou": "thank you", "thanku": "thank you", "thankyu": "thank you",
            "thnku": "thank you", "tyvm": "thank you very much",
            "whatis": "what is", "whereis": "where is", "whois": "who is",
            "whowas": "who was", "whenwas": "when was", "wherewas": "where was",
            "whatwas": "what was", "howmany": "how many", "howmuch": "how much",
            "howold": "how old", "tellme": "tell me", "showme": "show me",
            "tellmeabout": "tell me about", "showmevideos": "show me videos",
            "iam": "I am", "doyou": "do you", "canyou": "can you",
            "goodmorning": "good morning",
            "goodafternoon": "good afternoon", "goodevening": "good evening",
            "hithere": "hi there", "hellothere": "hello there",
            "gonna": "going to", "wanna": "want to", "lemme": "let me",
            "gimme": "give me", "dunno": "don't know", "idk": "I don't know",
        ]
        let apostrophes: [String: String] = [
            "im": "I'm", "ive": "I've", "youre": "you're", "youve": "you've",
            "youll": "you'll", "youd": "you'd", "theyre": "they're",
            "dont": "don't", "doesnt": "doesn't", "didnt": "didn't",
            "cant": "can't", "couldnt": "couldn't", "wont": "won't",
            "wouldnt": "wouldn't", "shouldnt": "shouldn't", "isnt": "isn't",
            "wasnt": "wasn't", "werent": "weren't", "arent": "aren't",
            "havent": "haven't", "hasnt": "hasn't", "hadnt": "hadn't",
            "whats": "what's", "whos": "who's", "wheres": "where's",
            "hows": "how's", "thats": "that's", "theres": "there's",
            "heres": "here's", "whens": "when's",
        ]
        let texting: [String: String] = [
            "pls": "please", "plz": "please", "plse": "please", "pleez": "please",
            "thx": "thanks", "thnx": "thanks", "thanx": "thanks", "thks": "thanks",
            "tks": "thanks", "thnks": "thanks",
            "wat": "what", "wut": "what", "wht": "what", "whut": "what",
            "abt": "about", "bday": "birthday",
            "vid": "video", "vids": "videos", "pic": "picture", "pics": "pictures",
            "ppl": "people", "yrs": "years", "yr": "year",
            // Real (obscure) words in the system list that are, in a
            // question to Hallie, always the slip.
            "tel": "tell", "sho": "show", "wen": "when", "aer": "are",
            "teh": "the", "adn": "and", "nad": "and", "byee": "bye",
        ]
        for (key, value) in runTogether { table[key] = (value, .runTogether) }
        for (key, value) in apostrophes { table[key] = (value, .runTogether) }
        for (key, value) in texting { table[key] = (value, .texting) }
        return table
    }()

    /// Rewrites that a capitalised word in the middle of a sentence keeps
    /// out of: each is also a real surname or given name ("Cant", "Im").
    static let nameLikeRewrites: Set<String> = [
        "cant", "im", "wont", "ur", "hows", "whos", "wat", "vid", "wen", "sho",
    ]

    /// "ur" before one of these reads as "you're" ("ur welcome"); else "your".
    static let youAreFollowers: Set<String> = [
        "welcome", "right", "the", "so", "very", "great", "amazing", "awesome",
        "funny", "kind", "sweet", "helpful", "a", "an", "wonderful", "correct",
        "wrong", "not", "good", "smart", "lovely", "too", "really", "such",
        "doing", "going", "there", "here", "back", "still", "always", "just",
    ]

    /// A lower-case "r" is "are" only beside one of these ("how r u").
    static let areNeighbours: Set<String> = [
        "how", "what", "who", "where", "when", "why", "you", "u", "we", "they",
        "there", "these", "those", "ur", "y",
    ]

    // MARK: - The closed vocabulary for one-letter slips

    /// Hallie's own function and command words. A token one keyboard slip
    /// from exactly one of these (and not a word or name itself) is read
    /// as it. Every word is at least three letters long.
    static let vocabulary: Set<String> = [
        // Commands and asks
        "show", "find", "search", "play", "open", "list", "tell", "about",
        "give", "please", "thanks", "thank", "hello", "remember", "know",
        // Question words
        "how", "when", "where", "who", "what", "which", "why", "many", "much",
        "old", "you", "your", "was", "were", "have",
        // Media
        "video", "videos", "clip", "clips", "picture", "pictures", "photo",
        "photos", "movie", "movies", "footage", "recording", "recordings",
        "tape", "tapes", "archive", "catalog",
        // Family and the tree
        "family", "tree", "mother", "father", "brother", "brothers", "sister",
        "sisters", "grandmother", "grandfather", "grandma", "grandpa",
        "grandparents", "parents", "daughter", "daughters", "cousin",
        "cousins", "uncle", "aunt", "husband", "wife", "children", "ancestors",
        "ancestor", "related", "relationship", "people", "person", "maiden",
        "name", "names",
        // Vital facts and events
        "born", "birth", "died", "death", "passed", "away", "married",
        "marry", "wedding", "birthday", "christmas", "thanksgiving", "easter",
        "halloween", "year", "years", "oldest", "youngest", "first", "last",
        "before", "after", "during", "together",
    ]

    /// Short function words a slip may be read as ("teh" → "the", "rae"
    /// → "are"). Each one's real-word neighbours are in `commonWords`.
    static let shortSlipVocabulary: Set<String> = [
        "the", "are", "and", "his", "her", "for", "else", "there", "today",
        "going", "morning", "evening", "afternoon", "night", "doing", "one",
        "can", "did", "out", "hey", "tonight", "write", "delete", "biography",
        "narrow", "spouse", "service", "military", "rain",
    ]

    /// Table words never used as slip targets: a typo inside a table
    /// ("what is the daye") and words too close to everyday English.
    static let slipVocabularyExclusions: Set<String> = [
        "daye", "todays", "hows", "thats", "later", "done", "type", "said",
        "says", "sort", "sorts", "cool", "neat",
    ]

    /// Vocabulary words people capitalise mid-sentence (holidays), so a
    /// capitalised slip of one of them may still be read.
    static let capitalisedVocabulary: Set<String> = [
        "christmas", "thanksgiving", "easter", "halloween",
    ]

    // MARK: - Run-together splitting

    /// A run-together token splits only into two or three of these
    /// ("whowas" → "who was", "videosof" → "videos of").
    static let splitParts: Set<String> = [
        "are", "you", "how", "what", "who", "where", "when", "why", "which",
        "is", "was", "were", "am", "do", "does", "did", "can", "could",
        "would", "will", "tell", "show", "me", "my", "your", "about", "thank",
        "the", "of", "to", "in", "on", "at", "for", "with", "many", "much",
        "old", "it", "this", "that", "there", "and", "or", "not", "have",
        "has", "had", "be", "been", "see", "find", "videos", "video",
        "pictures", "photos", "family", "tree", "mother", "father", "born",
        "died", "doing", "going", "today", "up", "all", "any", "some", "get",
        "got", "let", "give", "know", "we", "us", "our", "his", "her", "him",
        "she", "he", "they", "them", "their", "so", "if", "no", "yes", "hi",
        "hello", "hey", "hallie", "please", "thanks", "year", "years", "ago", "else",
        "good", "morning", "night", "afternoon", "evening", "i",
    ]

    /// Collapsing a DOUBLE letter ("hii", "thankss") is allowed only onto
    /// these; a triple ("helllo") may collapse onto any known word. Names
    /// are full of doubles — "Matt" must never become "mat".
    static let doubleCollapseTargets: Set<String> = [
        "hi", "hey", "yes", "ok", "no", "so", "thanks", "please", "hello",
        "bye", "wow", "yay", "yep", "nope", "sure", "what", "who", "how",
        "why", "when", "where", "show", "find", "tell", "videos", "video",
    ]

    // MARK: - Protected names

    /// Given names and family words that are never rewritten even with no
    /// People tab loaded; the injected oracle covers the rest (surnames,
    /// the tree). Chosen for being one slip from a vocabulary word or a
    /// split part, or being a common nickname.
    static let builtinProtectedNames: Set<String> = [
        "ma", "pa", "mom", "dad", "mum", "nana", "papa", "mama", "gram", "gramps",
        "tim", "timmy", "dan", "danny", "tom", "ted", "jim", "bob", "don", "ron",
        "kim", "pat", "sue", "meg", "amy", "joe", "al", "ed", "liz", "max",
        "jan", "kay", "fay", "gus", "ray", "roy", "lou", "art", "bud", "deb",
        "mae", "may", "mark", "matt", "libby", "anna", "ann", "anne", "donna",
        "will", "bill", "jill", "jack", "john", "joan", "jean", "june", "rose",
        "ruth", "beth", "ben", "sam", "sal", "hal", "mel", "val", "nan", "nell",
        "dot", "bea", "ada", "ida", "eve", "abe", "ike", "lee", "dee", "jo",
        "flo", "peg", "rita", "rick", "nick", "dick", "mick", "vic", "walt",
        "burt", "kurt", "curt", "bert", "carl", "earl", "neil", "dale", "gail",
        "dawn", "lynn", "glen", "gwen", "tina", "gina", "lisa", "elsa", "ella",
        "emma", "owen", "evan", "ian", "ivan", "sean", "dean", "joel", "noel",
        "ross", "ned", "fred", "stan", "dave", "pete", "mike", "tony", "andy",
        "harry", "barry", "larry", "gary", "jerry", "terry", "perry", "carrie",
        "paula", "bonnie", "ellen", "eileen", "muriel", "edith", "hallie",
        "wendy", "cindy", "sandy", "randy", "mary", "marie", "martha", "sara",
        "sarah", "kate", "katie", "jane", "jenny", "penny", "molly", "polly",
        "sally", "betty", "patty", "kathy", "cathy", "judy", "trudy", "grace",
        "hope", "faith", "joy", "iris", "ivy", "lily", "daisy", "fern", "pearl",
        "tess", "bess", "jess", "chris", "phil", "paul", "saul", "luke", "jake",
        "mitch", "chuck", "hank", "frank", "hugh", "hugo", "otto", "cy", "gil",
        "abel", "archie", "greta", "stuart", "avery", "marty", "james", "jamie",
        "doris", "dora", "nora", "cora", "lora", "hans", "andi", "howe", "tory",
    ]

    // MARK: - Words that are never "corrected"

    /// Everyday English a slip-corrector must leave alone because it is a
    /// real word one slip from a vocabulary word ("fine" is not "find",
    /// "hour" is not "your", "snow" is not "show") or a compound a
    /// splitter would otherwise break ("into", "somehow", "theme").
    static let commonWords: Set<String> = [
        // Near neighbours of the vocabulary
        "fine", "fins", "fond", "fund", "kind", "mind", "bind", "wind", "hind",
        "rind", "shoe", "shoes", "snow", "slow", "shop", "shot", "chow",
        "fell", "yell", "bell", "sell", "well", "cell", "dell", "tall", "toll",
        "hour", "hours", "four", "tour", "pour", "sour", "yours", "hoe", "now",
        "bow", "row", "cow", "low", "mow", "sow", "tow", "vow", "wow", "hew",
        "bold", "cold", "gold", "hold", "mold", "sold", "told", "olds", "odd",
        "corn", "horn", "worn", "torn", "barn", "burn", "bore", "bored", "borne",
        "dies", "dyed", "diet", "dried", "tied", "lied", "pied", "dues",
        "wheat", "whet", "chat", "that", "what's", "wham", "whom", "whose",
        "whim", "whip", "whit", "whir", "whiz", "thy", "shy", "wry", "thee", "then", "they", "them", "tho", "she", "tie", "toe", "ate", "area", "bare", "care", "dare", "fare", "hare", "mare", "pare", "rare", "ware", "ares", "hand", "band", "land", "sand", "wand", "rand", "grand", "ants", "end", "hip", "hiss", "this", "hen", "herd", "per", "fro", "fir", "form", "fort", "fork", "ford", "fore", "fur", "far", "foe", "fog", "fox", "else", "god", "gods", "gong", "gonging", "evenings", "nights", "might", "sight", "tight", "fight",
        "passes", "passer", "pasted", "paused", "marred", "marries", "married",
        "abut", "abbot", "tanks", "thank", "thinks", "thins", "tank", "thong",
        "may", "man", "mane", "main", "mink", "manly", "mush", "such", "mulch",
        "tear", "tears", "gear", "gears", "hear", "hears", "near", "bear",
        "dear", "fear", "pear", "rear", "sear", "wear", "yeah", "yearn",
        "rather", "gather", "lather", "feather", "bother", "brothel", "smother",
        "tee", "free", "trees", "tread", "treat", "trek", "true", "tier",
        "pay", "ply", "clay", "slay", "flay", "lost", "last", "lust", "lint",
        "lisp", "live", "dive", "hive", "five", "gave", "gibe", "flip", "slip",
        "clap", "tale", "tap", "tame", "take", "type", "tube", "sway", "wide",
        "wire", "wipe", "wise", "wine", "life", "knife", "wives", "ant", "aunts",
        "same", "game", "came", "fame", "lame", "nome", "none", "noon", "soon",
        "knew", "known", "knot", "whole", "wholly", "whoa", "hoot",
        "went", "west", "wet", "wit", "wig", "win", "won", "wan", "was", "wax",
        "way", "war", "wad", "wag", "who'd", "woo", "wok", "yak", "yam", "yap",
        "yaw", "yea", "yen", "yes", "yet", "yip", "yob", "yon", "yum", "yup",
        "hoe", "hog", "hop", "hot", "hub", "hug", "hum", "hut", "hid", "him",
        "his", "hit", "hoax", "howl", "howls", "howdy", "however",
        "shows", "showed", "showing", "shown", "finds", "finding", "found",
        "tells", "telling", "told", "plays", "played", "playing", "opens",
        "opened", "lists", "listed", "gives", "given", "giving", "knows",
        "passing", "dying", "marrying", "births", "deaths", "named", "naming",
        "videotape", "videotapes", "photograph", "photographs", "photographed",
        "pictured", "picturing", "recorded", "recorder", "taped", "taping",
        "archived", "archives", "catalogue", "catalogued", "cataloged",
        "familiar", "families", "grandmothers", "grandfathers", "grandson",
        "granddaughter", "grandkids", "grandchildren", "granny", "grandad",
        "granddad", "mothers", "fathers", "husbands", "wives", "uncles",
        "parent", "child", "kid", "kids", "son", "sons", "niece", "nephew",
        "persons", "personal", "peoples", "ancestry", "relation", "relations",
        "relative", "relatives", "relate", "relating", "maid", "maids",
        "weddings", "birthdays", "christmases", "year's", "yearly", "firsts",
        "lasts", "lasted", "lasting", "afterwards", "beforehand", "together",
        // Compounds a splitter would break
        "into", "onto", "upon", "within", "without", "cannot", "today",
        "tonight", "tomorrow", "yesterday", "maybe", "someone", "somebody",
        "something", "somehow", "somewhat", "somewhere", "sometimes", "anyone",
        "anybody", "anything", "anyhow", "anyway", "anywhere", "everyone",
        "everybody", "everything", "everywhere", "nobody", "nothing",
        "nowhere", "myself", "yourself", "himself", "herself", "itself",
        "ourselves", "themselves", "whatever", "whenever", "wherever",
        "whoever", "wherein", "whereas", "whatnot", "therein", "thereby",
        "herein", "theme", "tome", "dome", "meme", "heat", "meat", "beat",
        "seat", "bean", "mean", "wean", "hehe", "haha", "atom", "athome",
        "notable", "noted", "note", "nose", "tote", "totem", "anon", "amid",
        "amen", "among", "ahem", "undo", "outdo", "upset", "inset", "sofa",
        "soup", "hero", "here", "herb", "hers", "shed", "shes", "hes", "isle",
        "withal", "insofar", "inasmuch", "hitherto", "whereupon", "forgot",
        "forget", "forgive", "format", "former", "forth", "fortune", "forty",
        "forum", "doing", "domain", "dodo", "onset", "often", "seen", "been",
        "being", "begin", "began", "behind", "below", "beside", "besides",
        "between", "beyond", "became", "become", "because", "before",
        "ahead", "alone", "along", "also", "always", "another", "around",
        "away", "back", "badly", "baby", "babies", "hall", "hallway",
        // Frequent everyday words
        "a", "i", "an", "the", "and", "or", "but", "if", "of", "to", "in", "on",
        "at", "by", "for", "with", "from", "up", "down", "out", "off", "over",
        "under", "again", "then", "than", "once", "here", "there", "when",
        "all", "any", "both", "each", "few", "more", "most", "other", "some",
        "no", "nor", "not", "only", "own", "so", "too", "very", "can", "will",
        "just", "should", "would", "could", "might", "must", "shall", "am",
        "is", "are", "be", "have", "has", "had", "do", "does", "did", "get",
        "got", "make", "made", "go", "goes", "going", "gone", "come", "comes",
        "coming", "see", "saw", "look", "looking", "want", "need", "like",
        "love", "think", "say", "said", "ask", "asked", "use", "try", "call",
        "keep", "let", "put", "run", "set", "sit", "stand", "turn", "move",
        "help", "start", "stop", "talk", "work", "feel", "seem", "leave",
        "mean", "happen", "happened", "bring", "hold", "write", "read", "hear",
        "meet", "pay", "buy", "eat", "drink", "sleep", "wait", "watch",
        "watched", "wish", "hope", "guess", "wonder", "believe", "mind",
        "i'm", "me", "my", "mine", "we", "us", "our", "ours", "he", "him",
        "his", "she", "her", "it", "its", "they", "them", "their", "theirs",
        "this", "that", "these", "those", "one", "two", "three", "ten",
        "good", "great", "nice", "new", "big", "small", "little", "long",
        "short", "high", "low", "young", "early", "late", "right", "wrong",
        "sure", "real", "best", "better", "bad", "worse", "worst", "same",
        "different", "whole", "happy", "sad", "busy", "ready", "okay", "ok",
        "day", "days", "week", "month", "time", "times", "night", "morning",
        "afternoon", "evening", "home", "house", "school", "work", "place",
        "town", "city", "state", "country", "world", "way", "thing", "things",
        "man", "men", "woman", "women", "girl", "boy", "friend", "friends",
        "dog", "cat", "car", "boat", "beach", "cape", "lake", "party",
        "song", "music", "guitar", "piano", "dinner", "lunch", "breakfast",
        "hi", "hey", "bye", "yes", "yeah", "hmm", "oh", "um", "uh", "lol",
        "sorry", "welcome", "cheers", "hallie", "doing", "well", "fine",
        "mae", "mcgill", "merry", "box", "sunset",
        // Regnal numerals ("Edward III") — never stretched letters.
        "ii", "iii", "iv", "vi", "vii", "viii", "ix", "xi", "xii", "xiii",
        "xiv", "xv", "xvi",
        // Real words one slip from a table word (checked against the
        // system dictionary, 2026-09-21)
        "table", "fable", "cable", "gable", "sable", "bout", "gain", "round",
        "masked", "daunt", "haunt", "jaunt", "taunt", "gaunt", "black", "hack",
        "bee", "bet", "beast", "nest", "vest", "beet", "getter", "girth",
        "brunch", "hunch", "card", "carve", "scare", "clan", "lean", "cleat",
        "lip", "fate", "rate", "dearth", "doe", "dose", "ding", "dong", "dot",
        "font", "dill", "frill", "crop", "drip", "droop", "curing", "dearly",
        "nearly", "earl", "eastern", "eater", "aster", "eve", "event", "seven",
        "ever", "excise", "farther", "fist", "forge", "forger", "cast", "feast",
        "vast", "fiend", "fin", "bang", "gang", "hag", "halve", "haven",
        "heave", "shave", "heaving", "shaving", "hearing", "beading", "hell",
        "whelp", "yelp", "heir", "hole", "hood", "kingship", "joust", "jut",
        "lest", "lit", "lots", "post", "clove", "glove", "lobe", "lover",
        "lively", "munch", "minuet", "mistaken", "mixer", "mourning", "mover",
        "heed", "kneed", "needs", "needy", "nee", "knight", "bight", "eight",
        "fright", "bright", "fold", "pen", "cover", "hover", "rover", "overt",
        "parson", "prefect", "petty", "preset", "rest", "resent", "dough",
        "tough", "trough", "crap", "sighing", "singing", "selling", "spoon",
        "swoon", "worry", "star", "tart", "stiff", "stuffy", "fake", "rake",
        "stake", "taken", "stalk", "ape", "gape", "taper", "taupe", "tales",
        "reach", "tech", "hat", "thin", "thus", "though", "rime", "tine", "tip",
        "tops", "tipsy", "fired", "tried", "tire", "tropic", "tying", "every",
        "await", "waist", "wash", "wasp", "ways", "wee", "width", "witch",
        "worm", "wring", "rote", "ear", "shat", "whey", "whoop", "lay", "plat",
        "splay", "lease", "clip", "lear", "pad", "hone", "photon", "ole",
        "wold", "tor", "cor", "arse", "acre", "tare", "yore", "ours", "tumble",
        "once", "bone", "cone", "done", "gone", "lone", "none", "tone", "zone",
        "ons", "owe", "ode", "ore", "fan", "van", "cab", "cam", "cane", "cans",
        "scan", "rid", "dud", "die", "dig", "dim", "din", "dip", "lid", "bid",
        "aid", "mid", "food", "mood", "wood", "goods", "goad", "goof", "mice",
        "nicer", "ran", "rein", "ruin", "raid", "rail", "rains", "sire", "cure",
        "pure", "lure", "our", "oat", "opt", "put", "hut", "rut", "gut", "nut",
        "wire", "writ", "wrote", "white", "narrows", "arrow", "spouses",
        "behave", "usher", "belong", "island", "notice", "inform", "income",
        "insight", "update", "input", "inbox", "withdraw", "atone", "therefore",
        "beware", "behold", "begot", "beget", "heron", "keen", "jeep", "kept",
        "mine", "wind", "bind", "wells", "weld", "welt", "gold", "mold", "dice",
        "vice", "rice", "cane", "canny", "hen", "key", "hay", "hew", "they",
    ]
}
