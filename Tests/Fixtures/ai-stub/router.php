<?php
// A stand-in for Anthropic's Messages API and OpenAI's Responses API (#368), for tests and
// screenshots: run it with `php -S 127.0.0.1:<port> router.php` and point Runlet at it
// (`RUNLET_AI_BASE_URL`, Debug builds only). It answers with canned server-sent events shaped
// like the providers' documented streams, and never contacts anything.
//
// - GET  /v1/models     the provider's model list (Anthropic when x-api-key is set, else OpenAI)
// - POST /v1/messages   Anthropic's stream
// - POST /v1/responses  OpenAI's stream
//
// A key containing "invalid" gets a 401. RUNLET_AI_STUB_SCENARIO names a JSON file that sets the
// answer: `answer` (Markdown), `chunk` (characters per delta), `delay_ms` (between deltas),
// `hold_after` and `hold_ms` (pause once after that many characters, so a screenshot catches the
// answer while it streams), `stop` (end_turn, max_tokens, or refusal), and `status` with
// `retry_after` (an HTTP error instead). RUNLET_AI_STUB_LOG names a file that gets one JSON line
// per request: the path, the provider, whether a key came (never the key), and the body.

$path = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);
$headers = array_change_key_case(function_exists('getallheaders') ? getallheaders() : [], CASE_LOWER);
$provider = isset($headers['x-api-key']) ? 'anthropic' : 'openai';
$key = $provider === 'anthropic' ? ($headers['x-api-key'] ?? '') : preg_replace('/^Bearer\s+/', '', $headers['authorization'] ?? '');
$body = json_decode(file_get_contents('php://input') ?: 'null', true);

$scenario = [
    'answer' => "The error comes from the code in the tab.\n\nCheck the line it names.",
    'chunk' => 12,
    'delay_ms' => 15,
    'hold_after' => null,
    'hold_ms' => 0,
    'stop' => 'end_turn',
    'status' => 200,
    'retry_after' => null,
];
$file = getenv('RUNLET_AI_STUB_SCENARIO');
if ($file && is_file($file)) {
    $scenario = array_merge($scenario, json_decode(file_get_contents($file), true) ?: []);
}

if ($log = getenv('RUNLET_AI_STUB_LOG')) {
    file_put_contents($log, json_encode([
        'path' => $path,
        'method' => $_SERVER['REQUEST_METHOD'],
        'provider' => $provider,
        'key' => $key === '' ? 'missing' : 'present',
        'anthropic_version' => $headers['anthropic-version'] ?? null,
        'anthropic_beta' => $headers['anthropic-beta'] ?? null,
        'body' => $body,
    ]) . "\n", FILE_APPEND | LOCK_EX);
}

function fail(string $provider, int $status, string $type, string $message, $retryAfter = null): void
{
    http_response_code($status);
    header('Content-Type: application/json');
    if ($retryAfter !== null) {
        header('retry-after: ' . $retryAfter);
    }
    echo json_encode($provider === 'anthropic'
        ? ['type' => 'error', 'error' => ['type' => $type, 'message' => $message]]
        : ['error' => ['message' => $message, 'type' => $type, 'param' => null, 'code' => $type]]);
}

if ($key === '' || str_contains($key, 'invalid')) {
    fail($provider, 401, $provider === 'anthropic' ? 'authentication_error' : 'invalid_api_key', 'invalid x-api-key');
    return;
}

if ($path === '/v1/models') {
    header('Content-Type: application/json');
    if ($provider === 'anthropic') {
        $models = [['claude-opus-5-5', 'Claude Opus 5.5'], ['claude-sonnet-5-5', 'Claude Sonnet 5.5'], ['claude-haiku-5-5', 'Claude Haiku 5.5'], ['claude-opus-5', 'Claude Opus 5']];
        echo json_encode(['data' => array_map(fn ($m) => ['type' => 'model', 'id' => $m[0], 'display_name' => $m[1], 'created_at' => '2026-09-01T00:00:00Z'], $models), 'has_more' => false]);
    } else {
        $models = [['gpt-6-astra', 1795000000], ['gpt-6.1-sol', 1796000000], ['gpt-6-luna', 1790000000], ['text-embedding-3-large', 1705000000], ['gpt-realtime', 1796000000]];
        echo json_encode(['object' => 'list', 'data' => array_map(fn ($m) => ['id' => $m[0], 'object' => 'model', 'created' => $m[1], 'owned_by' => 'system'], $models)]);
    }
    return;
}

if ((int) $scenario['status'] !== 200) {
    $status = (int) $scenario['status'];
    $type = match ($status) {
        429 => $provider === 'anthropic' ? 'rate_limit_error' : 'rate_limit_exceeded',
        529 => 'overloaded_error',
        default => 'api_error',
    };
    fail($provider, $status, $type, 'The stub answered ' . $status . '.', $scenario['retry_after']);
    return;
}

$expected = $provider === 'anthropic' ? '/v1/messages' : '/v1/responses';
if ($path !== $expected || $_SERVER['REQUEST_METHOD'] !== 'POST' || !is_array($body)) {
    fail($provider, 404, 'not_found_error', 'Not found: ' . $path);
    return;
}

