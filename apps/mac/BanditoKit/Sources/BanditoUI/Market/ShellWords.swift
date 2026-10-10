import Foundation

/// Splits a command line into words the way a shell does, and joins words back. Pure; no expansion happens
/// (`$HOME` and `~` stay as typed). The daemon starts the program without a shell, so this only decides what the words
/// are.
enum ShellWords {
    /// The words of `line`, or nil when a quote is not closed or the line ends in a lone backslash.
    /// Words are split on spaces, tabs and new lines. `'…'` keeps everything; `"…"` keeps everything but `\"` and
    /// `\\`; a backslash outside quotes takes the next character literally; a backslash before a new line (a line
    /// continuation) is dropped with it. `""` is an empty word.
    static func split(_ line: String) -> [String]? {
        var words: [String] = []
        var current = ""
        var inWord = false
        var quote: Character?
        var iterator = Array(line).makeIterator()
        while let ch = iterator.next() {
            if let open = quote {
                if ch == open {
                    quote = nil
                } else if open == "\"", ch == "\\" {
                    guard let next = iterator.next() else { return nil }
                    if next == "\"" || next == "\\" || next == "$" || next == "`" {
                        current.append(next)
                    } else if next == "\n" {
                        continue
                    } else {
                        current.append("\\")
                        current.append(next)
                    }
                } else {
                    current.append(ch)
                }
                continue
            }
            switch ch {
            case "'", "\"":
                quote = ch
                inWord = true
            case "\\":
                guard let next = iterator.next() else { return nil }
                if next == "\n" || next == "\r" { continue }
                current.append(next)
                inWord = true
            case " ", "\t", "\n", "\r":
                if inWord {
                    words.append(current)
                    current = ""
                    inWord = false
                }
            default:
                current.append(ch)
                inWord = true
            }
        }
        if quote != nil { return nil }
        if inWord { words.append(current) }
        return words
    }

    /// The words of `line` for display and checks: the proper split, or a plain split on spaces when a quote is open.
    static func lenientSplit(_ line: String) -> [String] {
        split(line) ?? line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init)
    }

    /// One word as it is written in a command line: bare when it is plain, else in single quotes.
    static func quote(_ word: String) -> String {
        if word.isEmpty { return "''" }
        let plain = word.unicodeScalars.allSatisfy { scalar in
            (97...122).contains(scalar.value) || (65...90).contains(scalar.value) || (48...57).contains(scalar.value)
                || "@%+=:,./_-~".unicodeScalars.contains(scalar)
        }
        if plain { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// `split(join(words)) == words` for any words.
    static func join(_ words: [String]) -> String {
        words.map(quote).joined(separator: " ")
    }
}
