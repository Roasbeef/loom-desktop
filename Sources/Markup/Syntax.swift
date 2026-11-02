import Foundation

/// What a span of source code is, for colouring.
public enum SyntaxKind: Sendable, Equatable {
    case plain, keyword, string, comment, number, type, function
}

public struct SyntaxToken: Sendable, Equatable {
    public let kind: SyntaxKind
    public let text: String
}

/// A small tokenizer for the code a coding agent shows.
///
/// It colours by lexical class only, so it is wrong in small ways a real grammar
/// would not be and never wrong in ways that change the text: the tokens always
/// join back to exactly the input. An unknown language still gets strings,
/// comments and numbers, which carry most of the reading benefit.
public enum Syntax {
    private struct Language {
        var keywords: Set<String> = []
        var lineComments: [String] = []
        var blockComment: (open: String, close: String)?
        var capitalizedAreTypes = true
    }

    private static func language(_ name: String?) -> Language {
        func words(_ text: String) -> Set<String> { Set(text.split(separator: " ").map(String.init)) }
        let cStyle = (open: "/*", close: "*/")
        switch name?.lowercased() {
        case "swift":
            return Language(keywords: words("actor as async await break case catch class continue default defer do else enum extension false fileprivate final for func guard if import in init internal let mutating nil nonisolated private protocol public return self static struct super switch throw throws true try typealias var where while some any"), lineComments: ["//"], blockComment: cStyle)
        case "go", "golang":
            return Language(keywords: words("break case chan const continue default defer else fallthrough false for func go goto if import interface map nil package range return select struct switch true type var"), lineComments: ["//"], blockComment: cStyle)
        case "gleam":
            return Language(keywords: words("as assert case const external fn if import let opaque panic pub todo type use True False Nil Ok Error"), lineComments: ["//"], capitalizedAreTypes: true)
        case "rust", "rs":
            return Language(keywords: words("as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while"), lineComments: ["//"], blockComment: cStyle)
        case "python", "py":
            return Language(keywords: words("and as assert async await break class continue def del elif else except False finally for from global if import in is lambda None nonlocal not or pass raise return True try while with yield"), lineComments: ["#"])
        case "javascript", "js", "typescript", "ts", "tsx", "jsx":
            return Language(keywords: words("as async await break case catch class const continue default delete do else export extends false finally for from function if import in instanceof interface let new null of return super switch this throw true try type typeof undefined var void while yield"), lineComments: ["//"], blockComment: cStyle)
        case "sh", "bash", "zsh", "shell", "console":
            return Language(keywords: words("if then else elif fi for in do done while case esac function return export local set exit"), lineComments: ["#"], capitalizedAreTypes: false)
        case "erlang", "erl":
            return Language(keywords: words("after and andalso band begin case catch cond end fun if let not of or orelse receive try when"), lineComments: ["%"], capitalizedAreTypes: false)
        case "c", "cpp", "c++", "h", "objc":
            return Language(keywords: words("auto break case char const continue default do double else enum extern float for goto if int long register return short signed sizeof static struct switch typedef union unsigned void volatile while class public private protected namespace template new delete true false nullptr"), lineComments: ["//"], blockComment: cStyle)
        case "sql":
            return Language(keywords: words("select from where insert into values update set delete create table index join left right inner outer on and or not null primary key order by group limit as SELECT FROM WHERE INSERT INTO VALUES UPDATE SET DELETE CREATE TABLE INDEX JOIN LEFT RIGHT INNER OUTER ON AND OR NOT NULL PRIMARY KEY ORDER BY GROUP LIMIT AS"), lineComments: ["--"], capitalizedAreTypes: false)
        case "json", "toml", "yaml", "yml":
            return Language(keywords: words("true false null"), lineComments: name?.lowercased() == "json" ? [] : ["#"], capitalizedAreTypes: false)
        default:
            return Language(lineComments: [], capitalizedAreTypes: false)
        }
    }

    public static func highlight(_ code: String, language name: String?) -> [SyntaxToken] {
        let language = language(name)
        let characters = Array(code)
        var tokens: [SyntaxToken] = []
        var plain = ""
        var index = 0

        func flushPlain() {
            if !plain.isEmpty {
                tokens.append(.init(kind: .plain, text: plain))
                plain = ""
            }
        }

        func matches(_ text: String, at position: Int) -> Bool {
            let needle = Array(text)
            guard position + needle.count <= characters.count else { return false }
            for offset in needle.indices where characters[position + offset] != needle[offset] {
                return false
            }
            return true
        }

        scan: while index < characters.count {
            let character = characters[index]

            for marker in language.lineComments where matches(marker, at: index) {
                flushPlain()
                var end = index
                while end < characters.count, characters[end] != "\n" { end += 1 }
                tokens.append(.init(kind: .comment, text: String(characters[index..<end])))
                index = end
                continue scan
            }

            if let block = language.blockComment, matches(block.open, at: index) {
                flushPlain()
                var end = index + block.open.count
                while end < characters.count, !matches(block.close, at: end) { end += 1 }
                end = min(characters.count, end + block.close.count)
                tokens.append(.init(kind: .comment, text: String(characters[index..<end])))
                index = end
                continue
            }

            if character == "\"" || character == "'" || character == "`" {
                // An apostrophe inside a word is not a string.
                if character == "'", index > 0, characters[index - 1].isLetter {
                    plain.append(character)
                    index += 1
                    continue
                }
                flushPlain()
                var end = index + 1
                while end < characters.count, characters[end] != character, characters[end] != "\n" {
                    end += characters[end] == "\\" ? 2 : 1
                }
                end = min(characters.count, end + 1)
                tokens.append(.init(kind: .string, text: String(characters[index..<end])))
                index = end
                continue
            }

            if character.isNumber, index == 0 || !(characters[index - 1].isLetter || characters[index - 1] == "_") {
                flushPlain()
                var end = index
                while end < characters.count, characters[end].isHexDigit || characters[end] == "." || characters[end] == "_" || characters[end] == "x" {
                    end += 1
                }
                tokens.append(.init(kind: .number, text: String(characters[index..<end])))
                index = end
                continue
            }

            if character.isLetter || character == "_" {
                var end = index
                while end < characters.count, characters[end].isLetter || characters[end].isNumber || characters[end] == "_" {
                    end += 1
                }
                let word = String(characters[index..<end])
                if language.keywords.contains(word) {
                    flushPlain()
                    tokens.append(.init(kind: .keyword, text: word))
                } else if language.capitalizedAreTypes, word.first?.isUppercase == true {
                    flushPlain()
                    tokens.append(.init(kind: .type, text: word))
                } else if !language.keywords.isEmpty, end < characters.count, characters[end] == "(" {
                    flushPlain()
                    tokens.append(.init(kind: .function, text: word))
                } else {
                    plain += word
                }
                index = end
                continue
            }

            plain.append(character)
            index += 1
        }
        flushPlain()
        return tokens
    }

    /// Guesses a language from a file path, for highlighting tool output.
    public static func language(forPath path: String) -> String? {
        switch (path as NSString).pathExtension.lowercased() {
        case "swift": return "swift"
        case "go": return "go"
        case "gleam": return "gleam"
        case "rs": return "rust"
        case "py": return "python"
        case "js", "jsx", "ts", "tsx": return "typescript"
        case "sh", "zsh", "bash": return "sh"
        case "erl", "hrl": return "erlang"
        case "c", "h", "cpp", "cc", "m": return "c"
        case "sql": return "sql"
        case "json": return "json"
        case "toml": return "toml"
        case "yml", "yaml": return "yaml"
        default: return nil
        }
    }
}
