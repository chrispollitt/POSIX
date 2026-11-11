<?php
/*
 * Foo_Bar.php shim: the old foo($label) answered from ~/.foo/bar; this one answers from `auth`.
 *
 * Put this file where the PHP scripts find Foo_Bar.php (or first on include_path) and they use the auth store
 * without any other change:  list($user, $pass) = foo("cp1.uhcloud.com:cpanel");
 *
 * foo($label)  -> [$login, $secret]  for the entry imported from ~/.foo under that label; ["failed", "failed"] when there
 *                 is none (the contract of the original Foo_Bar.php; fb.php tests `$user == 'failed'`).
 * bar($login, $secret, $label)
 *              -> stores the entry in the auth service tier under that label (what foo($label) then answers), replacing
 *                 any entry with that label; $login "-delete" removes it.  true on success.  Nothing is written to ~/.foo/bar.
 *
 * `auth` is $AUTH_BIN, else ~/local/usr/bin/auth, else `auth` on the PATH.  The secret never touches a command line.
 *
 * It also works under the web server, where the environment is thin: auth is run with HOME set (to the account's home if
 * the environment has none) and with /usr/local/bin:/usr/bin:/bin and ~/local/usr/bin added to the PATH, because auth
 * needs python3 and gpg on the PATH and its settings in ~/.config/auth.
 */

function fb_home() {
  $pw = posix_getpwuid(posix_geteuid());
  return $pw['dir'];
}

function fb_auth_bin() {
  $bin = getenv('AUTH_BIN');
  if ($bin) {
    return $bin;
  }
  $mine = fb_home() . '/local/usr/bin/auth';
  return is_executable($mine) ? $mine : 'auth';
}

// "env HOME=... PATH=... " to put in front of the auth command line
function fb_env_prefix() {
  $home = getenv('HOME');
  if (!$home) {
    $home = fb_home();
  }
  $path  = getenv('PATH');
  $extra = '/usr/local/bin:/usr/bin:/bin:' . fb_home() . '/local/usr/bin';
  $path  = $path ? $path . ':' . $extra : $extra;
  return 'env HOME=' . escapeshellarg($home) . ' PATH=' . escapeshellarg($path) . ' ';
}

function foo($one) {
  $out = [];
  $rc  = 1;
  exec(fb_env_prefix() . escapeshellarg(fb_auth_bin()) . ' foo ' . escapeshellarg($one) . ' 2>/dev/null', $out, $rc);
  if ($rc === 0 && isset($out[0])) {
    $f = explode("\t", $out[0], 2);
    if (count($f) === 2) {
      return [$f[0], $f[1]];
    }
  }
  return ["failed", "failed"];
}

function bar($three, $two, $one) {
  // $three = login (or "-delete"), $two = secret, $one = label.  Goes into the service tier, the one foo() reads first.
  // The options go AFTER the label and login: with the options first, the webhost's Python argparse treats the label and
  // login as unknown options ("auth: unknown option LABEL").
  $cmd = fb_env_prefix() . escapeshellarg(fb_auth_bin()) . ' bar ' . escapeshellarg($one);
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
