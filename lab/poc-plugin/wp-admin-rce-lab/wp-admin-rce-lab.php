<?php
/**
 * Plugin Name: WP Admin RCE Lab
 * Description: Local lab demonstration: an administrator can turn plugin-install privileges into OS command execution. For isolated lab use only.
 * Version: 1.0.0
 * Author: Security Lab
 * License: GPL-2.0-or-later
 */

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

/**
 * Run a fixed, non-interactive demonstration command as the web server user.
 *
 * Reached at /?wplab_rce=1. Requires an authenticated session with the
 * manage_options capability (administrator by default). The command is
 * intentionally fixed so this artifact is a proof of execution, not a
 * general-purpose web shell; edit wplab_rce_demo_command() if you need a
 * different command in your own lab.
 */
function wplab_rce_demo_command() {
	return 'id; whoami; uname -sr; hostname; pwd';
}

/**
 * Endpoint that proves arbitrary code runs inside the WordPress process.
 */
function wplab_rce_endpoint() {
	if ( ! isset( $_GET['wplab_rce'] ) ) {
		return;
	}

	if ( ! is_user_logged_in() || ! current_user_can( 'manage_options' ) ) {
		status_header( 403 );
		header( 'Content-Type: text/plain; charset=utf-8' );
		exit( "403 forbidden: administrator session required\n" );
	}

	$cmd = wplab_rce_demo_command();

	$descriptors = array(
		1 => array( 'pipe', 'w' ),
		2 => array( 'pipe', 'w' ),
	);
	$process = proc_open( $cmd, $descriptors, $pipes, ABSPATH );

	if ( ! is_resource( $process ) ) {
		status_header( 500 );
		exit( "proc_open failed\n" );
	}

	$stdout = stream_get_contents( $pipes[1] );
	$stderr = stream_get_contents( $pipes[2] );
	fclose( $pipes[1] );
	fclose( $pipes[2] );
	$code = proc_close( $process );

	$report = sprintf(
		"command: %s\nexit: %d\nweb-user: %s\nhost: %s\ncwd: %s\n--- stdout ---\n%s--- stderr ---\n%s",
		$cmd,
		$code,
		trim( (string) shell_exec( 'whoami' ) ),
		trim( (string) gethostname() ),
		ABSPATH,
		$stdout,
		$stderr
	);

	// Out-of-band proof that arbitrary code ran inside the web server process.
	@file_put_contents(
		'/workspace/lab/rce-proof.txt',
		'[' . gmdate( 'c' ) . "] admin plugin execution\n" . $report . "\n"
	);

	status_header( 200 );
	header( 'Content-Type: text/plain; charset=utf-8' );
	echo $report;
	exit;
}
add_action( 'init', 'wplab_rce_endpoint' );
