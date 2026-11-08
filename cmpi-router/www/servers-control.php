<?php
// cmpi-router www/servers-control.php, installed as /var/www/html/servers/admin/control.php by `setup-services.sh servers-admin`.
// The back end of the logged-in servers page: lists the services it may control and starts, stops or restarts one.
// It sits under /servers/admin/, which Apache protects with a login (AuthType Basic over https), and it refuses to run without
// that login.  It decides nothing itself: every request goes on to /usr/local/sbin/cpbee-service through sudo (www-data may run
// only that), which holds the table of allowed services and actions.  Nothing from the request reaches a shell.
header('Content-Type: application/json');
header('Cache-Control: no-store');

function out(int $code, array $a): void { http_response_code($code); echo json_encode($a); exit; }

$user = $_SERVER['REMOTE_USER'] ?? '';
if ($user === '') out(401, ['ok' => false, 'message' => 'not logged in']);

// Run the wrapper with these arguments (an array: no shell), wait at most $timeout seconds; returns [exit code, output].
function wrapper(array $args, int $timeout = 75): array {
    $p = proc_open(array_merge(['sudo', '-n', '/usr/local/sbin/cpbee-service'], $args),
                   [0 => ['pipe', 'r'], 1 => ['pipe', 'w'], 2 => ['redirect', 1]], $pipes);
    if (!is_resource($p)) return [127, 'could not run the helper'];
    fclose($pipes[0]);
    stream_set_blocking($pipes[1], false);
    $buf = ''; $exit = null; $end = microtime(true) + $timeout;
    while (microtime(true) < $end) {
        $r = [$pipes[1]]; $w = null; $e = null;
        if (@stream_select($r, $w, $e, 1) > 0) {
            $chunk = fread($pipes[1], 8192);
            if ($chunk !== '' && $chunk !== false) $buf .= $chunk;
            elseif (feof($pipes[1])) break;                      // the helper closed its output: it is done
        }
        $st = proc_get_status($p);
        if (!$st['running']) { $exit = $st['exitcode']; $buf .= (string)stream_get_contents($pipes[1]); break; }
    }
    if ($exit === null) {
        for ($i = 0; $i < 30; $i++) {                            // its output is closed: give it a moment to exit
            $st = proc_get_status($p);
            if (!$st['running']) break;
            usleep(100000);
        }
        if ($st['running']) { proc_terminate($p); $exit = 124; $buf .= "\ntimed out"; }
        else $exit = $st['exitcode'];
    }
    fclose($pipes[1]);
    $closed = proc_close($p);
    if ($exit === -1) $exit = $closed;                          // the status was already taken: close knows
    return [$exit, trim($buf)];
}

function services(): array {
    [$rc, $txt] = wrapper(['list'], 15);
    $out = [];
    if ($rc === 0) foreach (explode("\n", $txt) as $ln) {
        $f = explode('|', $ln);
        if (count($f) === 4 && $f[0] !== '') $out[] = ['name' => $f[0], 'state' => $f[1], 'actions' => $f[2] === '' ? [] : explode(' ', $f[2]), 'label' => $f[3]];
    }
    return $out;
}

if ($_SERVER['REQUEST_METHOD'] === 'GET') {
    out(200, ['ok' => true, 'user' => $user, 'services' => services()]);
}
if ($_SERVER['REQUEST_METHOD'] !== 'POST') out(405, ['ok' => false, 'message' => 'GET or POST only']);

// A request another web site could have made for the browser is refused: it must carry our own header (which a page on
// another origin cannot add without our consent) and, where the browser says, come from this site.
if (($_SERVER['HTTP_X_CPBEE'] ?? '') !== '1') out(403, ['ok' => false, 'message' => 'missing header']);
if (isset($_SERVER['HTTP_SEC_FETCH_SITE']) && $_SERVER['HTTP_SEC_FETCH_SITE'] !== 'same-origin') out(403, ['ok' => false, 'message' => 'not from this page']);
if (!empty($_SERVER['HTTP_ORIGIN']) && (parse_url($_SERVER['HTTP_ORIGIN'], PHP_URL_HOST) . (($pt = parse_url($_SERVER['HTTP_ORIGIN'], PHP_URL_PORT)) ? ':' . $pt : '')) !== ($_SERVER['HTTP_HOST'] ?? '')) {
    out(403, ['ok' => false, 'message' => 'not from this page']);
}

$action = $_POST['action'] ?? '';
$name   = $_POST['name'] ?? '';
if (!in_array($action, ['start', 'stop', 'restart'], true) || !preg_match('/^[a-z0-9]{1,20}$/', $name)) {
    out(400, ['ok' => false, 'message' => 'bad request']);
}
[$rc, $msg] = wrapper([$action, $name, $user]);
out($rc === 0 ? 200 : 409, ['ok' => $rc === 0, 'message' => $msg === '' ? "exit $rc" : $msg, 'services' => services()]);
