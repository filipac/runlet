<?php

declare(strict_types=1);

/*
 * Magic comments (#10): inline values without dump() calls or temporary variables.
 * (Below, `*\/` stands for the end of a comment.)
 *
 *     $users = User::all(); //?            the line's value (here: the assigned value)
 *     $total = $a /*?*\/ + $b;             the value of the expression right before the comment
 *     $query->get() /*?->count()*\/        a projection of that value; the chain still gets the value
 *     sleep(1); /*?.*\/                    milliseconds since the previous /*?.*\/ (or the start)
 *
 * MagicComments finds the comments with the tokenizer (so text inside strings, heredocs, other
 * comments, and inline HTML never counts) and the expressions they refer to with php-parser,
 * then inserts calls to Probe at byte offsets. Nothing is pretty-printed or moved, and nothing
 * inserted contains a newline, so every line keeps its number. A comment in a place where a
 * call would change what the code does (an assignment target, a by-reference argument, isset(),
 * a constant expression, …) is left alone and reported, and the run is otherwise unaffected.
 *
 * Probe records `inline` events while the code runs: the first 100 hits of each probe with
 * their values, then counts with a value sampled about four times a second, then the final
 * count when the run finishes.
 *
 * This file must stay compatible with PHP 7.4 syntax and runtime.
 */

namespace RunletRunner;

use RunletVendor\PhpParser\Node;
use RunletVendor\PhpParser\Node\Expr;
use RunletVendor\PhpParser\Node\Stmt;

final class MagicComments
{
    /** Contexts an expression can be in (see childContext()). */
    private const READ = 'read';
    private const WRITE = 'write';
    private const REF = 'ref';
    private const REF_ITEM = 'refItem';
    private const ISSET = 'isset';
    private const CONSTANT = 'const';
    private const INTERPOLATION = 'interpolation';
    private const NO_WRAP = 'noWrap';
    private const ARGUMENT = 'arg';
    private const ARGUMENT_CHAIN = 'argChain';
    private const ARGUMENT_NODE = 'argNode';
    private const REF_SYNTAX = 'refSyntax';

    private const PROBE = '\\RunletRunner\\Probe::';
    private const PROJECTION_VARIABLE = '$__runletProbe';

    /** @var string */
    private $source;
    /** @var \RunletVendor\PhpParser\Parser */
    private $parser;
    /** @var array<int, array{0: int|null, 1: string, 2: int, 3: int}> [token id or null, text, byte offset, line] */
    private $tokens = [];
    /** @var int[] token start offsets, ascending */
    private $offsets = [];
    /** @var array<int, int> bracket token index => matching token index, both ways */
    private $match = [];
    /** @var array<int, array<int, array<string, mixed>>> expressions by end offset, outermost first */
    private $exprByEnd = [];
    /** @var array<int, array<int, Node\Stmt>> statements by end offset, outermost first */
    private $stmtByEnd = [];
    /** @var array<int, array{open: int, close: int, stmts: Node\Stmt[]}> statement lists */
    private $regions = [];
    /** @var array<string, Stmt\Function_> functions the snippet declares, by lowercase name */
    private $functions = [];
    /** @var array<string, Stmt\ClassLike> classes the snippet declares, by lowercase name */
    private $classes = [];
    /** @var Stmt\Expression|null the last statement, which the compiler turns into `return …;` */
    private $returned;

    /** @param \RunletVendor\PhpParser\Parser $parser */
    private function __construct(string $source, $parser, ?Stmt\Expression $returned)
    {
        $this->source = $source;
        $this->parser = $parser;
        $this->returned = $returned;
    }

    /** Quick check before any work: the snippet mentions a magic comment at all. */
    public static function mentioned(string $source): bool
    {
        return strpos($source, '//?') !== false || strpos($source, '/*?') !== false;
    }

    /**
     * Plans the probes for $source (already parsed into $statements by $parser).
     *
     * Returns `edits` ([offset, deleteLength, text, group, key1, key2], see SnippetCompiler),
     * `probes` (id => [line, kind, comment]), and `rejected` ([line, comment, reason]).
     * $returned is the final expression statement the compiler returns as the result:
     * a mark after it wraps its expression instead, since nothing after a return runs.
     *
     * @param Node\Stmt[] $statements
     * @param \RunletVendor\PhpParser\Parser $parser
     * @return array{edits: array<int, array<int, mixed>>, probes: array<int, array{line: int, kind: string, comment: string}>, rejected: array<int, array{line: int, comment: string, reason: string}>}
     */
    public static function plan(string $source, array $statements, $parser, ?Stmt\Expression $returned = null): array
    {
        $planner = new self($source, $parser, $returned);

        return $planner->run($statements);
    }

    /**
     * @param Node\Stmt[] $statements
     * @return array{edits: array<int, array<int, mixed>>, probes: array<int, array{line: int, kind: string, comment: string}>, rejected: array<int, array{line: int, comment: string, reason: string}>}
     */
    private function run(array $statements): array
    {
        $comments = $this->tokenize();
        $result = ['edits' => [], 'probes' => [], 'rejected' => []];
        if ($comments === []) {
            return $result;
        }
        $this->collectDeclarations($statements, '');
        $this->regions[] = ['open' => -1, 'close' => strlen($this->source), 'stmts' => $statements];
        $scope = ['byRef' => false, 'ns' => '', 'uses' => $this->collectUses($statements)];
        foreach ($statements as $statement) {
            $this->walk($statement, self::READ, null, '', null, $scope);
        }

        $id = 0;
        foreach ($comments as $comment) {
            $edits = [];
            $kind = '';
            $reason = $this->resolve($comment, $id + 1, $edits, $kind);
            if ($reason !== null) {
                $result['rejected'][] = ['line' => $comment['line'], 'comment' => self::shortComment($comment['text']), 'reason' => $reason];
                continue;
            }
            $id++;
            $result['probes'][$id] = ['line' => $comment['line'], 'kind' => $kind, 'comment' => self::shortComment($comment['text'])];
            foreach ($edits as $edit) {
                $result['edits'][] = $edit;
            }
        }

        return $result;
    }

    // MARK: Tokens

    /**
     * Tokenizes the source and returns its magic comments in source order.
     *
     * @return array<int, array{form: string, text: string, offset: int, line: int, index: int, projection: string|null}>
     */
    private function tokenize(): array
    {
        $offset = 0;
        $line = 1;
        $stack = [];
        $comments = [];
        foreach (token_get_all($this->source) as $token) {
            if (is_array($token)) {
                [$id, $text] = $token;
            } else {
                $id = null;
                $text = $token;
            }
            $index = count($this->tokens);
            $this->tokens[] = [$id, $text, $offset, $line];
            $this->offsets[] = $offset;
            if ($id === null) {
                if ($text === '(' || $text === '{' || $text === '[') {
                    $stack[] = $index;
                } elseif ($text === ')' || $text === '}' || $text === ']') {
                    $open = array_pop($stack);
                    if ($open !== null) {
                        $this->match[$open] = $index;
                        $this->match[$index] = $open;
                    }
                }
            } elseif ($id === T_CURLY_OPEN || $id === T_DOLLAR_OPEN_CURLY_BRACES) {
                $stack[] = $index;
            } elseif ($id === T_COMMENT) {
                $form = self::form($text);
                if ($form !== null) {
                    $comments[] = ['form' => $form[0], 'text' => rtrim($text), 'offset' => $offset, 'line' => $line, 'index' => $index, 'projection' => $form[1]];
                }
            }
            $offset += strlen($text);
            $line += substr_count($text, "\n");
        }

        return $comments;
    }

