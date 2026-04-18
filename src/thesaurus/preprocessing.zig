//! Text processing module to clean terms & synonyms.
const std = @import("std");

/// Stopwords used in Postgres' FtS.
///
/// See:
/// - https://github.com/postgres/postgres/blob/master/src/backend/snowball/stopwords/english.stop
const en_stopwords = std.StaticStringMap(void).initComptime(.{
    .{"the"},     .{"a"},       .{"an"},      .{"is"},       .{"are"},        .{"was"},
    .{"were"},    .{"be"},      .{"been"},    .{"being"},    .{"have"},       .{"has"},
    .{"had"},     .{"do"},      .{"does"},    .{"did"},      .{"will"},       .{"would"},
    .{"could"},   .{"should"},  .{"may"},     .{"might"},    .{"shall"},      .{"can"},
    .{"need"},    .{"dare"},    .{"ought"},   .{"used"},     .{"to"},         .{"of"},
    .{"in"},      .{"for"},     .{"on"},      .{"with"},     .{"at"},         .{"by"},
    .{"from"},    .{"as"},      .{"into"},    .{"through"},  .{"during"},     .{"before"},
    .{"after"},   .{"above"},   .{"below"},   .{"between"},  .{"out"},        .{"off"},
    .{"over"},    .{"under"},   .{"again"},   .{"further"},  .{"then"},       .{"once"},
    .{"it"},      .{"its"},     .{"itself"},  .{"this"},     .{"that"},       .{"these"},
    .{"those"},   .{"am"},      .{"having"},  .{"doing"},    .{"don"},        .{"now"},
    .{"i"},       .{"me"},      .{"my"},      .{"myself"},   .{"we"},         .{"our"},
    .{"you"},     .{"your"},    .{"yours"},   .{"yourself"}, .{"yourselves"}, .{"he"},
    .{"him"},     .{"himself"}, .{"his"},     .{"she"},      .{"her"},        .{"hers"},
    .{"herself"}, .{"they"},    .{"them"},    .{"their"},    .{"theirs"},     .{"themselves"},
    .{"what"},    .{"which"},   .{"because"}, .{"until"},    .{"while"},      .{"against"},
    .{"who"},     .{"whom"},    .{"and"},     .{"but"},      .{"or"},         .{"nor"},
    .{"not"},     .{"so"},      .{"very"},    .{"just"},     .{"about"},      .{"up"},
    .{"if"},      .{"how"},     .{"when"},    .{"where"},    .{"why"},        .{"also"},
    .{"too"},     .{"quite"},   .{"really"},  .{"all"},      .{"any"},        .{"some"},
    .{"each"},    .{"every"},   .{"must"},    .{"between"},  .{"down"},       .{"here"},
    .{"there"},   .{"both"},    .{"few"},     .{"more"},     .{"most"},       .{"other"},
    .{"such"},    .{"no"},      .{"only"},    .{"own"},      .{"same"},       .{"than"},
    .{"s"},       .{"t"},
});

/// Transforms identifier to lowercase & merges to build final target term.
///
/// Returns: `concat(lower(onto), lower(ident))`
pub fn processTerm(buf: []u8, onto: []const u8, ident: []const u8) []u8 {
    const name = std.ascii.lowerString(buf, onto);
    const id = std.ascii.lowerString(buf[name.len..buf.len], ident);
    return buf[0..(name.len + id.len)];
}

/// Combinatory _fn._ that normalizes the specified string by:
/// 1. Removing unnecessary punctuation,
/// 2. Transforming to lowercase,
/// 3. Triming leading & trailing whitespace, and
/// 4. Replacing stopwords with `?` identifier.
///
/// Note:
/// - Removes UTF-8 codepoints if sequence _len._ is greater than 1.
///
/// See:
/// - https://www.postgresql.org/docs/current/textsearch-dictionaries.html#TEXTSEARCH-THESAURUS
/// - http://www.sai.msu.su/~megera/oddmuse/index.cgi/Thesaurus_dictionary
pub fn processSynonym(allocator: std.mem.Allocator, slice: []const u8) ![]u8 {
    var result = try allocator.dupe(u8, slice);
    errdefer allocator.free(result);

    const cleaned = try normalizeSynonym(result);
    result = try allocator.realloc(result, cleaned.len);

    const filtered = try filterStopwords(result);
    result = try allocator.realloc(result, filtered.len);

    return result;
}

fn filterStopwords(str: []u8) ![]u8 {
    var idx: usize = 0;
    var buf: [1024]u8 = undefined;

    var it = std.mem.tokenizeScalar(u8, str[0..str.len], ' ');
    while (it.next()) |token| {
        if (idx != 0) {
            buf[idx] = ' ';
            idx += 1;
        }

        if (isStopword(token)) {
            buf[idx] = '?';
            idx += 1;
            continue;
        }

        std.mem.copyForwards(u8, buf[idx..(idx + token.len)], token);
        idx += token.len;
    }

    if (idx > 0) {
        std.mem.copyForwards(u8, str, buf[0..idx]);
    }

    return str[0..idx];
}

fn normalizeSynonym(str: []u8) ![]u8 {
    var n: usize = str.len;
    var copy: [1024]u8 = undefined;
    std.mem.copyForwards(u8, &copy, str);

    var c: u8 = std.ascii.control_code.nul;
    var i: usize = 0;
    var j: usize = 0;
    while (i < n) {
        c = copy[i];

        const size = getSizeUtf8(c);
        if (size == 1 and !std.ascii.isControl(c)) {
            if (std.ascii.isWhitespace(c)) {
                c = ' ';
            }

            if (!std.ascii.isAlphanumeric(c)) {
                switch (c) {
                    '@', '-', '_', '+', '\'', ' ' => {},
                    else => {
                        var prefix: u8 = std.ascii.control_code.nul;
                        if (i > 0 and std.ascii.isAlphanumeric(copy[i - 1])) {
                            prefix = copy[i - 1];
                        }

                        var suffix: u8 = std.ascii.control_code.nul;
                        if (i + 1 < n and std.ascii.isAlphanumeric(copy[i + 1])) {
                            suffix = copy[i + 1];
                        }

                        if (!std.ascii.isAlphanumeric(prefix) or !std.ascii.isAlphanumeric(suffix)) {
                            c = std.ascii.control_code.nul;
                        }
                    },
                }
            }

            if (c != std.ascii.control_code.nul) {
                str[j] = std.ascii.toLower(c);
                j += 1;
            }
        }

        i += size;
    }

    var flag: u8 = 0b0;
    i = 0;
    while (i < j) {
        if (std.mem.indexOfScalar(u8, &std.ascii.whitespace, str[i]) != null) {
            flag |= 0b1;
            i += 1;
        }

        if (std.mem.indexOfScalar(u8, &std.ascii.whitespace, str[j - 1]) != null) {
            flag |= 0b1;
            j -= 1;
        }

        if ((flag & flag) == 0b0) {
            break;
        }
        flag = 0b0;
    }

    j = @max(j, i);
    n = j - i;

    if (n > 0) {
        std.mem.copyForwards(u8, str, str[i..j]);
    }

    return str[i..j];
}

inline fn isStopword(token: []const u8) bool {
    return en_stopwords.has(token);
}

inline fn getSizeUtf8(char: u8) u3 {
    return std.unicode.utf8ByteSequenceLength(char) catch {
        return 1;
    };
}