$model = $body['model'] ?? 'unknown';
header('Content-Type: text/event-stream');
header('Cache-Control: no-cache');
while (ob_get_level() > 0) {
    ob_end_flush();
}

function send(?string $event, array $data): void
{
    if ($event !== null) {
        echo "event: {$event}\n";
    }
    echo 'data: ' . json_encode($data, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE) . "\n\n";
    flush();
}

$answer = (string) $scenario['answer'];
$chunk = max(1, (int) $scenario['chunk']);
$pieces = [];
for ($i = 0; $i < mb_strlen($answer); $i += $chunk) {
    $pieces[] = mb_substr($answer, $i, $chunk);
}
$stop = $scenario['stop'];

function stream_pieces(array $pieces, array $scenario, callable $emit): void
{
    $sent = 0;
    $held = false;
    foreach ($pieces as $piece) {
        $emit($piece);
        $sent += mb_strlen($piece);
        if (!$held && $scenario['hold_after'] !== null && $sent >= (int) $scenario['hold_after']) {
            $held = true;
            usleep((int) $scenario['hold_ms'] * 1000);
        } else {
            usleep((int) $scenario['delay_ms'] * 1000);
        }
        if (connection_aborted()) {
            exit;
        }
    }
}

if ($provider === 'anthropic') {
    send('message_start', ['type' => 'message_start', 'message' => ['id' => 'msg_stub', 'type' => 'message', 'role' => 'assistant', 'content' => [], 'model' => $model, 'stop_reason' => null, 'usage' => ['input_tokens' => 512, 'output_tokens' => 1]]]);
    send('content_block_start', ['type' => 'content_block_start', 'index' => 0, 'content_block' => ['type' => 'thinking', 'thinking' => '']]);
    send('content_block_delta', ['type' => 'content_block_delta', 'index' => 0, 'delta' => ['type' => 'thinking_delta', 'thinking' => '']]);
    send('content_block_delta', ['type' => 'content_block_delta', 'index' => 0, 'delta' => ['type' => 'signature_delta', 'signature' => 'stub']]);
    send('content_block_stop', ['type' => 'content_block_stop', 'index' => 0]);
    send('content_block_start', ['type' => 'content_block_start', 'index' => 1, 'content_block' => ['type' => 'text', 'text' => '']]);
    send('ping', ['type' => 'ping']);
    stream_pieces($pieces, $scenario, fn ($piece) => send('content_block_delta', ['type' => 'content_block_delta', 'index' => 1, 'delta' => ['type' => 'text_delta', 'text' => $piece]]));
    send('content_block_stop', ['type' => 'content_block_stop', 'index' => 1]);
    $delta = ['stop_reason' => $stop, 'stop_sequence' => null];
    if ($stop === 'refusal') {
        $delta['stop_details'] = ['type' => 'refusal', 'category' => 'cyber', 'explanation' => 'The stub declined.'];
    }
    send('message_delta', ['type' => 'message_delta', 'delta' => $delta, 'usage' => ['output_tokens' => 240]]);
    send('message_stop', ['type' => 'message_stop']);
} else {
    $sequence = 0;
    send('response.created', ['type' => 'response.created', 'sequence_number' => $sequence++, 'response' => ['id' => 'resp_stub', 'status' => 'in_progress', 'model' => $model]]);
    send('response.output_item.added', ['type' => 'response.output_item.added', 'sequence_number' => $sequence++, 'output_index' => 0, 'item' => ['type' => 'reasoning', 'id' => 'rs_stub']]);
    send('response.output_item.added', ['type' => 'response.output_item.added', 'sequence_number' => $sequence++, 'output_index' => 1, 'item' => ['type' => 'message', 'id' => 'msg_stub', 'role' => 'assistant']]);
    if ($stop === 'refusal') {
        send('response.refusal.delta', ['type' => 'response.refusal.delta', 'sequence_number' => $sequence++, 'item_id' => 'msg_stub', 'output_index' => 1, 'content_index' => 0, 'delta' => 'The stub declined.']);
    } else {
        stream_pieces($pieces, $scenario, function ($piece) use (&$sequence) {
            send('response.output_text.delta', ['type' => 'response.output_text.delta', 'sequence_number' => $sequence++, 'item_id' => 'msg_stub', 'output_index' => 1, 'content_index' => 0, 'delta' => $piece, 'logprobs' => []]);
        });
    }
    $usage = ['input_tokens' => 512, 'output_tokens' => 240];
    if ($stop === 'max_tokens') {
        send('response.incomplete', ['type' => 'response.incomplete', 'sequence_number' => $sequence++, 'response' => ['id' => 'resp_stub', 'status' => 'incomplete', 'model' => $model, 'incomplete_details' => ['reason' => 'max_output_tokens'], 'usage' => $usage]]);
    } else {
        send('response.completed', ['type' => 'response.completed', 'sequence_number' => $sequence++, 'response' => ['id' => 'resp_stub', 'status' => 'completed', 'model' => $model, 'usage' => $usage]]);
    }
}