    /**
     * The magic-comment form of a comment token, with a projection's chain: `line` (`//?`),
     * `value` (`/*?*\/`), `time` (`/*?.*\/`), `projection` (`/*?->…*\/` or `/*??->…*\/`).
     *
     * @return array{0: string, 1: string|null}|null
     */
    private static function form(string $text): ?array
    {
        if (preg_match('/^\/\/\?[ \t]*\r?\n?$/', $text)) {
            return ['line', null];
        }
        if (preg_match('/^\/\*\?\s*\*\/$/', $text)) {
            return ['value', null];
        }
        if (preg_match('/^\/\*\?\.\s*\*\/$/', $text)) {
            return ['time', null];
        }
        if (preg_match('/^\/\*\?(\??->.*?)\s*\*\/$/s', $text, $match)) {
            return ['projection', $match[1]];
        }

        return null;
    }

    private static function shortComment(string $text): string
    {
        $text = (string) preg_replace('/\s+/', ' ', $text);

        return strlen($text) > 80 ? substr($text, 0, 77) . '…' : $text;
    }

    private static function significant(?int $id): bool
    {
        return $id !== T_WHITESPACE && $id !== T_COMMENT && $id !== T_DOC_COMMENT;
    }

    /** Index of the first significant token starting at or after $offset. */
    private function nextSignificant(int $offset): ?int
    {
        $low = 0;
        $high = count($this->offsets);
        while ($low < $high) {
            $middle = intdiv($low + $high, 2);
            if ($this->offsets[$middle] < $offset) {
                $low = $middle + 1;
            } else {
                $high = $middle;
            }
        }
        for ($i = $low, $count = count($this->tokens); $i < $count; $i++) {
            if (self::significant($this->tokens[$i][0])) {
                return $i;
            }
        }

        return null;
    }

    /** Index of the last significant token before token $index. */
    private function previousSignificant(int $index): ?int
    {
        for ($i = $index - 1; $i >= 0; $i--) {
            if (self::significant($this->tokens[$i][0])) {
                return $i;
            }
        }

        return null;
    }

    private function tokenIndexAt(int $offset): ?int
    {
        $low = 0;
        $high = count($this->offsets) - 1;
        while ($low <= $high) {
            $middle = intdiv($low + $high, 2);
            if ($this->offsets[$middle] === $offset) {
                return $middle;
            }
            if ($this->offsets[$middle] < $offset) {
                $low = $middle + 1;
            } else {
                $high = $middle - 1;
            }
        }

        return null;
    }

    private function tokenText(?int $index): ?string
    {
        return $index === null ? null : $this->tokens[$index][1];
    }

    private function tokenEnd(int $index): int
    {
        return $this->tokens[$index][2] + strlen($this->tokens[$index][1]) - 1;
    }

    // MARK: Syntax tree

    /**
     * Records every expression (with the context it is evaluated in), every statement, and
     * every statement list ("region") where a statement can be inserted.
     *
     * @param array{call: Node, index: int, arg: Node\Arg}|null $call
     * @param array{byRef: bool, ns: string, uses: array<string, array<string, string>>} $scope
     */
    private function walk(Node $node, string $context, ?Node $parent, string $slot, ?array $call, array $scope): void
    {
        $start = $node->getStartFilePos();
        $end = $node->getEndFilePos();
        if ($start >= 0 && $end >= $start) {
            if ($node instanceof Expr) {
                $this->exprByEnd[$end][] = ['node' => $node, 'context' => $context, 'parent' => $parent, 'slot' => $slot, 'call' => $call, 'scope' => $scope];
            } elseif ($node instanceof Stmt && !($node instanceof Stmt\Nop)) {
                $this->stmtByEnd[$end][] = $node;
            }
        }

        $inner = $scope;
        if ($node instanceof Stmt\Namespace_) {
            $inner['ns'] = $node->name !== null ? $node->name->toString() : '';
            $inner['uses'] = $this->collectUses($node->stmts);
        }
        if ($node instanceof Node\FunctionLike) {
            $inner['byRef'] = $node->returnsByRef();
        }
        $this->recordRegions($node);

        foreach ($node->getSubNodeNames() as $name) {
            $value = $node->$name;
            $children = is_array($value) ? $value : [$value];
            foreach ($children as $index => $child) {
                if (!$child instanceof Node) {
                    continue;
                }
                [$childContext, $childCall] = $this->childContext($node, $name, $child, $context, is_int($index) ? $index : 0, $call, $inner);
                $this->walk($child, $childContext, $node, $name, $childCall, $inner);
            }
        }
    }

