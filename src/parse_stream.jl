#-------------------------------------------------------------------------------
"""
`SyntaxToken` covers a contiguous range of the source text which contains a
token *relevant for parsing*. Syntax trivia (comments and whitespace) is dealt
with separately, though `SyntaxToken` does include some minimal information
about whether these were present.

This does not include tokens include
* Whitespace
* Comments

Note that "triviality" of tokens is context-dependent in general. For example,
the parentheses in `(1+2)*3` are important for parsing but are irrelevant after
the abstract syntax tree is constructed.
"""
struct SyntaxToken
    raw::RawToken
    # Flags for leading whitespace
    had_whitespace::Bool
    had_newline::Bool
end

function Base.show(io::IO, tok::SyntaxToken)
    range = string(lpad(first_byte(tok), 3), ":", rpad(last_byte(tok), 3))
    print(io, rpad(range, 17, " "), rpad(kind(tok), 15, " "))
end

kind(tok::SyntaxToken) = tok.raw.kind
first_byte(tok::SyntaxToken) = tok.raw.startbyte + 1
last_byte(tok::SyntaxToken) = tok.raw.endbyte + 1
span(tok::SyntaxToken) = last_byte(tok) - first_byte(tok) + 1

is_dotted(tok::SyntaxToken)    = tok.raw.dotop
is_suffixed(tok::SyntaxToken)  = tok.raw.suffix
is_decorated(tok::SyntaxToken) = is_dotted(tok) || is_suffixed(tok)

Base.:(~)(tok::SyntaxToken, k::Kind) = kind(tok) == k
Base.:(~)(k::Kind, tok::SyntaxToken) = kind(tok) == k

#-------------------------------------------------------------------------------

# Range in the source text which will become a node in the tree. Can be either
# a token (leaf node of the tree) or an interior node, depending on how nodes
# overlap.
struct TaggedRange
    head::SyntaxHead
    first_byte::Int
    last_byte::Int
end

function TaggedRange(raw::RawToken, flags::RawFlags)
    TaggedRange(SyntaxHead(raw.kind, flags), raw.startbyte + 1, raw.endbyte + 1)
end

head(text_span::TaggedRange)       = text_span.head
kind(text_span::TaggedRange)       = kind(text_span.head)
flags(text_span::TaggedRange)      = flags(text_span.head)
first_byte(text_span::TaggedRange) = text_span.first_byte
last_byte(text_span::TaggedRange)  = text_span.last_byte
span(text_span::TaggedRange)       = last_byte(text_span) - first_byte(text_span) + 1

struct Diagnostic
    text_span::TaggedRange
    message::String
end

function show_diagnostic(io::IO, diagnostic::Diagnostic, code)
    printstyled(io, "Error: ", color=:light_red)
    print(io, diagnostic.message, ":\n")
    p = first_byte(diagnostic.text_span)
    q = last_byte(diagnostic.text_span)
    if !isvalid(code, q)
        # Transform byte range into valid text range
        q = prevind(code, q)
    end
    if q < p || (p == q && code[p] == '\n')
        # An empty or invisible range!  We expand it symmetrically to make it
        # visible.
        p = max(firstindex(code), prevind(code, p))
        q = min(lastindex(code), nextind(code, q))
    end
    print(io, code[1:prevind(code, p)])
    _printstyled(io, code[p:q]; color=(100,40,40))
    print(io, code[nextind(code, q):end], '\n')
end

#-------------------------------------------------------------------------------
"""
ParseStream provides an IO interface for the parser. It
- Wraps the lexer from Tokenize.jl with a short lookahead buffer
- Removes whitespace and comment tokens, shifting them into the output implicitly

This is simililar to rust-analyzer's
[TextTreeSink](https://github.com/rust-analyzer/rust-analyzer/blob/4691a0647b2c96cc475d8bbe7c31fe194d1443e7/crates/syntax/src/parsing/text_tree_sink.rs)
"""
mutable struct ParseStream
    lexer::Tokenize.Lexers.Lexer{IOBuffer,RawToken}
    lookahead::Vector{SyntaxToken}
    spans::Vector{TaggedRange}
    diagnostics::Vector{Diagnostic}
    # First byte of next token
    next_byte::Int
    # Counter for number of peek()s we've done without making progress via a bump()
    peek_count::Int
end

