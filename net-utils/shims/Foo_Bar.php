<?php
/*
 * Foo_Bar.php shim: the old foo($label) answered from ~/.foo/bar; this one answers from `auth`.
 *
 * Put this file where the PHP scripts find Foo_Bar.php (or first on include_path) and they use the auth store
 * without any other change:  list($user, $pass) = foo("cp1.uhcloud.com:cpanel");
 *
 * foo($label)  -> [$login, $secret]  for the entry imported from ~/.foo under that label; ["", ""] when there is none
 *                 (what the callers test: if ($user == "") ...).
 * bar($login, $secret, $label)
 *              -> stores the entry in the auth service tier under that label (what foo($label) then answers), replacing
 *                 any entry with that label; $login "-delete" removes it.  true on success.  Nothing is written to ~/.foo/bar.
 *
 * `auth` is $AUTH_BIN, else ~/local/usr/bin/auth, else `auth` on the PATH.  The secret never touches a command line.
 */

function fb_auth_bin() {
  $bin = getenv('AUTH_BIN');
  if ($bin) {
    return $bin;
  }
  $pw   = posix_getpwuid(posix_geteuid());
  $mine = $pw['dir'] . '/local/usr/bin/auth';
  return is_executable($mine) ? $mine : 'auth';
}

function foo($one) {
  $out = [];
  $rc  = 1;
  exec(escapeshellarg(fb_auth_bin()) . ' foo ' . escapeshellarg($one) . ' 2>/dev/null', $out, $rc);
  if ($rc === 0 && isset($out[0])) {
    $f = explode("\t", $out[0], 2);
    if (count($f) === 2) {
      return [$f[0], $f[1]];
    }
  }
  return ["", ""];
}

function bar($three, $two, $one) {
  // $three = login (or "-delete"), $two = secret, $one = label.  Goes into the service tier, the one foo() reads first.
  // The options go AFTER the label and login: with the options first, the webhost's Python argparse treats the label and
  // login as unknown options ("auth: unknown option LABEL").
  $cmd = escapeshellarg(fb_auth_bin()) . ' bar ' . escapeshellarg($one);
  if ($three === "-delete") {
    $cmd .= ' --service --delete';
  } else {
    $cmd .= ' ' . escapeshellarg($three) . ' --service --stdin';
  }
  $p = proc_open($cmd, [0 => ['pipe', 'r'], 1 => ['file', '/dev/null', 'w'], 2 => ['file', '/dev/null', 'w']], $pipes);
  if (!is_resource($p)) {
    return false;
  }
  fwrite($pipes[0], $two . "\n");                   // the secret goes on stdin, never on the command line
  fclose($pipes[0]);
  return proc_close($p) === 0;
}