    /**
     * How $child (in $node's $name) is evaluated: read (a call may wrap it), written,
     * taken by reference, checked by isset/empty/??, a constant expression, the start of a
     * `{$…}` interpolation, a call argument (whether by reference depends on the callee), or
     * a slot that cannot hold a call at all.
     *
     * @param array{call: Node, index: int, arg: Node\Arg}|null $call
     * @param array{byRef: bool, ns: string, uses: array<string, array<string, string>>} $scope
     * @return array{0: string, 1: array{call: Node, index: int, arg: Node\Arg}|null}
     */
    private function childContext(Node $node, string $name, Node $child, string $context, int $index, ?array $call, array $scope): array
    {
        if ($context === self::CONSTANT || $name === 'attrGroups' || $node instanceof Node\AttributeGroup || $node instanceof Node\Attribute) {
            return [self::CONSTANT, null];
        }
        // Declarations.
        if ($node instanceof Node\Param) {
            return [$name === 'var' ? self::WRITE : ($name === 'default' ? self::CONSTANT : self::READ), null];
        }
        if ($node instanceof Node\Const_ || $node instanceof Node\DeclareItem) {
            return [$name === 'value' ? self::CONSTANT : self::READ, null];
        }
        if ($node instanceof Node\PropertyItem) {
            return [$name === 'default' ? self::CONSTANT : self::READ, null];
        }
        if ($node instanceof Node\StaticVar) {
            return [$name === 'var' ? self::WRITE : self::CONSTANT, null];
        }
        if ($node instanceof Stmt\EnumCase) {
            return [$name === 'expr' ? self::CONSTANT : self::READ, null];
        }
        if ($node instanceof Node\ClosureUse || $node instanceof Stmt\Global_ || $node instanceof Stmt\Unset_) {
            return [self::WRITE, null];
        }
        if ($node instanceof Stmt\Catch_) {
            return [$name === 'var' ? self::WRITE : self::READ, null];
        }
        // Writes.
        if ($node instanceof Expr\Assign || $node instanceof Expr\AssignOp) {
            return [$name === 'var' ? self::WRITE : self::READ, null];
        }
        if ($node instanceof Expr\AssignRef) {
            return [$name === 'var' ? self::WRITE : self::REF, null];
        }
        if ($node instanceof Expr\PreInc || $node instanceof Expr\PreDec || $node instanceof Expr\PostInc || $node instanceof Expr\PostDec) {
            return [self::WRITE, null];
        }
        if ($node instanceof Stmt\Foreach_) {
            if ($name === 'expr') {
                return [$node->byRef ? self::REF : self::READ, null];
            }

            return [$name === 'keyVar' || $name === 'valueVar' ? self::WRITE : self::READ, null];
        }
        if ($node instanceof Expr\List_) {
            return [self::WRITE, null];
        }
        if ($node instanceof Expr\Array_) {
            return [$context === self::WRITE || $context === self::REF ? self::WRITE : self::READ, null];
        }
        if ($node instanceof Node\ArrayItem) {
            if ($name !== 'value') {
                return [self::READ, null];
            }
            if ($context === self::WRITE) {
                return [self::WRITE, null];
            }

            return [$node->byRef ? self::REF_ITEM : self::READ, null];
        }
        // isset(), empty(), and ?? read without warnings.
        if ($node instanceof Expr\Isset_ || $node instanceof Expr\Empty_) {
            return [self::ISSET, null];
        }
        if ($node instanceof Expr\BinaryOp\Coalesce) {
            return [$name === 'left' ? self::ISSET : self::READ, null];
        }
        // `"{$…}"`: the expression must start with a variable.
        if ($node instanceof Node\Scalar\InterpolatedString || $node instanceof Expr\ShellExec) {
            return [self::INTERPOLATION, null];
        }
        // Fetch chains carry their context to the start of the chain.
        if ($node instanceof Expr\ArrayDimFetch) {
            return $name === 'var' ? [self::chain($context), $call] : [self::READ, null];
        }
        if ($node instanceof Expr\PropertyFetch || $node instanceof Expr\NullsafePropertyFetch) {
            return $name === 'var' ? [self::chain($context), $call] : [self::NO_WRAP, null];
        }
        if ($node instanceof Expr\StaticPropertyFetch || $node instanceof Expr\ClassConstFetch || $node instanceof Expr\Variable) {
            return [self::NO_WRAP, null];
        }
        if ($node instanceof Expr\MethodCall || $node instanceof Expr\NullsafeMethodCall || $node instanceof Expr\StaticCall || $node instanceof Expr\FuncCall || $node instanceof Expr\New_) {
            if ($name === 'args') {
                return $child instanceof Node\Arg ? [self::ARGUMENT_NODE, ['call' => $node, 'index' => $index, 'arg' => $child]] : [self::READ, null];
            }
            if (($node instanceof Expr\MethodCall || $node instanceof Expr\NullsafeMethodCall) && $name === 'var') {
                return [$context === self::INTERPOLATION || $context === self::NO_WRAP ? $context : self::READ, null];
            }
            if ($node instanceof Expr\FuncCall && $name === 'name') {
                return [$context === self::INTERPOLATION || $context === self::NO_WRAP ? $context : self::READ, null];
            }
            if ($node instanceof Expr\New_ && $child instanceof Stmt\Class_) {
                return [self::READ, null];
            }

            return [self::NO_WRAP, null];
        }
        if ($node instanceof Expr\Instanceof_) {
            return [$name === 'expr' ? self::READ : self::NO_WRAP, null];
        }
        if ($node instanceof Node\Arg) {
            if ($name !== 'value') {
                return [self::READ, null];
            }

            return $node->byRef ? [self::REF_SYNTAX, null] : [self::ARGUMENT, $call];
        }
        // Values returned or yielded by reference.
        if ($node instanceof Stmt\Return_ || ($node instanceof Expr\Yield_ && $name === 'value')) {
            return [$scope['byRef'] ? self::REF : self::READ, null];
        }
        if (($node instanceof Expr\ArrowFunction && $name === 'expr') || ($node instanceof Node\PropertyHook && $name === 'body' && $child instanceof Expr)) {
            return [$node->byRef ? self::REF : self::READ, null];
        }

        return [self::READ, null];
    }

    /** The context of the expression a fetch reads from: a written `$a[1]` writes into `$a`. */
    private static function chain(string $context): string
    {
        switch ($context) {
            case self::WRITE:
            case self::REF:
            case self::REF_ITEM:
                return self::WRITE;
            case self::ARGUMENT:
            case self::ARGUMENT_CHAIN:
                return self::ARGUMENT_CHAIN;
            case self::ISSET:
            case self::INTERPOLATION:
            case self::NO_WRAP:
            case self::CONSTANT:
                return $context;
            default:
                return self::READ;
        }
    }

    /**
     * `use` imports of one namespace (or the file): class and function aliases.
     *
     * @param Node\Stmt[] $statements
     * @return array<string, array<string, string>>
     */
    private function collectUses(array $statements): array
    {
        $uses = ['class' => [], 'function' => []];
        foreach ($statements as $statement) {
            if ($statement instanceof Stmt\Use_ || $statement instanceof Stmt\GroupUse) {
                $prefix = $statement instanceof Stmt\GroupUse ? $statement->prefix->toString() . '\\' : '';
                foreach ($statement->uses as $use) {
                    $type = $use->type !== Stmt\Use_::TYPE_UNKNOWN ? $use->type : $statement->type;
                    $kind = $type === Stmt\Use_::TYPE_FUNCTION ? 'function' : ($type === Stmt\Use_::TYPE_NORMAL ? 'class' : null);
                    if ($kind !== null) {
                        $uses[$kind][strtolower($use->getAlias()->toString())] = $prefix . $use->name->toString();
                    }
                }
            }
        }

        return $uses;
    }

    /**
     * Functions and classes the snippet declares, by fully qualified lowercase name.
     *
     * @param Node[] $nodes
     */
    private function collectDeclarations(array $nodes, string $namespace): void
    {
        foreach ($nodes as $node) {
            if (!$node instanceof Node) {
                continue;
            }
            if ($node instanceof Stmt\Namespace_) {
                $this->collectDeclarations($node->stmts, $node->name !== null ? $node->name->toString() : '');
                continue;
            }
            if ($node instanceof Stmt\Function_) {
                $this->functions[strtolower(ltrim($namespace . '\\' . $node->name->toString(), '\\'))] = $node;
            } elseif ($node instanceof Stmt\ClassLike && $node->name !== null) {
                $this->classes[strtolower(ltrim($namespace . '\\' . $node->name->toString(), '\\'))] = $node;
            }
            foreach (['stmts', 'else', 'elseifs', 'cases', 'catches', 'finally'] as $name) {
                if (!property_exists($node, $name)) {
                    continue;
                }
                $value = $node->$name;
                $this->collectDeclarations(is_array($value) ? $value : [$value], $namespace);
            }
        }
    }

