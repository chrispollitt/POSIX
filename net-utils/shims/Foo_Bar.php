<?php
/*
 * Foo_Bar.php shim: the old foo($label) answered from ~/.foo/bar; this one answers from `auth`.
 *
 * Put this file where the PHP scripts find Foo_Bar.php (or first on include_path) and they use the auth store
 * without any other change:  list($user, $pass) = foo("cp1.uhcloud.com:cpanel");
 *
 * foo($label)  -> [$login, $secret]  for the entry imported from ~/.foo under that label; ["", ""] when there is none
 *                 (what the callers test: if ($user == "") ...).
 * bar()        -> not supported here (it wrote ~/.foo/bar); use `auth set --service SCHEME@HOST LOGIN`.
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
  fwrite(STDERR, "Foo_Bar shim: bar() is not supported; use: auth set --service SCHEME@HOST LOGIN\n");
  return false;
}
