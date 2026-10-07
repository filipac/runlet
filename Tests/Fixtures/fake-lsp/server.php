<?php
// A fake language server for RunletLanguageTests (#336). It speaks LSP over stdin and stdout
// like PHPantom, and records what the client sends:
//
// - `initialized`: asks the client to watch `**/*.php` (all kinds), `**/composer.lock` (changes
//   only) and `*.toml` under the root (a relative pattern), with `client/registerCapability`;
//   then creates a progress token and, once the client accepts it, begins "Fake: Indexing" and
//   reports 42% "Scanning (42/100 files)".
// - `fake/endProgress` ends that progress with "Indexed 3 classes".
// - `fake/unregister` withdraws the watchers with `client/unregisterCapability`.
// - `fake/log` returns what it saw: the `initialize` params, the client's answers to its
//   requests by id, every `workspace/didChangeWatchedFiles` notification, and the other
//   notifications' methods.

$log = ['initialize' => null, 'answers' => (object) [], 'watched' => [], 'notifications' => []];
$root = null;

function send(array $message): void
{
    $message['jsonrpc'] = '2.0';
    $body = json_encode($message, JSON_UNESCAPED_SLASHES);
    fwrite(STDOUT, 'Content-Length: ' . strlen($body) . "\r\n\r\n" . $body);
    fflush(STDOUT);
}

function read(): ?array
{
    $length = null;
    while (($line = fgets(STDIN)) !== false) {
        $line = rtrim($line, "\r\n");
        if ($line === '') {
            break;
        }
        if (stripos($line, 'Content-Length:') === 0) {
            $length = (int) trim(substr($line, 15));
        }
    }
    if ($line === false || $length === null) {
        return null;
    }
    $body = '';
    while (strlen($body) < $length) {
        $chunk = fread(STDIN, $length - strlen($body));
        if ($chunk === false || $chunk === '') {
            return null;
        }
        $body .= $chunk;
    }
    return json_decode($body, true);
}

while (($message = read()) !== null) {
    $method = $message['method'] ?? null;
    $id = $message['id'] ?? null;

    if ($method === null) {
        // The client's answer to one of our requests.
        $log['answers']->{(string) $id} = array_key_exists('result', $message) ? $message['result'] : ['error' => $message['error'] ?? null];
        if ($id === 'progress-create') {
            $value = ['kind' => 'begin', 'title' => 'Fake: Indexing', 'message' => 'Starting', 'percentage' => 0, 'cancellable' => false];
            send(['method' => '$/progress', 'params' => ['token' => 'fake/indexing', 'value' => $value]]);
            $value = ['kind' => 'report', 'message' => 'Scanning (42/100 files)', 'percentage' => 42];
            send(['method' => '$/progress', 'params' => ['token' => 'fake/indexing', 'value' => $value]]);
        }
        continue;
    }

    switch ($method) {
        case 'initialize':
            $log['initialize'] = $message['params'];
            $root = $message['params']['rootUri'] ?? null;
            send(['id' => $id, 'result' => [
                'capabilities' => ['executeCommandProvider' => ['commands' => ['fake.navigate']]],
                'serverInfo' => ['name' => 'fake-lsp', 'version' => '0.0.1'],
            ]]);
            break;
        case 'initialized':
            send(['id' => 'register-watchers', 'method' => 'client/registerCapability', 'params' => ['registrations' => [
                ['id' => 'type-hierarchy', 'method' => 'textDocument/prepareTypeHierarchy', 'registerOptions' => (object) []],
                ['id' => 'watchers', 'method' => 'workspace/didChangeWatchedFiles', 'registerOptions' => ['watchers' => [
                    ['globPattern' => '**/*.php', 'kind' => 7],
                    ['globPattern' => '**/composer.lock', 'kind' => 2],
                    ['globPattern' => ['baseUri' => $root, 'pattern' => '*.toml']],
                ]]],
            ]]]);
            send(['id' => 'progress-create', 'method' => 'window/workDoneProgress/create', 'params' => ['token' => 'fake/indexing']]);
            break;
        case 'fake/endProgress':
            send(['method' => '$/progress', 'params' => ['token' => 'fake/indexing', 'value' => ['kind' => 'end', 'message' => 'Indexed 3 classes']]]);
            send(['id' => $id, 'result' => null]);
            break;
        case 'fake/unregister':
            send(['id' => 'unregister-watchers', 'method' => 'client/unregisterCapability', 'params' => ['unregisterations' => [
                ['id' => 'watchers', 'method' => 'workspace/didChangeWatchedFiles'],
            ]]]);
            send(['id' => $id, 'result' => null]);
            break;
        case 'fake/log':
            send(['id' => $id, 'result' => $log]);
            break;
        case 'workspace/didChangeWatchedFiles':
            $log['watched'][] = $message['params']['changes'];
            break;
        case 'shutdown':
            send(['id' => $id, 'result' => null]);
            break;
        case 'exit':
            exit(0);
        default:
            if ($id !== null) {
                send(['id' => $id, 'result' => null]);
            } else {
                $log['notifications'][] = $method;
            }
    }
}
