<?php
/*
 * Foo_Bar.php for the LAN (the laptop): foo() asks the auth vault first and falls back to the old ~/.foo/bar file.
 *
 * Every language's Foo_Bar library (bash, perl, python, js, c) runs Foo_Bar_w.php, which requires this file, so installing
 * it here moves all of them onto the vault with no change to any caller.  The rest of this file is the 2015 original
 * (WebApps/user_php/Foo_Bar.php) with one change: its foo() is renamed fb_file_foo() and is the fallback.
 * bar() is the original: it still writes ~/.foo/bar.
 *
 * foo($label) -> [$login, $secret]:
 *   1. `auth foo LABEL` (4 s limit).  With the master vault unlocked, or a service record for the label, that is the answer.
 *   2. Anything else (vault locked, cpbee not answering, no such label) -> the original code reads ~/.foo/bar exactly as before.
 *   When auth fails because the vault is locked or cpbee is down, that is remembered for 60 s in a small file in the temp
 *   directory, so a loop over many labels (GetHosts) does not retry ssh for each one.
 * No secret is printed or put on a command line.  Environment: AUTH_BIN (auth), FOO_BAR_DOWN_SECS (60), FOO_BAR_NO_AUTH=1
 * (skip the vault: behave exactly like the original).
 */

function fb_lan_home() {
  $pw = posix_getpwuid(posix_geteuid());
  return $pw['dir'];
}

function fb_lan_auth_bin() {
  $bin = getenv('AUTH_BIN');
  if ($bin) {
    return $bin;
  }
  return is_executable('/usr/local/bin/auth') ? '/usr/local/bin/auth' : 'auth';
}

function fb_lan_down_file() {
  return sys_get_temp_dir() . '/foo-bar-auth-down-' . posix_geteuid();
}

// [$login, $secret] from the vault, or null when auth has nothing (or cannot be asked right now)
function fb_auth_foo($one) {
  if (getenv('FOO_BAR_NO_AUTH')) {
    return null;
  }
  $secs = getenv('FOO_BAR_DOWN_SECS');
  $secs = ($secs === false || $secs === '') ? 60 : (int)$secs;
  $down = fb_lan_down_file();
  if ($secs > 0 && file_exists($down) && (time() - filemtime($down)) < $secs) {
    return null;
  }
  $path = getenv('PATH');
  $path = ($path ? $path . ':' : '') . '/usr/local/bin:/usr/bin:/bin';
  $cmd  = 'env HOME=' . escapeshellarg(getenv('HOME') ?: fb_lan_home()) . ' PATH=' . escapeshellarg($path) .
          ' timeout 4 ' . escapeshellarg(fb_lan_auth_bin()) . ' foo ' . escapeshellarg($one);
  $p = proc_open($cmd, [0 => ['file', '/dev/null', 'r'], 1 => ['pipe', 'w'], 2 => ['file', '/dev/null', 'w']], $pipes);
  if (!is_resource($p)) {
    return null;
  }
  $out = stream_get_contents($pipes[1]);
  fclose($pipes[1]);
  $rc = proc_close($p);
  if ($rc === 0) {
    $f = explode("\t", rtrim($out, "\r\n"), 2);
    if (count($f) === 2 && $f[1] !== '') {
      return [$f[0], $f[1]];
    }
    return null;
  }
  if ($rc !== 1) {                         // 4 locked, 124 timed out, 255 ssh failed, 127 no auth: remember it for a while
    @touch($down);
  }
  return null;
}

// do the foo() operation ////////////////////////////////
function foo($one) {
  $r = fb_auth_foo(fb_alias($one));
  if ($r !== null) {
    return $r;
  }
  return fb_file_foo($one);                // the old file knows the label as written
}

