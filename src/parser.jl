"""
ParseState carries parser context as we recursively descend into the parse
tree. For example, normally `x -y` means `(x) - (y)`, but when parsing matrix
literals we're in "whitespace sensitive" mode, and `[x -y]` means [(x) (-y)].
"""
struct ParseState
    tokens::TokenStream
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
function ParseState(tokens::TokenStream; julia_version=VERSION)
    ParseState(tokens, julia_version, true, false, true, false, false, false)
end

function ParseState(ps::ParseState; range_colon_enabled=nothing,
                    space_sensitive=nothing, for_generator=nothing,
                    end_symbol=nothing, whitespace_newline=nothing,
                    where_enabled=nothing)
    ParseState(ps.tokens, ps.julia_version,
        range_colon_enabled === nothing ? ps.range_colon_enabled : range_colon_enabled,
        space_sensitive === nothing ? ps.space_sensitive : space_sensitive,
        for_generator === nothing ? ps.for_generator : for_generator,
        end_symbol === nothing ? ps.end_symbol : end_symbol,
        whitespace_newline === nothing ? ps.whitespace_newline : whitespace_newline,
        where_enabled === nothing ? ps.where_enabled : where_enabled)
end

take_token!(ps::ParseState) = take_token!(ps.tokens)
require_token(ps::ParseState) = require_token(ps.tokens)
peek_token(ps::ParseState) = peek_token(ps.tokens)
put_back!(ps::ParseState, tok::RawToken) = put_back!(ps.tokens, tok)

#-------------------------------------------------------------------------------
# Parser

function is_closing_token(ps::ParseState, tok)
    k = kind(tok)
    return k in (K"else", K"elseif", K"catch", K"finally",
                 K",", K")", K"]", K"}", K";",
                 K"EndMarker") || (k == K"end" && !ps.end_symbol)
end

function has_whitespace_prefix(tok::SyntaxToken)
    tok.leading_trivia.kind == K" "
end

function TODO(str)
    error("TODO: $str")
end

# Parse numbers, identifiers, parenthesized expressions, lists, vectors, etc.
function parse_atom(ps::ParseState; checked::Bool=true)::RawSyntaxNode
    tok = require_token(ps)
    tok_kind = kind(tok)
    # TODO: Reorder these to put most likely tokens first
    if tok_kind == K":" # symbol/expression quote
        take_token!(ps)
        next = peek_token(ps)
        if is_closing_token(ps, next) && (kind(next) != K"Keyword" ||
                                          has_whitespace_prefix(next))
            return RawSyntaxNode(tok)
        elseif has_whitespace_prefix(next)
            error("whitespace not allowed after \":\" used for quoting")
        elseif kind(next) == K"NewlineWs"
            error("newline not allowed after \":\" used for quoting")
        else
            # Being inside quote makes `end` non-special again. issue #27690
            ps1 = ParseState(ps, end_symbol=false)
            return RawSyntaxNode(K"quote", parse_atom(ps1, checked=false))
        end
    elseif tok_kind == K"=" # misplaced =
        error("unexpected `=`")
    elseif tok_kind == K"Identifier"
        if checked
            TODO("Checked identifier names")
        end
        take_token!(ps)
        return RawSyntaxNode(tok)
    elseif tok_kind == K"VarIdentifier"
        take_token!(ps)
        return RawSyntaxNode(tok)
    elseif tok_kind == K"(" # parens or tuple
        take_token!(ps)
        return parse_paren(ps, checked)
    elseif tok_kind == K"[" # cat expression
        # NB: Avoid take_token! here? It's better to not consume tokens early
        # take_token!(ps)
        vex = parse_cat(ps, tok, K"]", ps.end_symbol)
    elseif tok_kind == K"{" # cat expression
        take_token!(ps)
        TODO("""parse_cat(ps, K"}", )""")
    elseif tok_kind == K"`"
        TODO("(macrocall (core @cmd) ...)")
        # return Expr(:macrocall, Expr(:core, Symbol("@cmd")),
    elseif isliteral(tok_kind)
        take_token!(ps)
        return RawSyntaxNode(tok)
    elseif is_closing_token(tok)
        error("unexpected: $tok")
    else
        error("invalid syntax: `$tok`")
    end
end

# parse `a@b@c@...` for some @
#
# `is_separator` - predicate
# `head` the expression head to yield in the result, e.g. "a;b" => (block a b)
# `is_closer` - predicate to identify tokens that stop parsing
#               however, this doesn't consume the closing token, just looks at it
function parse_Nary(ps::ParseState, down::Function, is_separator::Function,
                    result_kind, is_closer::Function)
end

# flisp: parse-docstring
# Parse statement with possible docstring
function parse_statement_with_doc(ps::ParseState)
    parse_eq(ps)
    # TODO: Detect docstrings
end

# flisp: parse-cat
# Parse syntax inside of `[]` or `{}`
function parse_cat(ps0::ParseState, opening_tok, closer, last_end_symbol::Bool)
    ps = ParseState(ps0, range_colon_enabled=true,
                    space_sensitive=true,
                    where_enabled=true,
                    whitespace_newline=false,
                    for_generator=true)
    if require_token(ps) == closer
        take_token!(ps)
        return 
    end
end

#-------------------------------------------------------------------------------

# the principal non-terminals follow, in increasing precedence order

#function parse_block(ps::ParseState, down=parse_eq)
#end

# flisp: parse-stmts
# `;` at the top level produces a sequence of top level expressions
function parse_statements(ps::ParseState)
    parse_Nary(ps, parse_statement)
end

# flisp: parse-eq
function parse_eq(ps::ParseState)
    parse_assignment(ps, parse_comma)
end

# flisp: parse-eq*
# parse_eq_2 is used where commas are special, for example in an argument list
# function parse_eq_2

function parse_assignment(ps::ParseState, down)
    ex = down(ps)
    t = peek_token(ps)
    if !is_prec_assignment(t)
        return ex
    end
    take_token!(ps)
    if kind(t) == K"~"
        # ~ is the only non-syntactic assignment-precedence operator
        TODO("Turn ~ into a call node")
    else
        RawSyntaxNode
    end
end

#-------------------------------------------------------------------------------

function parse(code)
    tokens = JuliaSyntax.TokenStream(code)
    parse_statements(tokens)
end