    /** Records the statement lists inside $node where a statement can be inserted. */
    private function recordRegions(Node $node): void
    {
        if (($node instanceof Stmt\Function_ || $node instanceof Stmt\ClassMethod || $node instanceof Expr\Closure
                || $node instanceof Stmt\Catch_ || $node instanceof Stmt\Finally_ || $node instanceof Stmt\Block) && is_array($node->stmts ?? null)) {
            $close = $this->tokenIndexAt($node->getEndFilePos());
            if ($close !== null && $this->tokenText($close) === '}' && isset($this->match[$close])) {
                $this->addRegion($this->match[$close], $close, $node->stmts);
            }

            return;
        }
        if ($node instanceof Stmt\TryCatch || $node instanceof Stmt\Do_) {
            $open = $this->nextSignificant($node->getStartFilePos() + ($node instanceof Stmt\TryCatch ? 3 : 2));
            if ($open !== null && $this->tokenText($open) === '{' && isset($this->match[$open])) {
                $this->addRegion($open, $this->match[$open], $node->stmts);
            }

            return;
        }
        if ($node instanceof Stmt\If_) {
            $clauses = array_merge([$node], $node->elseifs, $node->else !== null ? [$node->else] : []);
            foreach ($clauses as $i => $clause) {
                $next = $clauses[$i + 1] ?? null;
                $altClose = $next !== null ? $next->getStartFilePos() - 1 : $node->getEndFilePos();
                if ($clause instanceof Stmt\Else_) {
                    $open = $this->nextSignificant($clause->getStartFilePos() + 4);
                } else {
                    $open = $this->afterParenthesis($clause->cond->getEndFilePos());
                }
                $this->addBodyRegion($open, $altClose, $clause->stmts);
            }

            return;
        }
        if ($node instanceof Stmt\While_) {
            $this->addBodyRegion($this->afterParenthesis($node->cond->getEndFilePos()), $node->getEndFilePos(), $node->stmts);

            return;
        }
        if ($node instanceof Stmt\Foreach_) {
            $this->addBodyRegion($this->afterParenthesis($node->valueVar->getEndFilePos()), $node->getEndFilePos(), $node->stmts);

            return;
        }
        if ($node instanceof Stmt\For_) {
            $keyword = $this->nextSignificant($node->getStartFilePos());
            $parenthesis = $keyword !== null ? $this->nextSignificant($this->tokenEnd($keyword) + 1) : null;
            if ($parenthesis !== null && $this->tokenText($parenthesis) === '(' && isset($this->match[$parenthesis])) {
                $this->addBodyRegion($this->nextSignificant($this->tokenEnd($this->match[$parenthesis]) + 1), $node->getEndFilePos(), $node->stmts);
            }

            return;
        }
        if ($node instanceof Stmt\Declare_ && is_array($node->stmts)) {
            $last = end($node->declares);
            if ($last !== false) {
                $this->addBodyRegion($this->afterParenthesis($last->getEndFilePos()), $node->getEndFilePos(), $node->stmts);
            }

            return;
        }
        if ($node instanceof Stmt\Switch_) {
            $close = $this->tokenIndexAt($node->getEndFilePos());
            $switchClose = $close !== null && $this->tokenText($close) === '}' ? $node->getEndFilePos() - 1 : $node->getEndFilePos();
            foreach ($node->cases as $i => $case) {
                $after = $case->cond !== null ? $case->cond->getEndFilePos() + 1 : $case->getStartFilePos() + 7;
                $open = $this->nextSignificant($after);
                if ($open !== null && ($this->tokenText($open) === ':' || $this->tokenText($open) === ';')) {
                    $next = $node->cases[$i + 1] ?? null;
                    $this->addRegion($open, null, $case->stmts, $next !== null ? $next->getStartFilePos() - 1 : $switchClose);
                }
            }

            return;
        }
        if ($node instanceof Stmt\Namespace_) {
            $after = $node->name !== null ? $node->name->getEndFilePos() + 1 : $node->getStartFilePos() + 9;
            $open = $this->nextSignificant($after);
            if ($open === null) {
                return;
            }
            if ($this->tokenText($open) === '{' && isset($this->match[$open])) {
                $this->addRegion($open, $this->match[$open], $node->stmts);
            } elseif ($this->tokenText($open) === ';') {
                // `namespace A;` holds the statements up to the next namespace.
                $this->addRegion($open, null, $node->stmts, max($node->getEndFilePos(), $this->tokens[$open][2]));
            }
        }
    }

    /** The first significant token after the `)` that follows offset $end. */
    private function afterParenthesis(int $end): ?int
    {
        $parenthesis = $this->nextSignificant($end + 1);
        if ($parenthesis === null || $this->tokenText($parenthesis) !== ')') {
            return null;
        }

        return $this->nextSignificant($this->tokenEnd($parenthesis) + 1);
    }

    /**
     * A body opened by `{` (closed by its `}`) or `:` (alternative syntax, closed at
     * $altClose). A single statement without braces has no region.
     *
     * @param Node\Stmt[] $statements
     */
    private function addBodyRegion(?int $open, int $altClose, array $statements): void
    {
        if ($open === null) {
            return;
        }
        if ($this->tokenText($open) === '{' && isset($this->match[$open])) {
            $this->addRegion($open, $this->match[$open], $statements);
        } elseif ($this->tokenText($open) === ':') {
            $this->addRegion($open, null, $statements, $altClose);
        }
    }

    /** @param Node\Stmt[] $statements */
    private function addRegion(int $openIndex, ?int $closeIndex, array $statements, ?int $closeOffset = null): void
    {
        $close = $closeIndex !== null ? $this->tokens[$closeIndex][2] - 1 : (int) $closeOffset;
        $this->regions[] = ['open' => $this->tokens[$openIndex][2], 'close' => $close, 'stmts' => $statements];
    }

    // MARK: Resolution

    /**
     * Plans one magic comment's probe. Returns null and fills $edits and $kind, or returns
     * why the comment cannot be shown.
     *
     * @param array{form: string, text: string, offset: int, line: int, index: int, projection: string|null} $comment
     * @param array<int, array<int, mixed>> $edits
     */
    private function resolve(array $comment, int $id, array &$edits, string &$kind): ?string
    {
        $previous = $this->previousSignificant($comment['index']);
        if ($previous === null) {
            return 'There is nothing before it to show.';
        }
        $projection = null;
        if ($comment['form'] === 'projection') {
            $projection = $this->projection((string) $comment['projection']);
            if ($projection === null) {
                return 'A projection is a chain that starts with -> or ?->, such as /*?->count()*/.';
            }
        }
        // `//?` at the end of a line inside a list (`foo($a, //?`) refers to the item before the comma.
        if ($comment['form'] === 'line' && $this->tokenText($previous) === ',') {
            $beforeComma = $this->previousSignificant($previous);
            if ($beforeComma !== null && $this->candidates($this->tokenEnd($beforeComma), $beforeComma) !== []) {
                $previous = $beforeComma;
            }
        }
        $previousEnd = $this->tokenEnd($previous);
        // `//?` is about its own line; a statement's value shows on the line it ends on.
        $sameLine = $this->tokens[$previous][3] + substr_count($this->tokens[$previous][1], "\n") === $comment['line'];

        // 1. An expression ends right before the comment.
        $candidates = $comment['form'] === 'line' && !$sameLine ? [] : $this->candidates($previousEnd, $previous);
        if ($candidates !== []) {
            $firstReason = null;
            foreach ($candidates as $entry) {
                $mode = $this->mode($entry, $reason);
                if ($mode !== null) {
                    return $this->wrap($entry, $mode, $comment['form'], $projection, $id, $edits, $kind);
                }
                $firstReason = $firstReason ?? $reason;
            }

            return $firstReason;
        }

        // 2. A statement with a value ends right before it on the same line: show that value.
        if ($comment['form'] !== 'time' && $sameLine) {
            foreach (array_reverse($this->stmtByEnd[$previousEnd] ?? []) as $statement) {
                $reason = $this->statementValue($statement, $comment['form'], $projection, $id, $edits, $kind);
                if ($reason !== false) {
                    return $reason;
                }
            }
        }

        // 3. Between statements: mark that the line was reached (or the time at that point).
        if ($comment['form'] !== 'projection') {
            $at = $this->gapInsertion($comment['offset'], $previous);
            if ($at !== null) {
                $kind = $comment['form'] === 'time' ? 'time' : 'reached';
                $returned = $this->returned;
                if ($returned !== null && $at > $returned->getEndFilePos()) {
                    // After the statement the compiler returns: mark once its value is ready.
                    $start = $returned->expr->getStartFilePos();
                    $end = $returned->expr->getEndFilePos();
                    $edits[] = [$start, 0, self::PROBE . ($kind === 'time' ? 'time(' : 'reached(') . $id . ', ', 4, $start - $end, -$id];
                    $edits[] = [$end + 1, 0, ')', 0, $end - $start, $id];

                    return null;
                }
                $call = $comment['form'] === 'time' ? 'mark' : 'hit';
                $edits[] = [$at, 0, self::PROBE . $call . '(' . $id . ');', 2, $id, 0];

                return null;
            }
        }

        return $comment['form'] === 'line'
            ? 'Nothing on this line has a value to show: put //? after a statement or an expression.'
            : 'Put it right after an expression, such as $total /*?*/ or $query->get() /*?->count()*/.';
    }