function ParseStream(code)
    lexer = Tokenize.tokenize(code, RawToken)
    ParseStream(lexer,
                Vector{SyntaxToken}(),
                Vector{TaggedRange}(),
                Vector{Diagnostic}(),
                1,
                0)
end

function Base.show(io::IO, mime::MIME"text/plain", stream::ParseStream)
    println(io, "ParseStream at position $(stream.next_byte)")
end

# Buffer up until the next non-whitespace token.
# This can buffer more than strictly necessary when newlines are significant,
# but this is not a big problem.
function _buffer_lookahead_tokens(stream::ParseStream)
    had_whitespace = false
    had_newline    = false
    while true
        raw = Tokenize.Lexers.next_token(stream.lexer)
        k = TzTokens.exactkind(raw)

        was_whitespace = k in (K"Whitespace", K"Comment", K"NewlineWs")
        was_newline    = k == K"NewlineWs"
        had_whitespace |= was_whitespace
        had_newline    |= was_newline
        push!(stream.lookahead, SyntaxToken(raw, had_whitespace, had_newline))
        if !was_whitespace
            break
        end
    end
end

function _lookahead_index(stream::ParseStream, n::Integer, skip_newlines::Bool)
    i = 1
    while true
        if i > length(stream.lookahead)
            _buffer_lookahead_tokens(stream)
        end
        k = kind(stream.lookahead[i])
        is_skipped =  k ∈ (K"Whitespace", K"Comment") ||
                     (k == K"NewlineWs" && skip_newlines)
        if !is_skipped
            if n == 1
                return i
            end
            n -= 1
        end
        i += 1
    end
end

"""
    peek_token(stream [, n=1])

Look ahead in the stream `n` tokens, returning a SyntaxToken
"""
function peek_token(stream::ParseStream, n::Integer=1, skip_newlines=false)
    stream.peek_count += 1
    if stream.peek_count > 100_000
        error("The parser seems stuck at byte $(position(stream))")
    end
    stream.lookahead[_lookahead_index(stream, n, skip_newlines)]
end

"""
    peek_token(stream [, n=1])

Look ahead in the stream `n` tokens, returning a Kind
"""
function peek(stream::ParseStream, n::Integer=1, skip_newlines=false)
    kind(peek_token(stream, n, skip_newlines))
end

# Bump the next `n` tokens
# flags and new_kind are applied to any non-trivia tokens
function _bump_n(stream::ParseStream, n::Integer, flags, new_kind=K"Nothing")
    if n <= 0
        return
    end
    for i=1:n
        tok = stream.lookahead[i]
        k = kind(tok)
        if k == K"EndMarker"
            break
        end
        is_trivia = k ∈ (K"Whitespace", K"Comment", K"NewlineWs")
        f = is_trivia ? TRIVIA_FLAG : flags
        k = (is_trivia || new_kind == K"Nothing") ? k : new_kind
        span = TaggedRange(SyntaxHead(k, f), first_byte(tok), last_byte(tok))
        push!(stream.spans, span)
    end
    Base._deletebeg!(stream.lookahead, n)
    stream.next_byte = last_byte(last(stream.spans)) + 1
    # Defuse the time bomb
    stream.peek_count = 0
end

"""
    bump(stream [, flags=EMPTY_FLAGS])

Shift the current token into the output as a new text span with the given
`flags`.
"""
function bump(stream::ParseStream, flags=EMPTY_FLAGS; skip_newlines=false,
              error=nothing, new_kind=K"Nothing")
    emark = position(stream)
    _bump_n(stream, _lookahead_index(stream, 1, skip_newlines), flags, new_kind)
    if !isnothing(error)
        emit(stream, emark, K"error", TRIVIA_FLAG, error=error)
    end
    # Return last token location in output if needed for set_flags!
    return lastindex(stream.spans)
end

"""
Bump comments and whitespace tokens preceding the next token
"""
function bump_trivia(stream::ParseStream; skip_newlines=false, error=nothing)
    emark = position(stream)
    _bump_n(stream, _lookahead_index(stream, 1, skip_newlines) - 1, EMPTY_FLAGS)
    if !isnothing(error)
        emit(stream, emark, K"error", TRIVIA_FLAG, error=error)
    end
    return lastindex(stream.spans)
end

function bump_invisible(stream::ParseStream, kind, flags=EMPTY_FLAGS;
                        error=nothing)
    emit(stream, position(stream), kind, flags, error=error)
    return lastindex(stream.spans)
