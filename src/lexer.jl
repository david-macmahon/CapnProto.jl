# lexer.jl - tokenizer for the Cap'n Proto schema language.

const PRIMITIVE_KEYWORDS = Dict{String,PrimitiveType}(
    "Void" => PT_Void, "Bool" => PT_Bool,
    "Int8" => PT_Int8, "Int16" => PT_Int16, "Int32" => PT_Int32, "Int64" => PT_Int64,
    "UInt8" => PT_UInt8, "UInt16" => PT_UInt16, "UInt32" => PT_UInt32, "UInt64" => PT_UInt64,
    "Float32" => PT_Float32, "Float64" => PT_Float64,
    "Text" => PT_Text, "Data" => PT_Data,
)

const NODE_KEYWORDS = Set(["struct", "enum", "interface", "const", "annotation",
                           "union", "group", "import", "using"])

"""
A single token produced by the [`Lexer`](@ref). `kind` is a `Symbol` (e.g.
`:ident`, `:keyword`, `:integer`, `:float`, `:string`, `:semicolon`, `:eof`),
`text` is the literal source text of the token, and `line` is the 1-based
source line on which it began.
"""
struct Token
    kind::Symbol
    text::String
    line::Int
end

"""
    Lexer(src::AbstractString)

A mutable tokenizer over a Cap'n Proto schema source string. Tracks the
current 1-based byte position and line. Use [`peek`](@ref), [`advance`](@ref),
and [`at_end`](@ref) to drive the parser; `peek` and `at_end` restore the
position after observing the next token.
"""
mutable struct Lexer
    src::String
    bytes::Vector{UInt8}
    pos::Int        # 1-based byte index
    line::Int
end
Lexer(src::AbstractString) = Lexer(String(src), codeunits(src), 1, 1)

at_end(lex::Lexer) = begin
    # Skip whitespace/comments to find the next real token, but restore position
    # so this is observation-only.
    save = (lex.pos, lex.line)
    t = next_token(lex)
    is_eof = t.kind == :eof
    lex.pos, lex.line = save
    return is_eof
end

function peek(lex::Lexer)::Token
    save = (lex.pos, lex.line)
    t = next_token(lex)
    lex.pos, lex.line = save
    return t
end

function advance(lex::Lexer)::Token
    return next_token(lex)
end

function next_token(lex::Lexer)::Token
    # Skip whitespace and comments.
    while lex.pos <= length(lex.bytes)
        c = lex.bytes[lex.pos]
        if c == 0x20 || c == 0x09 || c == 0x0d
            lex.pos += 1
        elseif c == 0x0a
            lex.pos += 1
            lex.line += 1
        elseif c == 0x23  # '#'
            while lex.pos <= length(lex.bytes) && lex.bytes[lex.pos] != 0x0a
                lex.pos += 1
            end
        else
            break
        end
    end
    if lex.pos > length(lex.bytes)
        return Token(:eof, "", lex.line)
    end
    start = lex.pos
    line = lex.line
    c = lex.bytes[lex.pos]
    # Identifiers / keywords.
    if is_ident_start(c)
        while lex.pos <= length(lex.bytes) && is_ident_char(lex.bytes[lex.pos])
            lex.pos += 1
        end
        text = String(lex.bytes[start:lex.pos-1])
        kind = if text in keys(PRIMITIVE_KEYWORDS)
            :keyword
        elseif text in NODE_KEYWORDS
            :keyword
        elseif text in ("true", "false")
            :ident  # handled specifically where needed
        else
            :ident
        end
        return Token(kind, text, line)
    end
    # Numbers: integers (hex/decimal) and floats.
    if is_digit(c) || (c == 0x2d && lex.pos < length(lex.bytes) && is_digit(lex.bytes[lex.pos+1]))
        return number_token(lex, line)
    end
    # Hex literals starting with 0x handled by number_token.
    # String literal.
    if c == 0x22  # '"'
        return string_token(lex, line)
    end
    # Punctuation.
    lex.pos += 1
    sym = Char(c)
    kind = if sym == '{'; :lbrace
    elseif sym == '}'; :rbrace
    elseif sym == '('; :lparen
    elseif sym == ')'; :rparen
    elseif sym == '['; :lbracket
    elseif sym == ']'; :rbracket
    elseif sym == ';'; :semicolon
    elseif sym == ','; :comma
    elseif sym == ':'; :colon
    elseif sym == '@'; :at
    elseif sym == '='; :eq
    elseif sym == '+'; :plus
    elseif sym == '-'; :minus
    elseif sym == '*'; :star
    elseif sym == '/'; :slash
    elseif sym == '$'; :dollar
    else; :punct
    end
    return Token(kind, string(sym), line)