    /**
     * Expressions that end at $end, outermost first. A parenthesized expression ends inside
     * its parentheses, so `($a + $b) /*?*\/` finds `$a + $b`.
     *
     * @return array<int, array<string, mixed>>
     */
    private function candidates(int $end, int $tokenIndex): array
    {
        if (isset($this->exprByEnd[$end])) {
            // `fn ($x) => $x * 2 /*?*\/` means the body, not the closure (nor `$f = fn …`);
            // `yield $i /*?*\/` the yielded value, not the one sent back; same for print, throw.
            $candidates = $this->exprByEnd[$end];
            for ($i = count($candidates) - 1; $i >= 0; $i--) {
                $node = $candidates[$i]['node'];
                if ($node instanceof Expr\ArrowFunction || $node instanceof Expr\Yield_ || $node instanceof Expr\Print_ || $node instanceof Expr\Throw_) {
                    $inner = array_slice($candidates, $i + 1);

                    return $inner !== [] ? $inner : $candidates;
                }
            }

            return $candidates;
        }
        // Strip parentheses: `(…)` around one expression.
        while ($this->tokenText($tokenIndex) === ')' && isset($this->match[$tokenIndex])) {
            $open = $this->match[$tokenIndex];
            $first = $this->nextSignificant($this->tokenEnd($open) + 1);
            $last = $this->previousSignificant($tokenIndex);
            if ($first === null || $last === null || $first > $last) {
                return [];
            }
            $start = $this->tokens[$first][2];
            $innerEnd = $this->tokenEnd($last);
            $found = array_values(array_filter($this->exprByEnd[$innerEnd] ?? [], static function (array $entry) use ($start): bool {
                return $entry['node']->getStartFilePos() === $start;
            }));
            if ($found !== []) {
                return $found;
            }
            $tokenIndex = $last;
        }

        return [];
    }

    /**
     * How a probe can wrap $entry: `value` (a call taking the value), `ref` (a call taking
     * and returning a reference, where the code takes the expression by reference), or null
     * with the reason in $reason.
     *
     * @param array<string, mixed> $entry
     */
    private function mode(array $entry, ?string &$reason): ?string
    {
        $node = $entry['node'];
        $mode = null;
        switch ($entry['context']) {
            case self::READ:
                $mode = 'value';
                break;
            case self::WRITE:
                $reason = 'It is where a value is assigned or declared, not read.';
                break;
            case self::REF:
                if (self::writable($node)) {
                    $mode = 'ref';
                } else {
                    $reason = 'This value is taken by reference.';
                }
                break;
            case self::REF_ITEM:
            case self::REF_SYNTAX:
                $reason = 'This value is taken by reference (&).';
                break;
            case self::ISSET:
                if (self::writable($node)) {
                    $reason = 'It is checked with isset(), empty(), or ??, so reading it could warn.';
                } else {
                    $mode = 'value';
                }
                break;
            case self::CONSTANT:
                $reason = 'Constant expressions (defaults, constants, attributes) cannot call code.';
                break;
            case self::INTERPOLATION:
                $reason = 'Inside "{$…}" the expression has to start with a variable: put the comment after the string.';
                break;
            case self::ARGUMENT:
            case self::ARGUMENT_CHAIN:
                $byRef = $this->argumentByRef($entry['call']);
                $writable = $entry['context'] === self::ARGUMENT && self::writable($node);
                if ($byRef === true) {
                    if ($writable) {
                        $mode = 'ref';
                    } else {
                        $reason = 'The function takes this argument by reference.';
                    }
                } elseif ($byRef === false || (!$writable && $entry['context'] === self::ARGUMENT)) {
                    $mode = 'value';
                } else {
                    $reason = 'Runlet cannot tell whether this argument is passed by reference: put the comment after the call.';
                }
                break;
            default:
                $reason = 'This part of the expression cannot be wrapped.';
        }
        if ($mode !== null && $this->breaksNullsafe($entry)) {
            $reason = 'It would stop ?-> from skipping the rest of the chain: put the comment right before ?-> or after the chain.';
            $mode = null;
        }

        return $mode;
    }

    /** Variables, array elements, and properties: what PHP can pass or bind by reference. */
    private static function writable(Node $node): bool
    {
        if ($node instanceof Expr\Variable) {
            return $node->name !== 'this';
        }

        return $node instanceof Expr\ArrayDimFetch || $node instanceof Expr\PropertyFetch || $node instanceof Expr\StaticPropertyFetch;
    }

    /**
     * A nullsafe chain short-circuits to its end: in `$a?->b()->c()`, a null `$a` skips
     * `->c()` too. Wrapping `$a?->b()` would end the chain there and call `c()` on null.
     *
     * @param array<string, mixed> $entry
     */
    private function breaksNullsafe(array $entry): bool
    {
        $parent = $entry['parent'];
        $continues = ($entry['slot'] === 'var' && ($parent instanceof Expr\MethodCall || $parent instanceof Expr\PropertyFetch || $parent instanceof Expr\ArrayDimFetch))
            || ($entry['slot'] === 'name' && $parent instanceof Expr\FuncCall)
            || ($entry['slot'] === 'class' && ($parent instanceof Expr\StaticCall || $parent instanceof Expr\StaticPropertyFetch || $parent instanceof Expr\ClassConstFetch));
        if (!$continues) {
            return false;
        }
        $node = $entry['node'];
        while ($node instanceof Expr) {
            if ($node instanceof Expr\NullsafeMethodCall || $node instanceof Expr\NullsafePropertyFetch) {
                return true;
            }
            if ($node instanceof Expr\MethodCall || $node instanceof Expr\PropertyFetch || $node instanceof Expr\ArrayDimFetch) {
                $node = $node->var;
            } elseif ($node instanceof Expr\FuncCall && $node->name instanceof Expr) {
                $node = $node->name;
            } elseif (($node instanceof Expr\StaticCall || $node instanceof Expr\StaticPropertyFetch || $node instanceof Expr\ClassConstFetch) && $node->class instanceof Expr) {
                $node = $node->class;
            } else {
                break;
            }
        }

        return false;
    }

    /**
     * Whether the called function takes this argument by reference: true, false, or null
     * when Runlet cannot tell (a method on an object, a class not loaded yet, a dynamic name).
     * Classes are never autoloaded for this.
     *
     * @param array{call: Node, index: int, arg: Node\Arg} $call
     */
    private function argumentByRef(array $call): ?bool
    {
        $node = $call['call'];
        $arg = $call['arg'];
        foreach (array_slice($node->args, 0, $call['index']) as $earlier) {
            if ($earlier instanceof Node\Arg && $earlier->unpack) {
                return null;
            }
        }
        $parameters = null;
        $scope = $this->scopeOf($node);
        if ($node instanceof Expr\FuncCall && $node->name instanceof Node\Name) {
            $parameters = $this->functionParameters($node->name, $scope);
        } elseif ($node instanceof Expr\StaticCall && $node->class instanceof Node\Name && $node->name instanceof Node\Identifier) {
            $parameters = $this->methodParameters($node->class, $node->name->toString(), $scope);
        } elseif ($node instanceof Expr\New_ && $node->class instanceof Node\Name) {
            $parameters = $this->methodParameters($node->class, '__construct', $scope);
        }
        if ($parameters === null) {
            return null;
        }
        if ($arg->unpack) {
            foreach (array_slice($parameters, $call['index']) as $parameter) {
                if ($parameter['byRef']) {
                    return true;
                }
            }

            return false;
        }
        if ($arg->name !== null) {
            foreach ($parameters as $parameter) {
                if ($parameter['name'] === $arg->name->toString()) {
                    return $parameter['byRef'];
                }
            }
            $last = end($parameters);

            return $last !== false && $last['variadic'] ? $last['byRef'] : false;
        }
        if (isset($parameters[$call['index']])) {
            return $parameters[$call['index']]['byRef'];
        }
        $last = end($parameters);

        return $last !== false && $last['variadic'] ? $last['byRef'] : false;
    }