end

"""
Hack: Reset kind or flags of an existing token in the output stream

This is necessary on some occasions when we don't know whether a token will
have TRIVIA_FLAG set until after consuming more input, or when we need to
insert a invisible token like core_@doc but aren't yet sure it'll be needed -
see bump_invisible()
"""
function reset_token!(stream::ParseStream, mark;
                      kind=nothing, flags=nothing)
    text_span = stream.spans[mark]
    k = isnothing(kind) ? (@__MODULE__).kind(text_span) : kind
    f = isnothing(flags) ? (@__MODULE__).flags(text_span) : flags
    stream.spans[mark] = TaggedRange(SyntaxHead(k, f),
                                  first_byte(text_span), last_byte(text_span))
end

#=
function accept(stream::ParseStream, k::Kind)
    if peek(stream) != k
        return false
    else
        bump(stream, TRIVIA_FLAG)
    end
end
=#

#=
function bump(stream::ParseStream, k::Kind, flags=EMPTY_FLAGS)
    @assert peek(stream) == k
    bump(stream, flags)
end
=#

function Base.position(stream::ParseStream)
    return stream.next_byte
end

"""
    emit(stream, start_mark, kind, flags = EMPTY_FLAGS; error=nothing)

Emit a new text span into the output which covers source bytes from
`start_mark` to the end of the most recent token which was `bump()`'ed.
The `start_mark` of the span should be a previous return value of
`position()`.
"""
function emit(stream::ParseStream, start_mark::Integer, kind::Kind,
              flags::RawFlags = EMPTY_FLAGS; error=nothing)
    text_span = TaggedRange(SyntaxHead(kind, flags), start_mark, stream.next_byte-1)
    if !isnothing(error)
        push!(stream.diagnostics, Diagnostic(text_span, error))
    end
    push!(stream.spans, text_span)
    return nothing
end

"""
Emit a diagnostic at the position of the next token

If `whitespace` is true, the diagnostic is positioned on the whitespace before
the next token. Otherwise it's positioned at the next token as returned by `peek()`.
"""
function emit_diagnostic(stream::ParseStream, mark=nothing; error, whitespace=false)
    i = _lookahead_index(stream, 1, true)
    begin_tok_i = i
    end_tok_i = i
    if whitespace
        # It's the whitespace which is the error. Find the range of the current
        # whitespace.
        begin_tok_i = 1
        end_tok_i = is_whitespace(stream.lookahead[i]) ? i : max(1, i-1)
    end
    mark = isnothing(mark) ? first_byte(stream.lookahead[begin_tok_i]) : mark
    err_end = last_byte(stream.lookahead[end_tok_i])
    # It's a bit weird to require supplying a SyntaxHead here...
    text_span = TaggedRange(SyntaxHead(K"error", EMPTY_FLAGS), mark, err_end)
    push!(stream.diagnostics, Diagnostic(text_span, error))
end

# Tree construction from the list of text spans held by ParseStream
#
# Note that this is largely independent of GreenNode, and could easily be
# made completely independent with a tree builder interface.

function _push_node!(stack, text_span::TaggedRange, children=nothing)
    if isnothing(children)
        node = GreenNode(head(text_span), span(text_span))
        push!(stack, (text_span=text_span, node=node))
    else
        node = GreenNode(head(text_span), span(text_span), children)
        push!(stack, (text_span=text_span, node=node))
    end
end

function to_raw_tree(st; wrap_toplevel_as_kind=nothing)
    stack = Vector{@NamedTuple{text_span::TaggedRange,node::GreenNode}}()
    for text_span in st.spans
        if kind(text_span) == K"TOMBSTONE"
            # Ignore invisible tokens which were created but never finalized.
            # See bump_invisible()
            continue
        end

        if isempty(stack) || first_byte(text_span) > last_byte(stack[end].text_span)
            # A leaf node (span covering a single token):
            # [a][b][stack[end]]
            #                   [text_span]
            _push_node!(stack, text_span)
            continue
        end
        # An interior node, span covering multiple tokens:
        #
        # [a][b][stack[end]]
        #    [    text_span]
        j = length(stack)
        while j > 1 && first_byte(text_span) <= first_byte(stack[j-1].text_span)
            j -= 1
        end
        children = [stack[k].node for k = j:length(stack)]
        resize!(stack, j-1)
        _push_node!(stack, text_span, children)
    end
    # show(stdout, MIME"text/plain"(), stack[1].node)
    if length(stack) == 1
        return only(stack).node
    elseif !isnothing(wrap_toplevel_as_kind)
        # Mostly for debugging
        children = [x.node for x in stack]
        return GreenNode(SyntaxHead(wrap_toplevel_as_kind), children...)
    else
        error("Found multiple nodes at top level")
    end