// Old labels that mean the same secret as another label.  mesh:pg is the same login and secret as mesh; the vault keeps
// it once (postgres mesh.cmnet mesh), so foo("mesh:pg") asks the vault for "mesh".  More can go in the file
// ~/.config/auth/foo-aliases (or $FOO_BAR_ALIASES), one per line:  OLDLABEL TAB-or-spaces TARGETLABEL  (# starts a comment).
function fb_alias($one) {
  $map = ['mesh:pg' => 'mesh'];
  $file = getenv('FOO_BAR_ALIASES') ?: (fb_lan_home() . '/.config/auth/foo-aliases');
  if (is_readable($file)) {
    foreach (file($file, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $line) {
      $line = trim(preg_replace('/#.*/', '', $line));
      if ($line !== '' && preg_match('/^(\S+)\s+(\S+)$/', $line, $m)) {
        $map[$m[1]] = $m[2];
      }
    }
  }
  return isset($map[$one]) ? $map[$one] : $one;
}

// do the foo() operation ////////////////////////////////
function fb_file_foo($one) {
  // vars //
  $fb_pwinfo = posix_getpwuid(posix_geteuid());
  $fb_home   = $fb_pwinfo['dir'];
  $fb_file   = "$fb_home/.foo/bar";
  // read file
  if(! file_exists($fb_file)) {
    trigger_error('fb file missing: '.$fb_file, E_USER_WARNING);
    return(["failed","failed"]);
  }
  $four = file($fb_file , FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
  // look for entry
  $qone = preg_quote($one, '/');
  $five = array_values(preg_grep( "/\t$qone$/", $four));
  if(count($five) != 1) {
    trigger_error('fb host missing: '.$one, E_USER_WARNING);
    return(["failed","failed"]);
  }
  list($three, $etwo, $one) = explode("\t",$five[0]);
  // decrypt
  $two = fb_decrypt($etwo, $one);
  if(strlen($two)==0) {
    trigger_error('fb decrypt failed: '.$one, E_USER_WARNING);
    return(["failed","failed"]);
  }

  return([$three,$two]);  
}

// do the bar() operation ////////////////////////////////
function bar($three,$two,$one) {
  // vars //
  $fb_pwinfo = posix_getpwuid(posix_geteuid());
  $fb_home   = $fb_pwinfo['dir'];
  $fb_file   = "$fb_home/.foo/bar";
  // encrypt
  $success = false;
  $etwo    = fb_encrypt($two, $one);
  // read file
  if( file_exists($fb_file) ) {
    $four  = file($fb_file, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
    $qone = preg_quote($one, '/');
    $four  = array_values(preg_grep( "/\t$qone$/", $four, PREG_GREP_INVERT));
  }
  elseif(!file_exists(dirname($fb_file))) {
    mkdir(dirname($fb_file));
  }
  // update/delete entry
  if($three != "-delete") {
    $four[]  = "$three\t$etwo\t$one";
  }
  // write file
  sort($four);
  $contents = implode(PHP_EOL, $four);
  $contents .= PHP_EOL;
  $success = file_put_contents ($fb_file, $contents, LOCK_EX );
  chmod(dirname($fb_file), 0700);
  chmod($fb_file, 0600);
  
  return($success);
}

// encrypt() ///////////////////////////////////////////////
function fb_encrypt($data, $salt) {
  $padding = 16 - (strlen($data) % 16);                    // calc pad len
  $ct      =  $data . str_repeat(chr($padding), $padding); // padded data 
  list($key, $iv) = fb_get_key_iv($salt);
  // encrypt
  $encrypt = openssl_encrypt(
    $ct,
    'aes-256-cbc',
    $key,
    true, // OPENSSL_RAW_DATA,  
    $iv);
  // encode
  $eencrypt = base64_encode($encrypt);
  // return
  return $eencrypt;
}

// decrypt() //////////////////////////////////////////////////
function fb_decrypt($edata, $salt) {
  // decode
  $data        = base64_decode($edata);
  // ct
  list($key, $iv) = fb_get_key_iv($salt);
  // decrypt
  $cleartext   = openssl_decrypt(
    $data,
    'aes-256-cbc',
    $key,
    true,
    $iv);
  // return
  $cleartext = rtrim($cleartext,"\x00..\x1F");
  return($cleartext);
}

// get key & iv //////////////////////////////////////////////
function fb_get_key_iv($salt) {
  // vars //
  $fb_pwinfo = posix_getpwuid(posix_geteuid());
  $fb_home   = $fb_pwinfo['dir'];
  $fb_file   = "$fb_home/.foo/bar";
  $fb_passwd = "$fb_home/.ssh-OLD/id_rsa";  // allowlist secret
  // get password (choose one)  // allowlist secret
  if(! file_exists($fb_passwd)) {
    trigger_error('fb file missing: '.$fb_passwd, E_USER_WARNING);
    return(["failed","failed"]);
  }
  $password = file_get_contents($fb_passwd);

  // hashing rounds
  $rounds  = 6;
  // hashed, computed password
  $data00  = $password . $salt;
  $hash    = array();
  $hash[0] = sha256($data00, true);
  $result  = $hash[0];
  // do hashing rounds
  for ($i = 1; $i < $rounds; $i++) {
    $hash[$i] = sha256($hash[$i - 1].$data00, true);
    $result      .= $hash[$i];
  }
  // final key
  $key         = substr($result, 0, 32);
  // iv
  $iv          = substr($result, 32, 16);
  // return
  return([$key, $iv]);
}

// sha256() ////////////////////////////////////////////
function sha256($a, $b) {
  return hash('SHA256', $a, $b);
}

////////////////////////////////////////////////////////

?>