    /**
     * The scope a call was recorded with.
     *
     * @return array{byRef: bool, ns: string, uses: array<string, array<string, string>>}
     */
    private function scopeOf(Node $node): array
    {
        foreach ($this->exprByEnd[$node->getEndFilePos()] ?? [] as $entry) {
            if ($entry['node'] === $node) {
                return $entry['scope'];
            }
        }

        return ['byRef' => false, 'ns' => '', 'uses' => ['class' => [], 'function' => []]];
    }

    /**
     * @param array{byRef: bool, ns: string, uses: array<string, array<string, string>>} $scope
     * @return array<int, array{name: string, byRef: bool, variadic: bool}>|null
     */
    private function functionParameters(Node\Name $name, array $scope): ?array
    {
        $candidates = [];
        $text = $name->toString();
        if ($name->isFullyQualified()) {
            $candidates[] = $text;
        } elseif ($name->isUnqualified()) {
            $alias = $scope['uses']['function'][strtolower($text)] ?? null;
            if ($alias !== null) {
                $candidates[] = $alias;
            } else {
                if ($scope['ns'] !== '') {
                    $candidates[] = $scope['ns'] . '\\' . $text;
                }
                $candidates[] = $text;
            }
        } else {
            $candidates[] = $this->qualify($name, $scope);
        }
        foreach ($candidates as $candidate) {
            $key = strtolower(ltrim($candidate, '\\'));
            if (isset($this->functions[$key])) {
                return self::astParameters($this->functions[$key]->params);
            }
            if (function_exists($key)) {
                try {
                    return self::reflectedParameters((new \ReflectionFunction($key))->getParameters());
                } catch (\Throwable $error) {
                    return null;
                }
            }
        }

        return null;
    }

    /**
     * @param array{byRef: bool, ns: string, uses: array<string, array<string, string>>} $scope
     * @return array<int, array{name: string, byRef: bool, variadic: bool}>|null
     */
    private function methodParameters(Node\Name $class, string $method, array $scope, int $depth = 0): ?array
    {
        $lower = strtolower($class->toString());
        if ($depth > 10 || in_array($lower, ['self', 'static', 'parent'], true)) {
            return null;
        }
        $name = strtolower(ltrim($this->qualify($class, $scope), '\\'));
        if (isset($this->classes[$name])) {
            $declaration = $this->classes[$name];
            foreach ($declaration->getMethods() as $candidate) {
                if (strcasecmp($candidate->name->toString(), $method) === 0) {
                    return self::astParameters($candidate->params);
                }
            }
            if ($declaration instanceof Stmt\Class_ && $declaration->extends !== null) {
                return $this->methodParameters($declaration->extends, $method, $scope, $depth + 1);
            }

            return $method === '__construct' && $declaration instanceof Stmt\Class_ && $declaration->extends === null ? [] : null;
        }
        if (!class_exists($name, false) && !interface_exists($name, false) && !trait_exists($name, false)) {
            return null;
        }
        try {
            $reflection = new \ReflectionClass($name);
            if ($reflection->hasMethod($method)) {
                return self::reflectedParameters($reflection->getMethod($method)->getParameters());
            }
            if ($method === '__construct') {
                return [];
            }
            // __callStatic() receives its arguments as an array: always by value.
            return $reflection->hasMethod('__callStatic') ? [] : null;
        } catch (\Throwable $error) {
            return null;
        }
    }

    /** @param array{byRef: bool, ns: string, uses: array<string, array<string, string>>} $scope */
    private function qualify(Node\Name $name, array $scope): string
    {
        if ($name->isFullyQualified()) {
            return $name->toString();
        }
        $parts = explode('\\', $name->toString());
        $alias = $scope['uses']['class'][strtolower($parts[0])] ?? null;
        if ($alias !== null) {
            $parts[0] = $alias;

            return implode('\\', $parts);
        }

        return ($scope['ns'] !== '' ? $scope['ns'] . '\\' : '') . $name->toString();
    }

    /**
     * @param Node\Param[] $params
     * @return array<int, array{name: string, byRef: bool, variadic: bool}>
     */
    private static function astParameters(array $params): array
    {
        $result = [];
        foreach ($params as $param) {
            $result[] = ['name' => $param->var instanceof Expr\Variable && is_string($param->var->name) ? $param->var->name : '', 'byRef' => $param->byRef, 'variadic' => $param->variadic];
        }

        return $result;
    }

    /**
     * @param \ReflectionParameter[] $params
     * @return array<int, array{name: string, byRef: bool, variadic: bool}>
     */
    private static function reflectedParameters(array $params): array
    {
        $result = [];
        foreach ($params as $param) {
            $result[] = ['name' => $param->getName(), 'byRef' => $param->isPassedByReference(), 'variadic' => $param->isVariadic()];
        }

        return $result;
    }

    /**
     * The value of a statement that ends right before the comment: an expression statement,
     * a return, or an echo. Returns false when $statement has no value, null when planned,
     * or a reason.
     *
     * @param array<int, array<int, mixed>> $edits
     * @return string|false|null
     */
    private function statementValue(Node\Stmt $statement, string $form, ?string $projection, int $id, array &$edits, string &$kind)
    {
        $target = null;
        if ($statement instanceof Stmt\Expression) {
            $expr = $statement->expr;
            if ($expr instanceof Expr\Print_ || $expr instanceof Expr\Throw_) {
                $expr = $expr->expr;
            } elseif ($expr instanceof Expr\Yield_ && $expr->value !== null) {
                $expr = $expr->value;
            } elseif ($expr instanceof Expr\Exit_) {
                if ($expr->expr === null) {
                    return 'exit has no value to show.';
                }
                $expr = $expr->expr;
            } elseif (($expr instanceof Expr\PostInc || $expr instanceof Expr\PostDec) && $projection === null
                && $expr->var instanceof Expr\Variable && is_string($expr->var->name) && $expr->var->name !== 'this') {
                // `$i++; //?` shows $i after the increment (PHP's value of `$i++` is the old one).
                $start = $expr->getStartFilePos();
                $end = $expr->getEndFilePos();
                $edits[] = [$start, 0, self::PROBE . 'after(' . $id . ', ', 4, $start - $end, -$id];
                $edits[] = [$end + 1, 0, ', $' . $expr->var->name . ')', 0, $end - $start, $id];
                $kind = 'value';

                return null;
            }
            $target = $expr;
        } elseif ($statement instanceof Stmt\Return_) {
            if ($statement->expr === null) {
                return false;
            }
            $target = $statement->expr;
        } elseif ($statement instanceof Stmt\Echo_) {
            if (count($statement->exprs) === 1 || $projection !== null) {
                $target = end($statement->exprs);
            } else {
                $count = count($statement->exprs);
                foreach ($statement->exprs as $i => $expr) {
                    $start = $expr->getStartFilePos();
                    $end = $expr->getEndFilePos();
                    $edits[] = [$start, 0, self::PROBE . 'echoArg(' . $id . ', ' . $i . ', ' . $count . ', ', 4, $start - $end, -$id];
                    $edits[] = [$end + 1, 0, ')', 0, $end - $start, $id];
                }
                $kind = 'value';

                return null;
            }
        } else {
            return false;
        }
        $entry = null;
        foreach ($this->exprByEnd[$target->getEndFilePos()] ?? [] as $candidate) {
            if ($candidate['node'] === $target) {
                $entry = $candidate;
                break;
            }
        }
        if ($entry === null) {
            return false;
        }
        $mode = $this->mode($entry, $reason);
        if ($mode === null) {
            return $reason;
        }

        return $this->wrap($entry, $mode, $form, $projection, $id, $edits, $kind);
    }