end

function show_diagnostics(io::IO, stream::ParseStream, code)
    for d in stream.diagnostics
        show_diagnostic(io, d, code)
    end
end

#-------------------------------------------------------------------------------
"""
ParseState carries parser context as we recursively descend into the parse
tree. For example, normally `x -y` means `(x) - (y)`, but when parsing matrix
literals we're in `space_sensitive` mode, and `[x -y]` means [(x) (-y)].
"""
struct ParseState
    stream::ParseStream
    # Vesion of Julia we're parsing this code for. May be different from VERSION!
    julia_version::VersionNumber

    # Disable range colon for parsing ternary conditional operator
    range_colon_enabled::Bool
    # In space-sensitive mode "x -y" is 2 expressions, not a subtraction
    space_sensitive::Bool
    # Seeing `for` stops parsing macro arguments and makes a generator
    for_generator::Bool
    # Treat 'end' like a normal symbol instead of a reserved word
    end_symbol::Bool
    # Treat newline like ordinary whitespace instead of as a potential separator
    whitespace_newline::Bool
    # Enable parsing `where` with high precedence
    where_enabled::Bool
end

# Normal context
function ParseState(stream::ParseStream; julia_version=VERSION)
    ParseState(stream, julia_version, true, false, true, false, false, false)
end

function ParseState(ps::ParseState; range_colon_enabled=nothing,
                    space_sensitive=nothing, for_generator=nothing,
                    end_symbol=nothing, whitespace_newline=nothing,
                    where_enabled=nothing)
    ParseState(ps.stream, ps.julia_version,
        range_colon_enabled === nothing ? ps.range_colon_enabled : range_colon_enabled,
        space_sensitive === nothing ? ps.space_sensitive : space_sensitive,
        for_generator === nothing ? ps.for_generator : for_generator,
        end_symbol === nothing ? ps.end_symbol : end_symbol,
        whitespace_newline === nothing ? ps.whitespace_newline : whitespace_newline,
        where_enabled === nothing ? ps.where_enabled : where_enabled)
end

function peek(ps::ParseState, n=1; skip_newlines=nothing)
    skip_nl = isnothing(skip_newlines) ? ps.whitespace_newline : skip_newlines
    peek(ps.stream, n, skip_nl)
end

function peek_token(ps::ParseState, n=1; skip_newlines=nothing)
    skip_nl = isnothing(skip_newlines) ? ps.whitespace_newline : skip_newlines
    peek_token(ps.stream, n, skip_nl)
end

function bump(ps::ParseState, flags=EMPTY_FLAGS; skip_newlines=nothing, kws...)
    skip_nl = isnothing(skip_newlines) ? ps.whitespace_newline : skip_newlines
    bump(ps.stream, flags; skip_newlines=skip_nl, kws...)
end

function bump_trivia(ps::ParseState, args...; kws...)
    bump_trivia(ps.stream, args...; kws...)
end

"""
Bump a new zero-width "invisible" token at the current stream position. These
can be useful in several situations.

When a token is implied but not present in the source text:
* Implicit multiplication - the * is invisible
  `2x  ==>  (call 2 * x)`
* Docstrings - the macro name is invisible
  `"doc" foo() = 1   ==>  (macrocall (core @doc) . (= (call foo) 1))`
* Big integer literals - again, an invisible macro name
  `11111111111111111111  ==>  (macrocall (core @int128_str) . 11111111111111111111)`
"""
function bump_invisible(ps::ParseState, args...; kws...)
    bump_invisible(ps.stream, args...; kws...)
end

function reset_token!(ps::ParseState, args...; kws...)
    reset_token!(ps.stream, args...; kws...)
end

function Base.position(ps::ParseState, args...)
    position(ps.stream, args...)
end

function emit(ps::ParseState, args...; kws...)
    emit(ps.stream, args...; kws...)
end

function emit_diagnostic(ps::ParseState, args...; kws...)
    emit_diagnostic(ps.stream, args...; kws...)
end

