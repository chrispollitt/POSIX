<?php
// cmpi-router www/servers-status.php, installed as /var/www/html/servers/status.php by `setup-services.sh servers`.
// For the servers list page: which services and upstream devices answer, tested from cpbee itself (a browser can only probe http).
// Apache listens on the lan0 address only, so this is LAN-only; it answers booleans, uptime and load, nothing else.
header('Content-Type: application/json');
header('Cache-Control: no-store');

// Open TCP connections to every target at once and wait at most $timeout seconds in total.
// $targets = [key => [host, port]]; returns [key => bool]. Host names are resolved first (IPv4).
function probe_all(array $targets, float $timeout = 2.0): array {
    $res = []; $socks = [];
    foreach ($targets as $k => [$host, $port]) {
        $res[$k] = false;
        $ip = filter_var($host, FILTER_VALIDATE_IP) ? $host : gethostbyname($host);
        if (!filter_var($ip, FILTER_VALIDATE_IP)) continue;
        $s = @stream_socket_client("tcp://$ip:$port", $errno, $errstr, 0, STREAM_CLIENT_CONNECT | STREAM_CLIENT_ASYNC_CONNECT);
        if ($s === false) continue;
        stream_set_blocking($s, false);
        $socks[$k] = $s;
    }
    $deadline = microtime(true) + $timeout;
    while ($socks && ($left = $deadline - microtime(true)) > 0) {
        $w = array_values($socks); $r = null; $e = null;
        if (@stream_select($r, $w, $e, (int)$left, (int)(($left - (int)$left) * 1e6)) < 1) break;
        foreach ($w as $s) {                      // writable = the connect finished; a peer name exists only if it succeeded
            $k = array_search($s, $socks, true);
            $res[$k] = @stream_socket_get_name($s, true) !== false;
            fclose($s); unset($socks[$k]);
        }
    }
    foreach ($socks as $s) fclose($s);
    return $res;
}

// true when the url answers with 2xx/3xx (a proxy that cannot reach its backend gives 503 and counts as down)
function http_ok(string $url, int $timeout = 3): bool {
    $ctx = stream_context_create(['http' => ['method' => 'GET', 'timeout' => $timeout, 'ignore_errors' => true, 'follow_location' => 0]]);
    @file_get_contents($url, false, $ctx, 0, 1);
    return !empty($http_response_header[0]) && preg_match('#^HTTP/\S+ [23]\d\d#', $http_response_header[0]) === 1;
}

$me = $_SERVER['SERVER_ADDR'] ?? '127.0.0.1';   // the lan0 address: vsftpd and telnet listen there, not on loopback
$t = probe_all([
    'ssh'          => ['127.0.0.1', 22],
    'smtp'         => ['127.0.0.1', 25],
    'ftp'          => [$me, 21],
    'telnet'       => [$me, 23],
    'terminals'    => [$me, 8444],               // nginx in front of the browser terminal apps (POSIX/web-ttyd)
    'ergo'         => [$me, 6697],               // the IRC server (Ergo, TLS) that Floyd and tvchat use
    'imaps'        => [$me, 993],                // the mailbox server (Dovecot, IMAP over TLS) that tvmail and phones use
    'floydgate'    => [$me, 7077],               // the master Floyd's gate (tvchat-floyd) for tvcal, tvmail, tvchat
    'radicale'     => [$me, 5232],             // the calendar server (Radicale, TLS) that tvcal and Floyd use
    'vax_console'  => ['127.0.0.1', 2323],       // simh console: the simulator is running
    'vax_telnet'   => ['192.168.20.30', 23],     // VMS itself (TCPware) answers
    'vax_http'     => ['192.168.20.30', 80],     // the DEC C web server on the VAX (VAX/httpd) answers
    'talkd'        => ['127.0.0.1', 518],        // talkd (talkd.service): TCP 518 is tvchat; UDP 518 (ntalk) cannot be probed with a connect
    'mesh_tcp'     => ['192.168.123.101', 80],   // building mesh/enterphone server, reached over vr180
    'router_old'   => ['192.168.1.254', 80],     // the existing home router (cmrouter); gone at FINAL
    'router_vr180' => ['192.168.123.1', 80],     // the building's VR180 Wi-Fi router
    'net_telus'    => ['www.telus.com', 443],    // internet reachability: the carrier ...
    'net_host'     => ['www.hostupon.com', 443], // ... and the web host
]);

// Floyd, the central tvchat bot (tvchat-floyd.service): is the daemon up, and for how long (systemctl needs no privileges to ask)
$floyd = trim((string)@shell_exec('systemctl is-active tvchat-floyd 2>/dev/null')) === 'active';
$floyd_up = null;
if ($floyd) {
    $ts = trim((string)@shell_exec('systemctl show -p ActiveEnterTimestamp --value tvchat-floyd 2>/dev/null'));
    $when = $ts === '' ? false : strtotime(preg_replace('/^[A-Za-z]{3} /', '', $ts));   // "Sat 2026-10-31 23:28:07 PDT"
    if ($when !== false) $floyd_up = max(0, time() - $when);
}

$up = @file_get_contents('/proc/uptime');
$la = @file_get_contents('/proc/loadavg');
echo json_encode([
    'ssh'          => $t['ssh'],
    'smtp'         => $t['smtp'],
    'ftp'          => $t['ftp'],
    'telnet'       => $t['telnet'],
    'terminals'    => $t['terminals'],
    'vax_console'  => $t['vax_console'],
    'vax_telnet'   => $t['vax_telnet'],
    'vax_http'     => $t['vax_http'],
    'talkd'        => $t['talkd'],
    'ergo'         => $t['ergo'],
    'imaps'        => $t['imaps'],
    'radicale'     => $t['radicale'],
    'floydgate'    => $t['floydgate'],
    'floyd'        => $floyd,
    'floyd_up_s'   => $floyd_up,
    'mesh'         => $t['mesh_tcp'] && http_ok('http://mesh/mesh/'),   // proxied by Apache at /mesh/; only asked when the port is open
    'router_old'   => $t['router_old'],
    'router_vr180' => $t['router_vr180'],
    'net_telus'    => $t['net_telus'],
    'net_host'     => $t['net_host'],
    'uptime_s'     => $up === false ? null : (int)explode(' ', $up)[0],
    'load'         => $la === false ? null : array_map('floatval', array_slice(explode(' ', $la), 0, 3)),
]);