    /**
     * Wraps the expression: `Probe::at(id, <expr>)`, `Probe::ref(…)` where it is taken by
     * reference, `Probe::tap(id, <expr>, fn ($v) => $v->projection)`, or `Probe::time(…)`.
     *
     * @param array<string, mixed> $entry
     * @param array<int, array<int, mixed>> $edits
     */
    private function wrap(array $entry, string $mode, string $form, ?string $projection, int $id, array &$edits, string &$kind): ?string
    {
        $node = $entry['node'];
        $start = $node->getStartFilePos();
        $end = $node->getEndFilePos();
        if ($form === 'time') {
            if ($mode === 'ref') {
                return 'This value is taken by reference: put /*?.*/ after the statement instead.';
            }
            $open = 'time(' . $id . ', ';
            $close = ')';
            $kind = 'time';
        } elseif ($form === 'projection') {
            if ($mode === 'ref') {
                return 'This value is taken by reference, so a projection cannot wrap it.';
            }
            $open = 'tap(' . $id . ', ';
            $close = ', fn (' . self::PROJECTION_VARIABLE . ') => ' . self::PROJECTION_VARIABLE . $projection . ')';
            $kind = 'value';
        } else {
            $open = ($mode === 'ref' ? 'ref(' : 'at(') . $id . ', ';
            $close = ')';
            $kind = 'value';
        }
        $edits[] = [$start, 0, self::PROBE . $open, 4, $start - $end, -$id];
        $edits[] = [$end + 1, 0, $close, 0, $end - $start, $id];

        return null;
    }

    /**
     * Validates a projection (`->count()`, `?->name`, `->items[0]->id`) and returns it on one
     * line without comments, or null.
     */
    private function projection(string $chain): ?string
    {
        $tokens = token_get_all('<?php ' . self::PROJECTION_VARIABLE . $chain . ';');
        $text = '';
        foreach (array_slice($tokens, 1) as $token) {
            if (is_array($token)) {
                if ($token[0] === T_COMMENT || $token[0] === T_DOC_COMMENT) {
                    continue;
                }
                if ($token[0] === T_WHITESPACE) {
                    $text .= ' ';
                    continue;
                }
                if (strpos($token[1], "\n") !== false || strpos($token[1], "\r") !== false) {
                    return null;
                }
                $text .= $token[1];
            } else {
                $text .= $token;
            }
        }
        try {
            $statements = $this->parser->parse('<?php ' . $text);
        } catch (\Throwable $error) {
            return null;
        }
        if ($statements === null || count($statements) !== 1 || !$statements[0] instanceof Stmt\Expression) {
            return null;
        }
        // A chain of fetches and calls that starts at the value with -> or ?->.
        $node = $statements[0]->expr;
        $first = null;
        while ($node instanceof Expr\MethodCall || $node instanceof Expr\NullsafeMethodCall || $node instanceof Expr\PropertyFetch
            || $node instanceof Expr\NullsafePropertyFetch || $node instanceof Expr\ArrayDimFetch) {
            $first = $node;
            $node = $node->var;
        }
        if (!$node instanceof Expr\Variable || $node->name !== substr(self::PROJECTION_VARIABLE, 1) || $first === null || $first instanceof Expr\ArrayDimFetch) {
            return null;
        }
        $result = substr(rtrim($text), strlen(self::PROJECTION_VARIABLE));

        return rtrim(substr($result, 0, -1));
    }

    /**
     * Where a statement can go for a comment between statements (`foreach (…) { //?`,
     * `} /*?.*\/`), or null. Before a `return`, `break`, `continue`, `throw`, or `exit` that
     * ends right before the comment, so the probe runs.
     */
    private function gapInsertion(int $offset, int $previous): ?int
    {
        $region = null;
        foreach ($this->regions as $candidate) {
            if ($candidate['open'] < $offset && $offset <= $candidate['close'] && ($region === null || $candidate['open'] > $region['open'])) {
                $region = $candidate;
            }
        }
        if ($region === null) {
            return null;
        }
        foreach ($region['stmts'] as $statement) {
            if ($statement->getStartFilePos() <= $offset && $offset <= $statement->getEndFilePos()) {
                return null;
            }
        }
        [$id, $text, $previousOffset] = $this->tokens[$previous];
        if ($previousOffset < $region['open']) {
            return null;
        }
        if (!in_array($text, ['{', '}', ';', ':'], true) && $id !== T_OPEN_TAG) {
            return null;
        }
        $previousEnd = $this->tokenEnd($previous);
        foreach ($region['stmts'] as $statement) {
            if ($statement->getEndFilePos() === $previousEnd && self::isJump($statement)) {
                return $statement->getStartFilePos();
            }
        }

        return $offset;
    }

    private static function isJump(Node\Stmt $statement): bool
    {
        if ($statement instanceof Stmt\Return_ || $statement instanceof Stmt\Break_ || $statement instanceof Stmt\Continue_ || $statement instanceof Stmt\Goto_) {
            return true;
        }

        return $statement instanceof Stmt\Expression && ($statement->expr instanceof Expr\Throw_ || $statement->expr instanceof Expr\Exit_);
    }
}

/**
 * Records magic-comment hits while the snippet runs and streams them as `inline` events.
 * Every method returns quickly and never throws or calls user code, except a projection's
 * own chain. Limits: the first 100 hits of each probe carry values; after that hits are
 * counted and a value is sent about four times a second; values stop (counts continue)
 * once 16 MiB of values were sent in the run.
 */
final class Probe
{
    /** @var bool */
    private static $active = false;
    /** @var array<int, array{line: int, kind: string}> */
    private static $probes = [];
    /** @var array<int, int> */
    private static $hits = [];
    /** @var array<int, int> hits sent with values */
    private static $sent = [];
    /** @var array<int, int> the last hit sent */
    private static $lastSent = [];
    /** @var array<int, float> */
    private static $sampledAt = [];
    /** @var float */
    private static $start = 0.0;
    /** @var float|null */
    private static $lastMark;
    /** @var int */
    private static $bytes = 0;
    /** @var array<int, array<int, mixed>> */
    private static $echo = [];
    /** @var ValueNormalizer|null */
    private static $normalizer;
    /** @var int */
    private static $maxHits = 100;
    /** @var int */
    private static $maxBytes = 16777216;

    /** Seconds between sampled values after a probe's first hits. */
    private const SAMPLE_SECONDS = 0.25;