end

function is_ident_start(c::UInt8)
    return (0x41 <= c <= 0x5a) || (0x61 <= c <= 0x7a) || c == 0x5f  # A-Za-z_
end
function is_ident_char(c::UInt8)
    return is_ident_start(c) || (0x30 <= c <= 0x39)  # plus 0-9
end
is_digit(c::UInt8) = 0x30 <= c <= 0x39

function number_token(lex::Lexer, line::Int)::Token
    start = lex.pos
    if lex.bytes[lex.pos] == 0x2d  # '-'
        lex.pos += 1
    end
    # Hex?
    if lex.pos + 1 <= length(lex.bytes) && lex.bytes[lex.pos] == 0x30 && lex.bytes[lex.pos+1] in (0x78, 0x58)
        lex.pos += 2
        while lex.pos <= length(lex.bytes) && is_hex_digit(lex.bytes[lex.pos])
            lex.pos += 1
        end
        return Token(:integer, String(lex.bytes[start:lex.pos-1]), line)
    end
    is_float = false
    while lex.pos <= length(lex.bytes) && is_digit(lex.bytes[lex.pos])
        lex.pos += 1
    end
    if lex.pos <= length(lex.bytes) && lex.bytes[lex.pos] == 0x2e  # '.'
        is_float = true
        lex.pos += 1
        while lex.pos <= length(lex.bytes) && is_digit(lex.bytes[lex.pos])
            lex.pos += 1
        end
    end
    # Exponent.
    if lex.pos <= length(lex.bytes) && lex.bytes[lex.pos] in (0x65, 0x45)  # e/E
        is_float = true
        lex.pos += 1
        if lex.pos <= length(lex.bytes) && lex.bytes[lex.pos] in (0x2b, 0x2d)
            lex.pos += 1
        end
        while lex.pos <= length(lex.bytes) && is_digit(lex.bytes[lex.pos])
            lex.pos += 1
        end
    end
    # Suffixes like 'f', 'i', 'u' etc. - consume alpha chars.
    while lex.pos <= length(lex.bytes) && is_ident_char(lex.bytes[lex.pos])
        lex.pos += 1
    end
    return Token(is_float ? :float : :integer, String(lex.bytes[start:lex.pos-1]), line)
end

is_hex_digit(c::UInt8) = is_digit(c) || (0x41 <= c <= 0x46) || (0x61 <= c <= 0x66)

function string_token(lex::Lexer, line::Int)::Token
    start = lex.pos
    lex.pos += 1  # opening quote
    buf = IOBuffer()
    while lex.pos <= length(lex.bytes) && lex.bytes[lex.pos] != 0x22
        c = lex.bytes[lex.pos]
        if c == 0x5c  # backslash escape
            lex.pos += 1
            e = lex.bytes[lex.pos]
            ch = if e == 0x6e; '\n'
            elseif e == 0x74; '\t'
            elseif e == 0x72; '\r'
            elseif e == 0x22; '\"'
            elseif e == 0x5c; '\\'
            elseif e == 0x30; '\0'
            else; Char(e)
            end
            write(buf, ch)
            lex.pos += 1
        else
            write(buf, Char(c))
            lex.pos += 1
        end
    end
    if lex.pos <= length(lex.bytes)
        lex.pos += 1  # closing quote
    end
    return Token(:string, String(take!(buf)), line)
end

# ----- helpers used by the parser ----------------------------------------------

function expect(lex::Lexer, kind::Symbol)::Token
    t = advance(lex)
    if t.kind != kind
        error("expected $kind on line $(t.line), got $(t.kind) '$(t.text)'")
    end
    return t
end

function expect_terminator(lex::Lexer)
    while peek(lex).kind in (:semicolon, :comma)
        advance(lex)
    end
    return nothing
end

function skip_terminators(lex::Lexer)
    while peek(lex).kind in (:semicolon, :comma)
        advance(lex)
    end
end

function skip_annotations(lex::Lexer)
    while peek(lex).kind == :dollar
        advance(lex)
        expect(lex, :ident)
        if peek(lex).kind == :lparen
            depth = 0
            while true
                t = advance(lex)
                if t.kind == :lparen
                    depth += 1
                elseif t.kind == :rparen
                    depth -= 1
                    depth == 0 && break
                elseif t.kind == :eof
                    break
                end
            end
        end
    end
end

"Skip past a value (used for unsupported default-value forms)."
function skip_value(lex::Lexer)
    depth = 0
    while true
        t = peek(lex)
        if depth == 0 && t.kind in (:semicolon, :eof)
            break
        end
        if t.kind == :lparen
            depth += 1
        elseif t.kind == :rparen
            depth -= 1
        end
        advance(lex)
    end
end