    /**
     * @internal Called by the runner with the compiled probes before the snippet runs.
     * @param array<int, array{line: int, kind: string, comment: string}> $probes
     * @param array<string, mixed> $limits
     */
    public static function install(array $probes, array $limits): void
    {
        self::$probes = [];
        foreach ($probes as $id => $probe) {
            self::$probes[(int) $id] = ['line' => (int) $probe['line'], 'kind' => (string) $probe['kind']];
        }
        self::$hits = [];
        self::$sent = [];
        self::$lastSent = [];
        self::$sampledAt = [];
        self::$echo = [];
        self::$bytes = 0;
        self::$lastMark = null;
        self::$maxHits = max(1, (int) ($limits['maxInlineHits'] ?? 100));
        self::$maxBytes = max(0, (int) ($limits['maxInlineBytes'] ?? 16777216));
        self::$normalizer = new ValueNormalizer([
            'maxDepth' => min(5, (int) ($limits['maxDepth'] ?? 8)),
            'maxChildren' => 100,
            'maxStringBytes' => 8192,
            'maxNodes' => 2500,
            'maxValueBytes' => 262144,
        ]);
        self::$active = self::$probes !== [];
    }

    /** @internal The snippet starts running now: elapsed times count from here. */
    public static function begin(): void
    {
        self::$start = microtime(true);
        self::$lastMark = null;
    }

    /**
     * @param mixed $value
     * @return mixed
     */
    public static function at(int $id, $value)
    {
        self::value($id, $value);

        return $value;
    }

    /**
     * Where the code takes the expression by reference (a by-reference argument, `=&`,
     * `foreach (… as &$v)`, a by-reference return): the reference passes through.
     *
     * @param mixed $value
     * @return mixed
     */
    public static function &ref(int $id, &$value)
    {
        self::value($id, $value);

        return $value;
    }

    /**
     * `$i++; //?`: returns the expression's own value, shows the variable's new value.
     *
     * @param mixed $result
     * @param mixed $value
     * @return mixed
     */
    public static function after(int $id, $result, $value)
    {
        self::value($id, $value);

        return $result;
    }

    /**
     * `/*?->count()*\/`: shows the projection, returns the value itself. The projection is
     * user code (it may query a database); it runs only for hits whose values are sent.
     *
     * @param mixed $value
     * @return mixed
     */
    public static function tap(int $id, $value, \Closure $projection)
    {
        if (!self::$active || !isset(self::$probes[$id])) {
            return $value;
        }
        $hit = self::count($id);
        if (!self::sends($id, $hit)) {
            return $value;
        }
        try {
            $projected = $projection($value);
        } catch (\Throwable $error) {
            self::emit($id, $hit, ['error' => ['className' => get_class($error), 'message' => self::clip($error->getMessage(), 2000)]]);

            return $value;
        }
        self::emit($id, $hit, ['value' => self::normalize($projected)]);

        return $value;
    }

    /**
     * `/*?.*\/` after an expression: the time since the previous mark, then the value.
     *
     * @param mixed $value
     * @return mixed
     */
    public static function time(int $id, $value)
    {
        self::mark($id);

        return $value;
    }

    /** `/*?.*\/` between statements. */
    public static function mark(int $id): void
    {
        if (!self::$active || !isset(self::$probes[$id])) {
            return;
        }
        $now = microtime(true);
        $elapsed = ($now - (self::$lastMark ?? self::$start)) * 1000;
        self::$lastMark = $now;
        $hit = self::count($id);
        if (self::sends($id, $hit)) {
            self::emit($id, $hit, ['ms' => round($elapsed, 3)]);
        }
    }

    /**
     * `//?` after the snippet's final expression (which becomes its result): reached once
     * the value is ready.
     *
     * @param mixed $value
     * @return mixed
     */
    public static function reached(int $id, $value)
    {
        self::hit($id);

        return $value;
    }

    /** `//?` on a line with no value: the line was reached. */
    public static function hit(int $id): void
    {
        if (!self::$active || !isset(self::$probes[$id])) {
            return;
        }
        $hit = self::count($id);
        if (self::sends($id, $hit)) {
            self::emit($id, $hit, []);
        }
    }

    /**
     * `echo $a, $b; //?`: collects the arguments, shows them as a list after the last one.
     *
     * @param mixed $value
     * @return mixed
     */
    public static function echoArg(int $id, int $index, int $count, $value)
    {
        if (!self::$active) {
            return $value;
        }
        if ($index === 0) {
            self::$echo[$id] = [];
        }
        self::$echo[$id][] = $value;
        if ($index === $count - 1) {
            $values = self::$echo[$id];
            unset(self::$echo[$id]);
            self::value($id, $values);
        }

        return $value;
    }

    /** @internal Sends the final count of probes whose last hits were not sent. */
    public static function finish(): void
    {
        if (!self::$active) {
            return;
        }
        self::$active = false;
        foreach (self::$hits as $id => $hits) {
            if ($hits > (self::$lastSent[$id] ?? 0)) {
                Channel::emit('inline', ['probe' => $id, 'line' => self::$probes[$id]['line'], 'kind' => self::$probes[$id]['kind'], 'hit' => $hits, 'final' => true]);
            }
        }
        self::$echo = [];
    }

    /** @param mixed $value */
    private static function value(int $id, $value): void
    {
        if (!self::$active || !isset(self::$probes[$id])) {
            return;
        }
        $hit = self::count($id);
        if (self::sends($id, $hit)) {
            self::emit($id, $hit, ['value' => self::normalize($value)]);
        }
    }

    private static function count(int $id): int
    {
        self::$hits[$id] = (self::$hits[$id] ?? 0) + 1;

        return self::$hits[$id];
    }

    /** The first hits of a probe are sent; later ones about four times a second. */
    private static function sends(int $id, int $hit): bool
    {
        if ($hit <= self::$maxHits) {
            return true;
        }
        $now = microtime(true);
        if ($now - (self::$sampledAt[$id] ?? 0.0) >= self::SAMPLE_SECONDS) {
            self::$sampledAt[$id] = $now;

            return true;
        }

        return false;
    }

    /** @param array<string, mixed> $fields */
    private static function emit(int $id, int $hit, array $fields): void
    {
        try {
            $payload = [
                'probe' => $id,
                'line' => self::$probes[$id]['line'],
                'kind' => self::$probes[$id]['kind'],
                'hit' => $hit,
                't' => round((microtime(true) - self::$start) * 1000, 3),
            ];
            if ($hit > self::$maxHits) {
                $payload['sampled'] = true;
            }
            if (isset($fields['value'])) {
                $size = strlen((string) json_encode($fields['value'], JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_PARTIAL_OUTPUT_ON_ERROR));
                if (self::$bytes + $size > self::$maxBytes) {
                    unset($fields['value']);
                    $payload['omitted'] = 'bytes';
                } else {
                    self::$bytes += $size;
                }
            }
            self::$sent[$id] = (self::$sent[$id] ?? 0) + 1;
            self::$lastSent[$id] = $hit;
            Channel::emit('inline', $payload + $fields);
        } catch (\Throwable $error) {
            // A probe must never break the code it watches.
        }
    }

    /**
     * @param mixed $value
     * @return array<string, mixed>
     */
    private static function normalize($value): array
    {
        if (self::$normalizer === null) {
            return ['id' => 0, 'type' => 'unknown'];
        }
        try {
            return self::$normalizer->normalize($value);
        } catch (\Throwable $error) {
            return ['id' => 0, 'type' => 'unknown', 'scalar' => 'Runlet could not inspect this value: ' . $error->getMessage()];
        }
    }

    private static function clip(string $text, int $limit): string
    {
        return strlen($text) > $limit ? substr($text, 0, $limit) . '…' : $text;
    }
}
